#!/usr/bin/env bash
#
# Configures OpenBao so that both secret paths work:
#   - argocd-repo-server      -> argocd-vault-plugin (Way 2, manifest generation)
#   - external-secrets        -> External Secrets Operator (Way 1, destination cluster)
#
# Requires a BAO_ADDR and a BAO_TOKEN with permission to manage policies and auth methods.
# The Kubernetes auth backend must trust the cluster whose ServiceAccount tokens are used:
# if Argo CD and your workloads run in different clusters, configure one auth mount per
# cluster and point each role at the right one.
set -euo pipefail

: "${BAO_ADDR:?set BAO_ADDR, e.g. https://openbao.example.com:8200}"
: "${BAO_TOKEN:?set BAO_TOKEN to an administrative token}"

KV_MOUNT="${KV_MOUNT:-secret}"
K8S_AUTH_PATH="${K8S_AUTH_PATH:-kubernetes}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Ensuring kv-v2 is mounted at ${KV_MOUNT}/"
bao secrets enable -path="${KV_MOUNT}" -version=2 kv 2>/dev/null \
  || echo "    already mounted, continuing"

echo "==> Ensuring Kubernetes auth is enabled at auth/${K8S_AUTH_PATH}/"
bao auth enable -path="${K8S_AUTH_PATH}" kubernetes 2>/dev/null \
  || echo "    already enabled, continuing"

# Run from inside the cluster, or supply kubernetes_ca_cert / token_reviewer_jwt explicitly
# when OpenBao is external. With OpenBao >= 2.0 the issuer is discovered automatically when
# kubernetes_host points at the in-cluster API server.
echo "==> Configuring the Kubernetes auth backend"
bao write "auth/${K8S_AUTH_PATH}/config" \
  kubernetes_host="${KUBERNETES_HOST:-https://kubernetes.default.svc}"

echo "==> Writing policies"
bao policy write argocd-avp-read      "${script_dir}/policy-argocd-avp.hcl"
bao policy write external-secrets-read "${script_dir}/policy-external-secrets.hcl"

# Way 2: the repo-server ServiceAccount. Granting this role is what makes Argo CD an
# OpenBao client — remove it again once no application depends on manifest generation.
echo "==> Role: argocd-repo-server (argocd-vault-plugin)"
bao write "auth/${K8S_AUTH_PATH}/role/argocd-repo-server" \
  bound_service_account_names=argocd-repo-server \
  bound_service_account_namespaces="${ARGOCD_NAMESPACE}" \
  token_policies=argocd-avp-read \
  token_ttl=1h

# Way 1: the External Secrets Operator ServiceAccount.
echo "==> Role: external-secrets (External Secrets Operator)"
bao write "auth/${K8S_AUTH_PATH}/role/external-secrets" \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces="${ESO_NAMESPACE}" \
  token_policies=external-secrets-read \
  token_ttl=1h

echo "==> Seeding example secrets"
bao kv put "${KV_MOUNT}/prod/redis"       password="$(openssl rand -base64 24)"
bao kv put "${KV_MOUNT}/prod/redis-acl"   my-user="$(openssl rand -base64 24)"
bao kv put "${KV_MOUNT}/prod/legacy-app"  password="$(openssl rand -base64 24)"

echo
echo "Done. Verify the placeholder path used by argocd-vault-plugin:"
echo "  bao kv get ${KV_MOUNT}/prod/legacy-app"
echo "  -> placeholder is <path:${KV_MOUNT}/data/prod/legacy-app#password>  (note the data/ segment)"
