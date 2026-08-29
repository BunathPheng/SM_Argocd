#!/usr/bin/env bash
#
# Cloud Agent start phase for SM_Argocd.
#
# Brings up the Docker daemon that kind and `docker build` depend on. It is idempotent: if a
# daemon is already responding on the socket it returns immediately. The daemon is launched
# in the background (there is no systemd in the VM) and this script waits for readiness
# before returning so that later terminals and scripts find a working Docker.
#
# It deliberately does NOT create the kind cluster or install the Argo CD / OpenBao / ESO
# stack — that is an on-demand developer action, see scripts/dev-cluster-up.sh.
set -euo pipefail

log() { printf '\n==> %s\n' "$*"; }

if docker info >/dev/null 2>&1; then
  log "Docker daemon already running"
  exit 0
fi

log "Starting dockerd"
sudo mkdir -p /var/log
sudo bash -c 'nohup dockerd >/var/log/dockerd.log 2>&1 &'

log "Waiting for the Docker socket"
for _ in $(seq 1 30); do
  if sudo docker info >/dev/null 2>&1; then
    # Make the socket usable without sudo for the rest of the session.
    sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
    log "Docker is ready"
    docker version --format 'Docker {{.Server.Version}} (storage: {{range .Server.Components}}{{if eq .Name "Engine"}}{{end}}{{end}})' 2>/dev/null || true
    docker info --format 'Storage driver: {{.Driver}}' 2>/dev/null || true
    exit 0
  fi
  sleep 2
done

echo "ERROR: dockerd did not become ready; see /var/log/dockerd.log" >&2
sudo tail -n 30 /var/log/dockerd.log >&2 || true
exit 1
