# Read-only policy for the External Secrets Operator (Way 1 — destination cluster).
#
# ESO adds the kv-v2 "data/" segment itself, so remoteRef.key in an ExternalSecret is
# written without it while the policy paths below still include it.

path "secret/data/prod/*" {
  capabilities = ["read"]
}

path "secret/metadata/prod/*" {
  capabilities = ["read", "list"]
}

# Argo CD's own credentials: repository access, cluster credentials, SSO client secret.
path "secret/data/argocd/*" {
  capabilities = ["read"]
}

path "secret/metadata/argocd/*" {
  capabilities = ["read", "list"]
}
