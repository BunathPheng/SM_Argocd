#!/usr/bin/env bash
#
# Static validation for the SM_Argocd manifests. Runs the checks a reviewer expects to pass
# before these manifests reach a cluster: YAML lint, shell lint, Helm lint + render, Kustomize
# build and a build of the argocd-vault-plugin sidecar image.
#
# Usage: scripts/lint.sh            (all checks; Docker build skipped if docker is absent)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

rc=0
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { echo "FAILED: $*" >&2; rc=1; }

step "yamllint (static manifests; helm templates excluded via .yamllint)"
yamllint . || fail "yamllint"

step "shellcheck (shell scripts)"
# shellcheck disable=SC2044
for f in $(git ls-files '*.sh'); do
  echo "  - $f"
  shellcheck "$f" || fail "shellcheck $f"
done

step "helm lint (charts)"
helm lint examples/legacy-app-avp/chart || fail "helm lint legacy-app"
helm dependency build examples/redis-eso/chart >/dev/null 2>&1 || \
  helm dependency update examples/redis-eso/chart >/dev/null 2>&1 || true
helm lint examples/redis-eso/chart || fail "helm lint redis-eso"

step "helm template (charts render)"
helm template redis examples/redis-eso/chart >/dev/null || fail "helm template redis-eso"
helm template legacy-app examples/legacy-app-avp/chart >/dev/null || fail "helm template legacy-app"

step "kustomize build (Argo CD + AVP overlay)"
kubectl kustomize avp/ >/dev/null || fail "kustomize build avp/"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  step "docker build (argocd-vault-plugin sidecar image)"
  docker build -t argocd-vault-plugin:lint-check avp/ >/dev/null || fail "docker build avp/"
else
  step "docker build (skipped: Docker unavailable)"
fi

echo
if [ "$rc" -eq 0 ]; then
  echo "All static checks passed."
else
  echo "One or more static checks failed." >&2
fi
exit "$rc"
