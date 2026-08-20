# Argo CD's Own Secrets from OpenBao

Distinct from application secrets: these are the credentials **Argo CD itself** needs — Git
repository access, external cluster credentials, SSO client secrets, notification tokens.

**Only External Secrets Operator can do this job.** Argo CD reads `Secret` objects from the
Kubernetes API, matched by specific labels. Vault Agent Injector and the Secrets Store CSI
Driver deliver files into a pod, which Argo CD never looks at.

## The label is the contract

Argo CD discovers its own configuration secrets by label:

| Label | Purpose | Required keys |
|---|---|---|
| `argocd.argoproj.io/secret-type: repository` | A single Git/Helm repository | `type`, `url`, `username`, `password` (or `sshPrivateKey`) |
| `argocd.argoproj.io/secret-type: repo-creds` | Credential template matching a URL prefix | `type`, `url`, `username`, `password` |
| `argocd.argoproj.io/secret-type: cluster` | External destination cluster | `name`, `server`, `config` |
| `app.kubernetes.io/part-of: argocd` | Makes values resolvable via `$name:key` in `argocd-cm` | any |

ESO's `target.template` is what lets you attach those labels to a generated secret.

## Repository credentials

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: repo-creds-myorg
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao-backend
    kind: ClusterSecretStore
  target:
    name: repo-creds-myorg
    creationPolicy: Owner
    template:
      metadata:
        labels:
          argocd.argoproj.io/secret-type: repository
      data:
        type: git
        url: https://github.com/myorg/myrepo
        username: "{{ .username }}"
        password: "{{ .token }}"
  data:
    - secretKey: username
      remoteRef: { key: secret/argocd/git, property: username }
    - secretKey: token
      remoteRef: { key: secret/argocd/git, property: token }
```

## External cluster credentials

`config` is a JSON blob, so build it in the template:

```yaml
  target:
    name: cluster-prod
    template:
      metadata:
        labels:
          argocd.argoproj.io/secret-type: cluster
      data:
        name: prod
        server: https://prod.k8s.example.com
        config: |
          {
            "bearerToken": "{{ .token }}",
            "tlsClientConfig": { "insecure": false, "caData": "{{ .caData }}" }
          }
```

## SSO / OIDC client secret

Argo CD resolves `$secretname:key` references in `argocd-cm` against secrets labelled
`app.kubernetes.io/part-of: argocd`:

```yaml
# argocd-cm
data:
  oidc.config: |
    name: OpenBao SSO
    issuer: https://sso.example.com
    clientID: argocd
    clientSecret: $oidc-secret:clientSecret
```

The `ExternalSecret` target then needs that label plus a `clientSecret` key:

```yaml
  target:
    name: oidc-secret
    template:
      metadata:
        labels:
          app.kubernetes.io/part-of: argocd
      data:
        clientSecret: "{{ .clientSecret }}"
```

## Bootstrap ordering

There is a chicken-and-egg problem: if the `ExternalSecret` that provides Argo CD's Git
credentials is itself deployed *by* Argo CD from a private repo, Argo CD cannot read the repo
that contains its own credentials.

Resolve it in one of these ways:

1. Apply that one `ExternalSecret` out-of-band (`kubectl apply`, or your installer) and manage
   everything else declaratively.
2. Keep the bootstrap `ExternalSecret` in a public or in-cluster-readable repository.
3. Include it in the Argo CD installation overlay itself, ahead of the app-of-apps.

Options 1 and 3 are the usual choices. Whichever you pick, the secret *value* still comes
from OpenBao — only the small reference object is bootstrapped manually.
