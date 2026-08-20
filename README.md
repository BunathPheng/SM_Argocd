# SM_Argocd — Secret Management for Argo CD with OpenBao

Reference documentation and working manifests for delivering secrets to Argo CD-managed
applications, using [OpenBao](https://openbao.org/) as the secret store.

Based on [Argo CD — Secret Management](https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/).

## The question this repository answers

A Helm chart needs a password. If you write it into `values.yaml`, or type it into the Argo CD
GUI parameters box, it becomes plaintext — in Git, in the `Application` resource, and in the
Argo CD UI. Where should the password come from instead?

Argo CD offers two answers, and the difference is **who calls OpenBao**:

- **Way 1 — Destination cluster.** An operator in the target cluster resolves the secret.
  Git holds a reference; Argo CD never sees the value. *Strongly recommended upstream.*
- **Way 2 — Manifest generation.** Argo CD's repo-server resolves the secret while rendering.
  Git holds a placeholder, but the rendered value is cached in Argo CD's Redis in plaintext.
  *Strongly cautioned against upstream, still supported.*

Both keep plaintext out of Git — that is not the differentiator, and it is the most common
misconception.

## Choosing between them

The decision is **per chart**:

```bash
helm show values bitnami/redis | grep -i -E 'existingsecret|secretkey|usersecret|passwordfiles'
```

- **Any hit** → Way 1. Pass the Secret name, let External Secrets Operator fill it.
- **No hit** → try the escape hatches in
  [`docs/03-destination-cluster-eso.md`](docs/03-destination-cluster-eso.md) (post-renderer
  patch, `usePasswordFiles`, wrapper chart) before accepting Way 2.

Keep the Way 2 exception list short and documented: every entry means Argo CD holds OpenBao
credentials and caches rendered secrets.

## Repository layout

| Path | Contents |
|---|---|
| [`docs/01-overview.md`](docs/01-overview.md) | Both ways compared, decision flowchart, where the secret exists in each |
| [`docs/02-manifest-generation-openbao.md`](docs/02-manifest-generation-openbao.md) | **Way 2**: architecture, request flow, step-by-step implementation, rotation caveats, hardening, troubleshooting |
| [`docs/03-destination-cluster-eso.md`](docs/03-destination-cluster-eso.md) | **Way 1**: reference implementation with External Secrets Operator |
| [`docs/04-argocd-own-secrets.md`](docs/04-argocd-own-secrets.md) | Argo CD's own secrets — repo credentials, clusters, SSO — from OpenBao |
| [`avp/`](avp/) | Sidecar image, plugin config, repo-server patch and network policies for Way 2 |
| [`openbao/`](openbao/) | Policies and Kubernetes auth setup for both paths |
| [`examples/redis-eso/`](examples/redis-eso/) | Way 1 end to end: Bitnami Redis with `existingSecret` + `auth.acl.userSecret` |
| [`examples/legacy-app-avp/`](examples/legacy-app-avp/) | Way 2 end to end: a chart that only accepts a literal password |

## Quick start

```bash
# 1. Configure OpenBao: kv-v2, Kubernetes auth, policies and roles for both paths
export BAO_ADDR=https://openbao.example.com:8200 BAO_TOKEN=<admin-token>
./openbao/setup-kubernetes-auth.sh

# 2. Way 1 — recommended default
kubectl apply -f examples/redis-eso/clustersecretstore.yaml
kubectl apply -f examples/redis-eso/application.yaml

# 3. Way 2 — only for charts that cannot take a Secret name
docker build -t registry.example.com/argocd-vault-plugin:1.18.1 avp/
docker push registry.example.com/argocd-vault-plugin:1.18.1
kubectl apply -k avp/
kubectl apply -f examples/legacy-app-avp/application.yaml
```

Replace `registry.example.com`, the OpenBao address in
[`avp/repo-server-patch.yaml`](avp/repo-server-patch.yaml) and
[`examples/redis-eso/clustersecretstore.yaml`](examples/redis-eso/clustersecretstore.yaml), and
the `repoURL` in both `application.yaml` files before applying.

## Two things worth knowing up front

**The Argo CD GUI is the worst place for a password.** Helm parameters typed into the UI are
persisted into the live `Application` resource: plaintext in etcd, readable by anyone with
`applications, get`, and permanent drift against Git.

**Vault Agent Injector and the CSI driver cannot serve Argo CD's own secrets.** They deliver
files into a pod; Argo CD reads labelled `Secret` objects from the API server. Only External
Secrets Operator covers that case — see
[`docs/04-argocd-own-secrets.md`](docs/04-argocd-own-secrets.md).
