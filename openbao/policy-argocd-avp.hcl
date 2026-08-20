# Read-only policy for argocd-vault-plugin running in the Argo CD repo-server.
#
# This policy is the only boundary between a compromised repo-server and your secret store,
# so keep the path prefixes as narrow as the deployment allows. Add one stanza per
# environment rather than widening to "secret/data/*".
#
# kv-v2 splits reads and metadata onto separate paths: the data path is what
# <path:secret/data/prod/app#key> placeholders resolve against.

path "secret/data/prod/*" {
  capabilities = ["read"]
}

path "secret/metadata/prod/*" {
  capabilities = ["read", "list"]
}

# Allows AVP to verify its own token; useful when debugging authentication.
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
