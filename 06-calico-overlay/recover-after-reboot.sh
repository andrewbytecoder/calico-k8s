#!/usr/bin/env bash

[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

set -Eeuo pipefail

LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CEOS_CONTAINER="clab-calico-overlay-ceos01"
INOTIFY_MIN_INSTANCES=1024

NODES=(
  k01-control-plane
  k01-worker
  k01-worker2
  k01-worker3
)

CEOS_INTERFACES=(eth1 eth2 eth3 eth4)
NODE_ADDRESSES=(
  10.10.10.10/24
  10.10.10.11/24
  10.10.10.12/24
  10.10.20.20/24
)
REMOTE_ROUTES=(
  "10.10.20.0/24 via 10.10.10.1"
  "10.10.20.0/24 via 10.10.10.1"
  "10.10.20.0/24 via 10.10.10.1"
  "10.10.10.0/24 via 10.10.20.1"
)

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

show_diagnostics() {
  set +e
  docker ps -a --filter "name=${CEOS_CONTAINER}" --format 'table {{.Names}}\t{{.Status}}'
  for node in "${NODES[@]}"; do
    docker exec "${node}" ip -br address show eth1 2>/dev/null || true
  done
  if command -v kubectl >/dev/null 2>&1; then
    kubectl get nodes -o wide
    kubectl get pods -n calico-system -o wide
    kubectl get tigerastatus
  fi
}

on_error() {
  local exit_code=$?
  trap - ERR
  printf '\nRecovery failed with exit code %s. Current status:\n' "${exit_code}" >&2
  show_diagnostics >&2
  exit "${exit_code}"
}

trap on_error ERR

for command_name in docker containerlab kubectl curl; do
  command -v "${command_name}" >/dev/null 2>&1 || die "required command not found: ${command_name}"
done

docker info >/dev/null 2>&1 || die "Docker is not running or the current user cannot access it"
docker inspect "${CEOS_CONTAINER}" >/dev/null 2>&1 || die "container not found: ${CEOS_CONTAINER}"

for node in "${NODES[@]}"; do
  docker inspect "${node}" >/dev/null 2>&1 || die "container not found: ${node}"
done

if [[ -f "${LAB_DIR}/k01.kubeconfig" ]]; then
  export KUBECONFIG="${LAB_DIR}/k01.kubeconfig"
elif [[ -f "${HOME}/.kube/config" ]]; then
  export KUBECONFIG="${HOME}/.kube/config"
else
  die "no kubeconfig found"
fi

sudo -v

current_inotify="$(sysctl -n fs.inotify.max_user_instances)"
if (( current_inotify < INOTIFY_MIN_INSTANCES )); then
  log "Raising fs.inotify.max_user_instances to ${INOTIFY_MIN_INSTANCES}"
  sudo sysctl -w "fs.inotify.max_user_instances=${INOTIFY_MIN_INSTANCES}"
fi

links_complete=true
for index in "${!NODES[@]}"; do
  node="${NODES[$index]}"
  ceos_interface="${CEOS_INTERFACES[$index]}"

  if ! docker exec "${node}" ip link show eth1 >/dev/null 2>&1; then
    links_complete=false
  fi

  if ! docker exec "${CEOS_CONTAINER}" ip link show "${ceos_interface}" >/dev/null 2>&1; then
    links_complete=false
  fi
done

if [[ "${links_complete}" == true ]]; then
  connected_count="$({ docker exec "${CEOS_CONTAINER}" Cli -c 'show interfaces status' 2>/dev/null || true; } | awk '$1 ~ /^Et[1-4]$/ && $0 ~ / connected / {count++} END {print count+0}')"
  if [[ "${connected_count}" != "4" ]]; then
    links_complete=false
  fi
fi

if [[ "${links_complete}" != true ]]; then
  log "Restarting cEOS before rebuilding all veth links"
  if [[ "$(docker inspect -f '{{.State.Running}}' "${CEOS_CONTAINER}")" == true ]]; then
    docker stop --timeout 15 "${CEOS_CONTAINER}" >/dev/null
  fi

  for node in "${NODES[@]}"; do
    if docker exec "${node}" ip link show eth1 >/dev/null 2>&1; then
      docker exec "${node}" ip link delete eth1
    fi
  done

  docker start "${CEOS_CONTAINER}" >/dev/null

  for index in "${!NODES[@]}"; do
    node="${NODES[$index]}"
    ceos_interface="${CEOS_INTERFACES[$index]}"

    log "Creating ${CEOS_CONTAINER}:${ceos_interface} <-> ${node}:eth1"
    sudo containerlab tools veth create \
      --a-endpoint "${CEOS_CONTAINER}:${ceos_interface}" \
      --b-endpoint "${node}:eth1" \
      --mtu 1500
  done
fi

log "Applying Kind node interface addresses and routes"
for index in "${!NODES[@]}"; do
  node="${NODES[$index]}"
  address="${NODE_ADDRESSES[$index]}"
  route="${REMOTE_ROUTES[$index]}"

  docker exec "${node}" ip link set dev eth1 up
  docker exec "${node}" ip link set dev eth1 mtu 1500
  docker exec "${node}" ethtool -K eth1 tso off gso off
  docker exec "${node}" ip addr replace "${address}" dev eth1
  docker exec "${node}" ip route replace ${route} dev eth1
done

log "Waiting for all cEOS data-plane interfaces"
ceos_ready=false
for _ in $(seq 1 120); do
  connected_count="$({ docker exec "${CEOS_CONTAINER}" Cli -c 'show interfaces status' 2>/dev/null || true; } | awk '$1 ~ /^Et[1-4]$/ && $0 ~ / connected / {count++} END {print count+0}')"
  if [[ "${connected_count}" == "4" ]]; then
    ceos_ready=true
    break
  fi
  sleep 2
done
[[ "${ceos_ready}" == true ]] || die "cEOS interfaces did not become connected"

log "Checking routed underlay connectivity"
underlay_ready=false
for _ in $(seq 1 120); do
  api_response="$(docker exec k01-worker3 curl -ksS --max-time 3 https://10.10.10.10:6443/livez 2>/dev/null || true)"
  kubelet_response="$(docker exec k01-control-plane curl -ksS --max-time 3 https://10.10.20.20:10250/healthz 2>/dev/null || true)"

  if [[ "${api_response}" == "ok" && ( "${kubelet_response}" == "Unauthorized" || "${kubelet_response}" == "ok" ) ]]; then
    underlay_ready=true
    break
  fi
  sleep 2
done
[[ "${underlay_ready}" == true ]] || die "routed underlay connectivity did not recover"

log "Waiting for Calico node readiness"
kubectl wait \
  --namespace calico-system \
  --for=condition=Ready \
  pod \
  --selector k8s-app=calico-node \
  --timeout=5m

kubectl wait --for=condition=Available tigerastatus/calico --timeout=5m

log "Recovery completed"
docker exec "${CEOS_CONTAINER}" Cli -c 'show ip interface brief'
kubectl get nodes -o wide
kubectl get pods -n calico-system -o wide
kubectl get tigerastatus
