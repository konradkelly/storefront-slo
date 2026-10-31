#!/usr/bin/env bash
# Installs Argo CD into a lab cluster and hands it the rest. The root Application "platform" renders k8s/platform:
# one Application per add-on (monitoring, operators, the Gateway) plus the storefront, synced from git in waves.
# Called by kind-up.sh and k3s-up.sh once the cluster and its Secrets exist; safe to rerun.
#   bash scripts/argocd-up.sh          # kind
#   bash scripts/argocd-up.sh k3s      # k3s on EC2 (k3s-up.sh sets DOMAIN and GRAFANA_CLOUD_URL)
# REVISION=<branch> makes every app track that branch instead of main. Push it first: Argo CD reads GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
version=v3.5.4
cluster=${1:-kind}
case "$cluster" in
  kind) context=kind-storefront ;;
  k3s)
    context=k3s-storefront
    export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/storefront-k3s.yaml}" ;;
  *) echo "usage: $0 [kind|k3s]" >&2; exit 2 ;;
esac
revision=${REVISION:-main}
k() { kubectl --context "$context" "$@"; }

k create namespace argocd --dry-run=client -o yaml | k apply -f -
k apply --server-side -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/$version/manifests/install.yaml"
k -n argocd patch configmap argocd-cm --type merge --patch-file k8s/argocd/argocd-cm.yaml
k -n argocd rollout status deployment/argocd-server --timeout=300s
k -n argocd rollout status deployment/argocd-repo-server --timeout=300s
k -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# The root app is the one thing not in git: it says which cluster this is and carries the per-run values.
cat <<EOF | k apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/konradkelly/storefront-slo.git
    targetRevision: $revision
    path: k8s/platform
    helm:
      valueFiles: [values-$cluster.yaml]
      valuesObject:
        revision: $revision
        domain: "${DOMAIN:-}"
        grafanaCloudUrl: "${GRAFANA_CLOUD_URL:-}"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - RespectIgnoreDifferences=true
  ignoreDifferences:
    # A soak drill's fault is an override on the storefront Application (scripts/experiments/soak_drill.py).
    # Without this, self-heal here would remove it within minutes.
    - group: argoproj.io
      kind: Application
      name: storefront
      jsonPointers:
        - /spec/source/kustomize
EOF

echo "Argo CD is syncing k8s/platform from $revision. On a new cluster that takes 10-15 minutes."
apps() { k -n argocd get applications --no-headers \
  -o custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null; }
for i in $(seq 120); do
  [ "$(k -n argocd get application platform -o jsonpath='{.status.sync.status}/{.status.health.status}')" = Synced/Healthy ] &&
    { apps; echo "Every app is Synced and Healthy."; break; }
  [ "$i" = 120 ] && { echo "Not done after 20 minutes. Still waiting:"; apps | grep -v 'Synced *Healthy'; exit 1; }
  ((i % 6 == 0)) && { echo "--- $(date +%T) waiting for:"; apps | grep -v 'Synced *Healthy' || true; }
  sleep 10
done
echo "Argo CD UI: kubectl --context $context -n argocd port-forward svc/argocd-server 8081:443"
echo "  (user admin; password: kubectl --context $context -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
