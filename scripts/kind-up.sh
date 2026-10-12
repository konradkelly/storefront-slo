#!/bin/bash
# Brings up the full kind environment from scratch, or re-applies it on an existing cluster. Safe to rerun.
#   bash scripts/kind-up.sh
#
# Needs: Docker (~9 GiB for Docker/WSL), kind, kubectl, helm. Every kubectl/helm call names the context, so other
# clusters in your kubeconfig are never touched.
set -euo pipefail
cd "$(dirname "$0")/.."

CTX=kind-storefront
CALICO_VERSION=v3.32.2
source scripts/lib/platform.sh # k(), step(), the shared platform and its versions

step "cluster"
if kind get clusters 2>/dev/null | grep -qx storefront; then
  echo "kind cluster 'storefront' already exists"
else
  kind create cluster --config k8s/kind-config.yaml
fi

step "Calico $CALICO_VERSION (kind's default CNI is disabled because it doesn't enforce NetworkPolicy)"
if ! k -n kube-system get ds calico-node >/dev/null 2>&1; then
  k create -f "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml" >/dev/null
fi
k -n kube-system rollout status ds/calico-node --timeout=300s
k wait --for=condition=Ready nodes --all --timeout=300s

install_monitoring
install_cnpg
install_metrics_server
install_keda
install_gateway k8s/gateway/gateway.yaml
k apply -f k8s/gateway/monitoring-routes.yaml

step "storefront-api image"
docker build -q -t storefront-api:dev ./app
kind load docker-image storefront-api:dev --name storefront

step "storefront workloads and SLO rules"
k apply -k k8s/overlays/kind
k -n storefront wait --for=condition=Ready cluster/storefront-db --timeout=600s
k -n storefront rollout restart deploy/storefront-api >/dev/null # pick up a freshly loaded :dev image
k -n storefront rollout status deploy/storefront-api --timeout=300s

step "done"
echo "Storefront:    http://storefront.localhost/products"
echo "Grafana:       http://grafana.localhost   (admin/admin)"
echo "Prometheus:    http://prometheus.localhost"
echo "Alertmanager:  http://alertmanager.localhost"
echo "Alert log:     kubectl --context $CTX -n monitoring logs -f deploy/alert-logger"
