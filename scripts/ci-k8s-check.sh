#!/usr/bin/env bash
# Offline rendering; schema validation fetches pinned custom-resource schemas.
# Requires kubectl 1.34.1, helm 4.3.0, kubeconform 0.8.0 and kube-linter 0.8.3 on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."

render_dir=$(mktemp -d)
trap 'rm -rf "$render_dir"' EXIT
crd_catalog=fd90051867733c60d32d16450556e9cd18459aef

kubectl kustomize k8s/base > "$render_dir/base.yaml"
kubectl kustomize k8s/overlays/kind > "$render_dir/kind.yaml"
kubectl kustomize k8s/overlays/kind-gitops > "$render_dir/kind-gitops.yaml"
kubectl kustomize k8s/overlays/ci > "$render_dir/ci.yaml"
kubectl kustomize k8s/overlays/k3s > "$render_dir/k3s.yaml"
# What Argo CD renders: the app-of-apps for each cluster (k3s with every optional value set), and the plain-manifest
# apps, which read shared files from outside their directory (k8s/argocd/argocd-cm.yaml).
helm template platform k8s/platform -f k8s/platform/values-kind.yaml > "$render_dir/platform-kind.yaml"
helm template platform k8s/platform -f k8s/platform/values-k3s.yaml \
  --set domain=203.0.113.10.sslip.io --set grafanaCloudUrl=https://example.invalid/api/prom/push > "$render_dir/platform-k3s.yaml"
for d in monitoring kind k3s; do
  kubectl kustomize --load-restrictor LoadRestrictionsNone "k8s/cluster/$d" > "$render_dir/cluster-$d.yaml"
done

# Missing schemas are errors, including for CRs. No -ignore-missing-schemas.
kubeconform -strict -summary -kubernetes-version 1.34.0 \
  -schema-location default \
  -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$crd_catalog/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
  "$render_dir/base.yaml" "$render_dir/kind.yaml" "$render_dir/kind-gitops.yaml" "$render_dir/ci.yaml" \
  "$render_dir/k3s.yaml" "$render_dir"/platform-*.yaml "$render_dir"/cluster-*.yaml \
  k8s/monitoring/soak-drill.yaml k8s/loadtest/k6-job.yaml

# Lint the deployable overlay: base intentionally leaves its image tag to overlays.
# The platform's own manifests (k8s/cluster) and the load test receive schema validation above.
kube-linter lint --config .kube-linter.yaml \
  "$render_dir/kind.yaml" "$render_dir/kind-gitops.yaml" "$render_dir/k3s.yaml"
