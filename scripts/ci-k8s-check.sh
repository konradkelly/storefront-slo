#!/usr/bin/env bash
# Offline rendering; schema validation fetches pinned custom-resource schemas.
# Requires kubectl 1.34.1, kubeconform 0.8.0 and kube-linter 0.8.3 on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."

render_dir=$(mktemp -d)
trap 'rm -rf "$render_dir"' EXIT
crd_catalog=fd90051867733c60d32d16450556e9cd18459aef

kubectl kustomize k8s/base > "$render_dir/base.yaml"
kubectl kustomize k8s/overlays/kind > "$render_dir/kind.yaml"
kubectl kustomize k8s/overlays/kind-gitops > "$render_dir/kind-gitops.yaml"
kubectl kustomize k8s/overlays/ci > "$render_dir/ci.yaml"

# Missing schemas are errors, including for CRs. No -ignore-missing-schemas.
kubeconform -strict -summary -kubernetes-version 1.34.0 \
  -schema-location default \
  -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$crd_catalog/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
  "$render_dir/base.yaml" "$render_dir/kind.yaml" "$render_dir/kind-gitops.yaml" "$render_dir/ci.yaml" \
  k8s/argocd/storefront.yaml \
  k8s/gateway/gateway.yaml k8s/gateway/monitoring-routes.yaml \
  k8s/monitoring/alert-logger.yaml k8s/loadtest/k6-job.yaml

# Lint the deployable overlay: base intentionally leaves its image tag to overlays.
# Supporting Gateway/logger/load-test manifests receive schema validation above.
kube-linter lint --config .kube-linter.yaml \
  "$render_dir/kind.yaml" "$render_dir/kind-gitops.yaml"
