# Sidecar image for argocd-vault-plugin (Way 2 — manifest generation).
#
# Deliberately does NOT contain argocd-cmp-server: the repo-server's existing "copyutil"
# init container shares that binary through the "var-files" volume, which keeps this image
# independent of the Argo CD version.
#
# Pin both versions explicitly and bump them deliberately:
#   AVP:  https://github.com/argoproj-labs/argocd-vault-plugin/releases
#   Helm: https://github.com/helm/helm/releases
FROM alpine:3.20

ARG AVP_VERSION=1.18.1
ARG HELM_VERSION=v3.16.3
ARG TARGETARCH=amd64

RUN apk add --no-cache bash ca-certificates curl git

RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
      -o /tmp/helm.tar.gz \
 && tar -xzf /tmp/helm.tar.gz -C /tmp \
 && mv "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm \
 && rm -rf /tmp/helm.tar.gz "/tmp/linux-${TARGETARCH}" \
 && helm version --short

RUN curl -fsSL \
      "https://github.com/argoproj-labs/argocd-vault-plugin/releases/download/v${AVP_VERSION}/argocd-vault-plugin_${AVP_VERSION}_linux_${TARGETARCH}" \
      -o /usr/local/bin/argocd-vault-plugin \
 && chmod +x /usr/local/bin/argocd-vault-plugin \
 && argocd-vault-plugin version

# UID 999 matches the argocd user used by the repo-server, so the shared
# var-files / plugins volumes stay readable.
RUN adduser -D -u 999 argocd
USER 999

ENTRYPOINT ["/var/run/argocd/argocd-cmp-server"]
