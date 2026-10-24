#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${OFFLINE_ROOT}/scripts/offline-common.sh"
cd "$SCRIPT_DIR"

TOPOLOGY_FILE="calico-ipam.clab.yaml"
KIND_CLUSTER="calico-ipam"

offline_cleanup_lab "$TOPOLOGY_FILE" "$KIND_CLUSTER"
offline_log "Lab destroyed; common tools and Docker images were preserved."
