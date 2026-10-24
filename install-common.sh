#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${ROOT}/app"
IMAGE_DIR="${ROOT}/images"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  printf '\n=== %s ===\n' "$*"
}

command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install Docker before running offline labs."
docker info >/dev/null 2>&1 || die "Docker daemon is not available."

log "Installing kubectl, calicoctl and kind"
for bin in kubectl calicoctl kind; do
  [[ -f "${APP_DIR}/${bin}" ]] || die "Missing ${APP_DIR}/${bin}"
  chmod +x "${APP_DIR}/${bin}"
  sudo install -m 0755 "${APP_DIR}/${bin}" "/usr/local/bin/${bin}"
done

log "Installing containerlab package"
DEB="$(find "$APP_DIR" -maxdepth 1 -name 'containerlab_*_linux_amd64.deb' | sort | tail -1)"
[[ -n "$DEB" ]] || die "Missing containerlab deb package in ${APP_DIR}"
sudo dpkg -i "$DEB"

log "Importing Arista cEOS image if needed"
if ! docker image inspect ceos:4.34.0F >/dev/null 2>&1; then
  [[ -f "${ROOT}/cEOS64-lab-4.34.0F.tar" ]] || die "Missing ${ROOT}/cEOS64-lab-4.34.0F.tar"
  docker import "${ROOT}/cEOS64-lab-4.34.0F.tar" ceos:4.34.0F
fi

log "Loading offline Docker image tar files"
MAP_FILE="${IMAGE_DIR}/tar-map.tsv"
[[ -f "$MAP_FILE" ]] || die "Missing ${MAP_FILE}"
while IFS=$'\t' read -r image tar_name; do
  [[ -z "${image:-}" || "$image" =~ ^# ]] && continue
  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "Image already present: $image"
    continue
  fi
  [[ -f "${IMAGE_DIR}/${tar_name}" ]] || die "Missing image tar: ${IMAGE_DIR}/${tar_name}"
  echo "Loading $image from ${tar_name}"
  docker load -i "${IMAGE_DIR}/${tar_name}"
done < "$MAP_FILE"

log "Verifying required images"
while IFS= read -r image; do
  [[ -z "$image" || "$image" =~ ^# ]] && continue
  docker image inspect "$image" >/dev/null 2>&1 || die "Missing required image after install: $image"
done < "${IMAGE_DIR}/required-image-list.txt"

log "Versions"
kubectl version --client=true || true
calicoctl version || true
kind version || true
containerlab version || true

echo ""
echo "Common offline tools and images are ready. You can now cd into any lab directory and run ./deploy.sh."
