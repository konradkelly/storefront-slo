#!/usr/bin/env bash
# Install Argo CD into the existing lab after kind-up.sh has installed operators.
set -euo pipefail
cd "$(dirname "$0")/.."
context=kind-storefront
version=v3.5.4
kubectl --context "$context" create namespace argocd --dry-run=client -o yaml | kubectl --context "$context" apply -f -
kubectl --context "$context" apply --server-side -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$version/manifests/install.yaml"
kubectl --context "$context" -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl --context "$context" -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl --context "$context" -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
if grep -q awaiting-first-release k8s/overlays/kind-gitops/kustomization.yaml; then
  echo 'Argo CD installed. Publish the first image before applying k8s/argocd/storefront.yaml.'
else
  kubectl --context "$context" apply -f k8s/argocd/storefront.yaml
fi
echo 'UI: kubectl --context kind-storefront -n argocd port-forward svc/argocd-server 8081:443'
