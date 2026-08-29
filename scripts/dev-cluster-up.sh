#!/usr/bin/env bash
#
# Bring up a local, self-contained environment that exercises BOTH secret-management ways
# this repository documents, end to end, on a kind cluster:
#
#   Way 1 (destination cluster / ESO):  OpenBao -> External Secrets Operator -> Kubernetes Secret
#   Way 2 (manifest generation / AVP):  helm template -> argocd-vault-plugin generate -> real value
#
# It is idempotent and safe to re-run. It encapsulates the workarounds required to run kind
# inside the nested Cloud Agent VM:
#
#   * kube-proxy is switched to nftables mode. The VM's shared kernel has no xt_statistic
#     module, so the default iptables proxier cannot build KUBE-SVC load-balancing rules and
#     ClusterIP/DNS silently break. The nftables proxier needs no such module.
#   * Images are pulled on the host and `kind load`-ed into the node, because the kind node's
#     containerd has restricted egress to registries while the host does not.
#   * The ESO admission webhooks are removed: the apiserver->pod admission path is unreliable
#     in nested kind. The controller reconciles independently, which is what the demo proves.
#
# Requires: docker (running), kind, kubectl, helm, bao. Run .cursor/install.sh first.
set -euo pipefail

CLUSTER="${CLUSTER:-sm-argocd}"
ESO_VERSION="${ESO_VERSION:-0.9.19}"   # ships external-secrets.io/v1beta1, which the manifests use
KUBECONFIG_FILE="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG="$KUBECONFIG_FILE"

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'kill "${PF_PID:-}" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

require() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
for t in docker kind kubectl helm bao; do require "$t"; done
docker info >/dev/null 2>&1 || { echo "Docker is not running; run .cursor/start.sh" >&2; exit 1; }

# Pull an image on the host (which has registry egress) and load it into the kind node.
preload() {
  local img
  for img in "$@"; do
    [ -z "$img" ] && continue
    docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img"
    kind load docker-image --name "$CLUSTER" "$img"
  done
}

# Preload every image referenced by pods in a namespace, then delete stuck pods so they
# restart against the now-local images.
heal_namespace_images() {
  local ns="$1" imgs
  imgs="$(kubectl -n "$ns" get pods \
    -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
    2>/dev/null | sort -u)"
  # shellcheck disable=SC2086
  [ -n "$imgs" ] && preload $imgs
  kubectl -n "$ns" delete pod --all --wait=false >/dev/null 2>&1 || true
}

########################################################################################
log "1/8  kind cluster '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  info "cluster already exists"
else
  cat >"$TMP/kind.yaml" <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  kubeProxyMode: "nftables"
YAML
  kind create cluster --name "$CLUSTER" --config "$TMP/kind.yaml" --wait 120s
fi
kubectl cluster-info --context "kind-${CLUSTER}" >/dev/null

# Belt-and-suspenders: make sure kube-proxy really is in nftables mode (older kind images
# ignore the config value), then wait for cluster DNS to work through a ClusterIP.
if ! kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -q 'mode: nftables'; then
  log "1b/8 switching kube-proxy to nftables mode"
  kubectl -n kube-system get cm kube-proxy -o yaml \
    | sed 's/mode: .*/mode: nftables/' | kubectl apply -f - >/dev/null
  kubectl -n kube-system rollout restart ds kube-proxy
  kubectl -n kube-system rollout status ds kube-proxy --timeout=90s
fi

########################################################################################
log "2/8  Helm repositories"
helm repo add openbao https://openbao.github.io/openbao-helm >/dev/null 2>&1 || true
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update >/dev/null

########################################################################################
log "3/8  OpenBao (dev mode)"
kubectl create namespace openbao --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install openbao openbao/openbao --namespace openbao \
  --set server.dev.enabled=true --set server.dev.devRootToken=root --set injector.enabled=false >/dev/null
sleep 8; heal_namespace_images openbao
kubectl -n openbao wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 --timeout=180s
# The Kubernetes auth backend reviews tokens via the API server; grant the SA that right.
kubectl create clusterrolebinding openbao-token-review \
  --clusterrole=system:auth-delegator --serviceaccount=openbao:openbao \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

