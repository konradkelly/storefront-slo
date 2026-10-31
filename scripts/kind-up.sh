#!/bin/bash
# Brings up the full kind environment from scratch, or re-applies it on an existing cluster. Safe to rerun.
#   bash scripts/kind-up.sh
#   REVISION=<branch> bash scripts/kind-up.sh    # track a pushed branch instead of main
#
# The script creates the cluster, its network plugin and the Secrets. Argo CD then installs everything else from
# GitHub (k8s/platform), so the cluster runs what's on main, not what's in your working tree.
#
# Needs: Docker (~9 GiB for Docker/WSL), kind, kubectl. Every kubectl call names the context, so other clusters in
# your kubeconfig are never touched.
set -euo pipefail
cd "$(dirname "$0")/.."

CTX=kind-storefront
CALICO_VERSION=v3.32.2
source scripts/lib/bootstrap.sh # k(), step(), the Secrets

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
k -n kube-system rollout status ds/calico-node --timeout=600s # a new cluster pulls ~250 MB of images per node
k wait --for=condition=Ready nodes --all --timeout=300s

step "Secrets (the only cluster state that isn't in git)"
create_slack_secret

step "Argo CD, then the platform and the storefront from git"
bash scripts/argocd-up.sh kind

step "done"
echo "Storefront:    http://storefront.localhost/products"
echo "Grafana:       http://grafana.localhost   (admin/admin)"
echo "Prometheus:    http://prometheus.localhost"
echo "Alertmanager:  http://alertmanager.localhost"
echo "Alert log:     kubectl --context $CTX -n monitoring logs -f deploy/alert-logger"
