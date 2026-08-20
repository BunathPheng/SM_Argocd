# Example — Way 1: External Secrets Operator with the Bitnami Redis chart

The Redis chart *looks* like it forces a plaintext password:

```yaml
auth:
  acl:
    users:
      - username: "my-user"
        password: "mypassword"   # plaintext in Git and in the Argo CD UI
```

But the same chart accepts Secret names instead — `auth.existingSecret`,
`auth.existingSecretPasswordKey` and `auth.acl.userSecret` — which puts it firmly in Way 1.

Full guide: [`docs/03-destination-cluster-eso.md`](../../docs/03-destination-cluster-eso.md)

## Prerequisites

1. External Secrets Operator installed in the destination cluster.
2. OpenBao role `external-secrets` bound to policy `external-secrets-read` —
   [`openbao/setup-kubernetes-auth.sh`](../../openbao/setup-kubernetes-auth.sh)
3. Secrets present in OpenBao. The ACL secret's keys must match the usernames:

   ```bash
   bao kv put secret/prod/redis     password="s3cr3t"
   bao kv put secret/prod/redis-acl my-user="an0ther"
   ```

## Apply

```bash
kubectl apply -f clustersecretstore.yaml   # once per cluster
kubectl apply -f application.yaml
```

## What happens

1. Argo CD applies the two `ExternalSecret` objects in sync wave -1. Neither contains a
   password.
2. ESO reads OpenBao and creates the `redis-auth` and `redis-acl-users` Secrets.
3. Argo CD's built-in `ExternalSecret` health check passes, so wave 0 proceeds and the Redis
   workload starts, referencing those Secrets by name.

## Verify

```bash
# ESO populated the Secrets
kubectl -n redis get externalsecret
kubectl -n redis get secret redis-auth redis-acl-users

# Nothing sensitive in what Argo CD rendered — the point of Way 1
argocd app manifests redis | grep -i password
```

The last command should show only Secret *names*, never a value.

## Rotation

ESO refreshes the Secret automatically at `refreshInterval`, but a running pod keeps the old
value. The `reloader.stakater.com/auto` annotation in `values.yaml` handles the restart, via
[Reloader](https://github.com/stakater/Reloader).