########################################################################################
log "4/8  External Secrets Operator ${ESO_VERSION}"
helm upgrade --install external-secrets external-secrets/external-secrets \
  --version "${ESO_VERSION}" --namespace external-secrets --create-namespace \
  --set installCRDs=true >/dev/null
sleep 8; heal_namespace_images external-secrets
kubectl -n external-secrets rollout status deploy/external-secrets --timeout=180s
# The apiserver->pod admission path is unreliable in nested kind; the controller reconciles
# without the webhook, which is what this demo verifies.
kubectl delete validatingwebhookconfigurations externalsecret-validate secretstore-validate >/dev/null 2>&1 || true

########################################################################################
log "5/8  Configure OpenBao (repo script) + seed demo secrets"
kubectl -n openbao port-forward svc/openbao 8200:8200 >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 20); do curl -fsS http://127.0.0.1:8200/v1/sys/health >/dev/null 2>&1 && break; sleep 1; done
export BAO_ADDR="http://127.0.0.1:8200" BAO_TOKEN="root"
./openbao/setup-kubernetes-auth.sh >/dev/null
# Deterministic values so the flow is verifiable end to end.
bao kv put secret/prod/redis     password=s3cr3t  >/dev/null
bao kv put secret/prod/redis-acl my-user=an0ther  >/dev/null
bao kv put secret/prod/legacy-app password=s3cr3t >/dev/null
info "seeded secret/prod/{redis,redis-acl,legacy-app}"

########################################################################################
log "6/8  Way 1 — ESO pulls from OpenBao into a Kubernetes Secret"
kubectl create namespace redis --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# The committed ClusterSecretStore targets https; dev-mode OpenBao serves http. Only the
# scheme is adapted for the demo — everything else is applied verbatim.
sed 's#https://openbao#http://openbao#' examples/redis-eso/clustersecretstore.yaml \
  | kubectl apply -f - >/dev/null
kubectl annotate clustersecretstore openbao-backend force-sync="$(date +%s)" --overwrite >/dev/null
helm template redis examples/redis-eso/chart --namespace redis \
  --show-only templates/externalsecret.yaml | kubectl -n redis apply -f - >/dev/null
# Wait for the Secrets ESO is expected to create.
for _ in $(seq 1 30); do
  kubectl -n redis get secret redis-auth redis-acl-users >/dev/null 2>&1 && break
  kubectl -n redis annotate externalsecret redis-auth redis-acl-users \
    force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
  sleep 3
done
kubectl -n redis get externalsecret
echo
info "redis-auth/redis-password      = $(kubectl -n redis get secret redis-auth      -o jsonpath='{.data.redis-password}' | base64 -d)"
info "redis-acl-users/my-user        = $(kubectl -n redis get secret redis-acl-users -o jsonpath='{.data.my-user}'        | base64 -d)"
info "OpenBao secret/prod/redis      = $(bao kv get -field=password secret/prod/redis)"

########################################################################################
log "7/8  Way 2 — argocd-vault-plugin substitutes the placeholder"
docker build -t argocd-vault-plugin:dev avp/ >/dev/null
echo "    helm template (before):"
helm template legacy-app examples/legacy-app-avp/chart | grep 'DB_PASSWORD' | sed 's/^/      /'
echo "    argocd-vault-plugin generate (after), inside the built sidecar image:"
docker run --rm --network host \
  -e AVP_TYPE=vault -e AVP_AUTH_TYPE=token -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root \
  -v "$REPO_ROOT/examples/legacy-app-avp/chart:/chart:ro" -w /chart \
  --entrypoint sh argocd-vault-plugin:dev \
  -c 'helm template legacy-app --namespace legacy-app . | argocd-vault-plugin generate -' \
  | grep 'DB_PASSWORD' | sed 's/^/      /'

########################################################################################
log "8/8  Done"
cat <<EOF

Both flows are live on cluster 'kind-${CLUSTER}':
  Way 1: kubectl -n redis get externalsecret,secret
  Way 2: re-run step 7, or 'docker run ... argocd-vault-plugin:dev'
  OpenBao UI/API: kubectl -n openbao port-forward svc/openbao 8200:8200  (token: root)

Tear down with: kind delete cluster --name ${CLUSTER}
EOF
