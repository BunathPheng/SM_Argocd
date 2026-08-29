#!/usr/bin/env bash
#
# Cloud Agent install phase for SM_Argocd.
#
# Installs the GitOps toolchain this repository is exercised with (Docker, kubectl, Helm,
# kind, yamllint, shellcheck and the OpenBao CLI) and vendors the Redis chart dependency so
# manifests render offline. It is idempotent: every step is guarded so re-running it (or
# running it against a warm snapshot) is a no-op when the tool is already present.
#
# Docker is configured for the fuse-overlayfs storage driver because the Cloud Agent VM is a
# nested container in which the default overlay2/containerd-snapshotter driver cannot mount
# overlays. The Docker daemon itself is started per-boot by .cursor/start.sh, not here.
set -euo pipefail

# Pinned tool versions — bump deliberately.
KUBECTL_VERSION="v1.31.3"
HELM_VERSION="v3.16.3"
KIND_VERSION="v0.25.0"
BAO_VERSION="2.2.0"

log() { printf '\n==> %s\n' "$*"; }

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confnew)

log "Installing base packages (shellcheck, yamllint, fuse-overlayfs, ...)"
sudo apt-get update -qq
sudo apt-get install "${APT_OPTS[@]}" \
  ca-certificates curl git jq gnupg openssl \
  shellcheck yamllint fuse3 fuse-overlayfs uidmap

log "Installing Docker CE"
if ! command -v docker >/dev/null 2>&1; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck disable=SC1091
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install "${APT_OPTS[@]}" \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin
fi

log "Configuring Docker for the nested-VM (fuse-overlayfs) storage driver"
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "storage-driver": "fuse-overlayfs",
  "features": { "containerd-snapshotter": false }
}
JSON
sudo groupadd -f docker
sudo usermod -aG docker "$(id -un)"

arch="$(dpkg --print-architecture)"  # amd64 / arm64

install_bin() { # url dest
  local url="$1" dest="$2" tmp
  tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp"
  sudo install -m 0755 "$tmp" "$dest"
  rm -f "$tmp"
}

if ! command -v kubectl >/dev/null 2>&1; then
  log "Installing kubectl ${KUBECTL_VERSION}"
  install_bin "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" /usr/local/bin/kubectl
fi

if ! command -v helm >/dev/null 2>&1; then
  log "Installing Helm ${HELM_VERSION}"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | HELM_INSTALL_DIR=/usr/local/bin sudo -E bash -s -- --version "${HELM_VERSION}"
fi

if ! command -v kind >/dev/null 2>&1; then
  log "Installing kind ${KIND_VERSION}"
  install_bin "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${arch}" /usr/local/bin/kind
fi

if ! command -v bao >/dev/null 2>&1; then
  log "Installing OpenBao CLI ${BAO_VERSION}"
  tmp="$(mktemp)"
  curl -fsSL "https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/bao_${BAO_VERSION}_linux_${arch}.deb" -o "$tmp"
  sudo dpkg -i "$tmp" >/dev/null
  rm -f "$tmp"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v helm >/dev/null 2>&1 && [ -f "${repo_root}/examples/redis-eso/chart/Chart.lock" ]; then
  log "Vendoring the Redis chart dependency (helm dependency build)"
  helm dependency build "${repo_root}/examples/redis-eso/chart" >/dev/null || \
    helm dependency update "${repo_root}/examples/redis-eso/chart" >/dev/null
fi

log "Install complete"
for t in docker kubectl helm kind yamllint shellcheck bao; do
  printf '  %-10s %s\n' "$t" "$("$t" version --short 2>/dev/null || "$t" --version 2>/dev/null | head -1 || echo present)"
done
