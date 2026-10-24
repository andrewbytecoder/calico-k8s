#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${OFFLINE_ROOT}/scripts/offline-common.sh"
cd "$SCRIPT_DIR"

LAB_NAME="19-calico-ingress"
TOPOLOGY_FILE="topology.clab.yaml"
KIND_CLUSTER="k01"
KUBECONFIG_FILE="${KIND_CLUSTER}.kubeconfig"

offline_require_runtime
offline_cleanup_lab "$TOPOLOGY_FILE" "$KIND_CLUSTER"

offline_log "Deploying containerlab topology"
sudo containerlab deploy -t "$TOPOLOGY_FILE"

if [[ -n "$KIND_CLUSTER" ]]; then
  offline_log "Waiting for kind containers to initialize"
  sleep 30
  sudo kind get kubeconfig --name="$KIND_CLUSTER" > "$KUBECONFIG_FILE"
  sudo chmod 0644 "$KUBECONFIG_FILE"
  export KUBECONFIG="${SCRIPT_DIR}/${KUBECONFIG_FILE}"
  offline_wait_api
  offline_load_kind_images "$KIND_CLUSTER" "$LAB_NAME"
  offline_install_calico "calico-cni-config/custom-resources.yaml"
  offline_apply_file "calico-cni-config/bgpconfiguration.yaml"
  offline_apply_file "calico-cni-config/bgppeer.yaml"
  offline_apply_file "k8s-manifests/lb-ippool.yaml"
  offline_apply_file "calico-cni-config/gatewayapi.yaml"
  offline_wait_gateway_api
  offline_apply_file "k8s-manifests/app-v1.yaml"
  offline_apply_file "k8s-manifests/app-v2.yaml"
  offline_apply_file "k8s-manifests/gateway.yaml"
  offline_apply_file "k8s-manifests/reference-grant.yaml"
  offline_apply_file "k8s-manifests/httproute.yaml"
  kubectl wait --for=condition=ready pod -l app=ingress-gateway-demo -n ingress-gateway-demo --timeout=180s || echo "Warning: demo pods are not ready yet."
  offline_log "Kubernetes nodes"
  kubectl get nodes -o wide
  echo ""
  echo "To use this cluster with kubectl, run:"
  echo "export KUBECONFIG=${SCRIPT_DIR}/${KUBECONFIG_FILE}"
fi

offline_log "Lab deployment completed"
