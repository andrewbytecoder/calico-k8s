# Offline Calico Containerlab Labs

This directory is the offline mirror of `/home/andrew/k8-networking-calico-containerlab/containerlab`.

## One-time setup on an offline host

```bash
cd /home/andrew/calico-containerlab
./install-common.sh
```

The common installer installs `kubectl`, `calicoctl`, `kind`, and `containerlab` from `app/`, imports `cEOS64-lab-4.34.0F.tar`, and loads Docker image tar files from `images/`.

`images/tar-map.tsv` maps each image to one dedicated tar file. Lab deploy scripts use these per-image tar files directly when importing images into kind nodes; the old combined `offline-images.tar` is no longer used.

## Run a lab

```bash
cd /home/andrew/calico-containerlab/06-calico-overlay
./deploy.sh
```

Each lab deploy script uses only local binaries, local manifests under `manifests/`, and local Docker images. Kind node images are standardized on `kindest/node:v1.35.0` and Calico is standardized on `v3.30.0`.

## Destroy a lab

```bash
./destroy.sh
```

Destroy scripts remove the lab topology, delete the kind cluster, remove generated kubeconfig files, and remove Docker networks named `clab` and `kind`. They intentionally keep Docker, kubectl, calicoctl, kind, containerlab, and all Docker images.
