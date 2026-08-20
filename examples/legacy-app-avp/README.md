# Example — Way 2: manifest generation with argocd-vault-plugin

Demonstrates the only case that genuinely needs this approach: a chart that accepts a
password **as a literal value** and provides no `existingSecret` parameter.

Full guide: [`docs/02-manifest-generation-openbao.md`](../../docs/02-manifest-generation-openbao.md)

## Prerequisites

1. AVP sidecar installed on the repo-server — [`avp/`](../../avp/)
2. OpenBao role `argocd-repo-server` bound to policy `argocd-avp-read` —
   [`openbao/setup-kubernetes-auth.sh`](../../openbao/setup-kubernetes-auth.sh)
3. The secret present in OpenBao:

   ```bash
   bao kv put secret/prod/legacy-app password="s3cr3t"
   ```

## Apply

```bash
kubectl apply -f application.yaml
```

## What happens

1. repo-server fetches this directory at the target revision.
2. The `avp-helm` sidecar runs `helm template`, producing a Secret whose `DB_PASSWORD` is
   still the literal string `<path:secret/data/prod/legacy-app#password>`.
3. `argocd-vault-plugin generate -` authenticates to OpenBao with the repo-server
   ServiceAccount token and replaces the placeholder with the real value.
4. The rendered manifest — now containing the password — is returned to the controller,
   **cached in Redis in plaintext**, and applied to the cluster.

## Verify

```bash
# Placeholder was substituted. WARNING: this prints the real password, which is
# precisely the exposure this approach introduces.
argocd app manifests legacy-app | grep DB_PASSWORD

# Sync/auth errors from AVP surface on the Application:
argocd app get legacy-app
```

If you see the literal `<path:...>` in the output, the plugin ran but AVP did not — check
that the `generate` command pipes through `argocd-vault-plugin generate -`.

## Rotation

Rotating in OpenBao does **not** propagate immediately: manifests are cached against the Git
revision, so the old value is served until the repo cache expires (default 24h) or you force
a refresh.

```bash
argocd app get legacy-app --hard-refresh
```

## Migrating off this pattern

If the chart gains an `existingSecret` parameter, follow section 10 of the guide: create the
`ExternalSecret`, swap the value for the Secret name, change `plugin:` back to `helm:`, then
remove the path from the `argocd-avp-read` policy.
