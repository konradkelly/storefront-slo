#!/usr/bin/env bash
# Install Argo CD into an existing lab cluster after its platform is up (kind-up.sh or k3s-up.sh), then register
# the storefront Application for that environment.
#   bash scripts/argocd-up.sh          # kind
#   bash scripts/argocd-up.sh k3s      # k3s on EC2 (called by k3s-up.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
version=v3.5.4
case "${1:-kind}" in
  kind)
    context=kind-storefront
    overlay=k8s/overlays/kind-gitops/kustomization.yaml
    app=k8s/argocd/storefront.yaml ;;
  k3s)
    context=k3s-storefront
    export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/storefront-k3s.yaml}"
    overlay=k8s/overlays/k3s/kustomization.yaml
    app=k8s/argocd/storefront-k3s.yaml ;;
  *) echo "usage: $0 [kind|k3s]" >&2; exit 2 ;;
esac
k() { kubectl --context "$context" "$@"; }

k create namespace argocd --dry-run=client -o yaml | k apply -f -
k apply --server-side -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$version/manifests/install.yaml"
k -n argocd rollout status deployment/argocd-server --timeout=300s
k -n argocd rollout status deployment/argocd-repo-server --timeout=300s
k -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
if grep -q awaiting-first-release "$overlay"; then
  echo "Argo CD installed. Publish the first image before applying $app."
else
  k apply -f "$app"
fi
echo "UI: kubectl --context $context -n argocd port-forward svc/argocd-server 8081:443"
