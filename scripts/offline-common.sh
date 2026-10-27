#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${OFFLINE_ROOT:-}" ]]; then
  OFFLINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

offline_log() {
  printf '\n=== %s ===\n' "$*"
}

offline_die() {
  echo "ERROR: $*" >&2
  exit 1
}

offline_require_runtime() {
  local missing=0
  for cmd in docker kubectl kind containerlab calicoctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing command: $cmd" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || offline_die "Run ${OFFLINE_ROOT}/install-common.sh first."

  docker info >/dev/null 2>&1 || offline_die "Docker daemon is not available."

  local list="${OFFLINE_ROOT}/images/required-image-list.txt"
  if [[ -f "$list" ]]; then
    while IFS= read -r image; do
      image="${image%$'\r'}"
      [[ -z "$image" || "$image" =~ ^# ]] && continue
      if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo "Missing Docker image: $image" >&2
        missing=1
      fi
    done < "$list"
  fi
  [[ "$missing" -eq 0 ]] || offline_die "Run ${OFFLINE_ROOT}/install-common.sh to install tools and load offline images."
}

offline_wait_api() {
  offline_log "Waiting for Kubernetes API"
  for _ in {1..60}; do
    if kubectl get nodes >/dev/null 2>&1; then
      kubectl get nodes -o wide
      return 0
    fi
    sleep 5
  done
  offline_die "Kubernetes API did not become ready in time."
}

offline_image_tar_for() {
  local image="$1"
  local map="${OFFLINE_ROOT}/images/tar-map.tsv"
  [[ -f "$map" ]] || return 1
  awk -F '\t' -v image="$image" '{ sub(/\r$/, "", $NF) } $1 == image { print $2; found=1; exit } END { if (!found) exit 1 }' "$map"
}

offline_load_kind_images() {
  local cluster="$1"
  local lab_name="${2:-}"
  local list="${OFFLINE_ROOT}/images/${lab_name}-kind-images.txt"
  [[ -f "$list" ]] || list="${OFFLINE_ROOT}/images/kind-image-list.txt"
  [[ -f "$list" ]] || return 0

  local nodes node image tar_name tar_path
  nodes="$(sudo kind get nodes --name "$cluster")"
  [[ -n "$nodes" ]] || offline_die "No kind nodes found for cluster: $cluster"

  offline_log "Loading offline image tar files into kind cluster ${cluster}"
  while IFS= read -r image; do
    image="${image%$'\r'}"
    [[ -z "$image" || "$image" =~ ^# ]] && continue
    tar_name="$(offline_image_tar_for "$image" || true)"
    tar_path="${OFFLINE_ROOT}/images/${tar_name}"
    echo "Loading $image"
    for node in $nodes; do
      echo "  -> $node"
      [[ -n "$tar_name" && -f "$tar_path" ]] || offline_die "Missing image tar for $image. Expected entry in images/tar-map.tsv and file under images/."
      if ! docker exec -i "$node" ctr -n k8s.io images import --all-platforms --digests - < "$tar_path" >/dev/null; then
        offline_die "Failed to load ${tar_path} into kind node $node"
      fi
    done
  done < "$list"
}

offline_apply_file() {
  local file="$1"
  [[ -f "$file" ]] || offline_die "Missing manifest: $file"
  offline_log "Applying $file"
  kubectl apply -f "$file"
}

offline_apply_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || offline_die "Missing manifest directory: $dir"
  shopt -s nullglob
  local files=("$dir"/*.yaml "$dir"/*.yml)
  shopt -u nullglob
  if [[ "${#files[@]}" -eq 0 ]]; then
    offline_die "No YAML manifests found in $dir"
  fi
  local file
  for file in "${files[@]}"; do
    offline_apply_file "$file"
  done
}

offline_apply_existing_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  shopt -s nullglob
  local files=("$dir"/*.yaml "$dir"/*.yml)
  shopt -u nullglob
  local file
  for file in "${files[@]}"; do
    offline_apply_file "$file"
  done
}

offline_create_or_apply() {
  local file="$1"
  [[ -f "$file" ]] || offline_die "Missing manifest: $file"
  kubectl create -f "$file" || kubectl apply -f "$file"
}

offline_install_calico() {
  local custom_resources="$1"
  offline_log "Installing Calico v3.30.0 from local manifests"
  offline_create_or_apply "${OFFLINE_ROOT}/manifests/operator-crds.yaml"
  offline_create_or_apply "${OFFLINE_ROOT}/manifests/tigera-operator.yaml"
  offline_apply_file "$custom_resources"

  offline_log "Waiting for Calico and Calico API server"
  kubectl get tigerastatus || true
  for _ in {1..80}; do
    local api_available calico_available
    api_available="$(kubectl get tigerastatus apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    calico_available="$(kubectl get tigerastatus calico -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    if [[ "$api_available" == "True" && "$calico_available" == "True" ]]; then
      kubectl get tigerastatus
      return 0
    fi
    sleep 15
  done
  kubectl get tigerastatus || true
  offline_die "Calico did not become ready in time."
}

offline_install_multus() {
  offline_log "Installing Multus from local manifest"
  offline_apply_file "${OFFLINE_ROOT}/manifests/multus-daemonset.yml"
  kubectl wait --for=condition=ready pod -l app=multus -n kube-system --timeout=180s || \
    echo "Warning: Multus pods are not ready yet; continuing so you can inspect the cluster."
}

offline_install_cni_plugins() {
  local cluster="$1"
  local tgz="${OFFLINE_ROOT}/app/cni-plugins-linux-amd64-v1.4.0.tgz"
  [[ -f "$tgz" ]] || offline_die "Missing CNI plugin archive: $tgz"
  offline_log "Installing CNI plugins in kind nodes"
  local nodes node
  nodes="$(sudo kind get nodes --name "$cluster")"
  for node in $nodes; do
    docker cp "$tgz" "${node}:/tmp/cni-plugins-linux-amd64-v1.4.0.tgz"
    docker exec "$node" sh -c 'mkdir -p /opt/cni/bin && tar -C /opt/cni/bin -xzf /tmp/cni-plugins-linux-amd64-v1.4.0.tgz'
  done
}

offline_wait_gateway_api() {
  offline_log "Waiting for Calico Gateway API resources"
  for _ in {1..60}; do
    if kubectl api-resources 2>/dev/null | grep -q 'gateway.networking.k8s.io'; then
      break
    fi
    sleep 10
  done
  for _ in {1..60}; do
    if kubectl get gatewayclass tigera-gateway-class >/dev/null 2>&1; then
      kubectl get gatewayclass
      return 0
    fi
    sleep 10
  done
  offline_die "Gateway API resources did not become ready in time."
}

offline_install_cert_manager() {
  offline_log "Installing cert-manager from local manifest"
  offline_apply_file "${OFFLINE_ROOT}/manifests/cert-manager-v1.16.2.yaml"
  kubectl wait --for=condition=available -n cert-manager \
    deploy/cert-manager \
    deploy/cert-manager-cainjector \
    deploy/cert-manager-webhook \
    --timeout=240s

  offline_log "Waiting for cert-manager webhook CA injection and TLS readiness"
  local secret_ca validating_ca mutating_ca
  for _ in {1..120}; do
    secret_ca="$(kubectl get secret -n cert-manager cert-manager-webhook-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
    validating_ca="$(kubectl get validatingwebhookconfiguration cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)"
    mutating_ca="$(kubectl get mutatingwebhookconfiguration cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)"

    if [[ -n "$secret_ca" && "$secret_ca" == "$validating_ca" && "$secret_ca" == "$mutating_ca" ]]; then
      if kubectl create --dry-run=server -f - >/dev/null 2>&1 <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cert-manager-webhook-readiness-check
spec:
  selfSigned: {}
EOF
      then
        return 0
      fi
    fi
    sleep 2
  done

  kubectl get pods -n cert-manager -o wide || true
  kubectl get validatingwebhookconfiguration cert-manager-webhook -o yaml || true
  offline_die "cert-manager webhook CA injection or TLS validation did not become ready in time."
}

offline_create_namespace() {
  local namespace="$1"
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
}

offline_cleanup_lab() {
  local topology_file="${1:-}"
  local cluster="${2:-}"

  if [[ -n "$topology_file" && -f "$topology_file" ]] && command -v containerlab >/dev/null 2>&1; then
    offline_log "Destroying containerlab topology ${topology_file}"
    sudo containerlab destroy -c -t "$topology_file" >/dev/null 2>&1 || true
  fi

  if [[ -n "$cluster" ]] && command -v kind >/dev/null 2>&1; then
    offline_log "Deleting kind cluster ${cluster}"
    sudo kind delete cluster --name "$cluster" >/dev/null 2>&1 || kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
  fi

  rm -f ./*.kubeconfig
  docker network rm clab kind >/dev/null 2>&1 || true
}
