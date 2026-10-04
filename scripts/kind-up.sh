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
KPS_VERSION=91.9.0
k() { kubectl --context "$CTX" "$@"; }
step() { echo; echo "== $*"; }

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

step "monitoring namespace, Slack secret, alert logger"
k create namespace monitoring --dry-run=client -o yaml | k apply -f -
secret_args=()
for f in slack-page-url slack-ticket-url; do
  if [ -s "alertmanager/secrets/$f" ]; then
    secret_args+=("--from-file=$f=alertmanager/secrets/$f")
  else
    echo "alertmanager/secrets/$f missing: Slack sends will fail, alert-logger still receives everything"
    secret_args+=("--from-literal=$f=")
  fi
done
k -n monitoring create secret generic alertmanager-slack "${secret_args[@]}" --dry-run=client -o yaml | k apply -f -
k -n monitoring create configmap alert-logger-script --from-file=webhook-logger.py=alertmanager/webhook-logger.py \
  --dry-run=client -o yaml | k apply -f -
k apply -f k8s/monitoring/alert-logger.yaml

step "kube-prometheus-stack $KPS_VERSION"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
# alertmanager.yml goes in as alertmanager.config (a map), which the chart writes out unchanged. The chart's
# stringConfig only works with tplConfig: true, and that would run Helm's template engine over the Slack
# {{ template ... }} calls, which only Alertmanager can resolve.
am_values=$(mktemp)
trap 'rm -f "$am_values"' EXIT
{ echo "alertmanager:"; echo "  config:"; sed 's/^/    /' alertmanager/alertmanager.yml; } > "$am_values"
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --kube-context "$CTX" --namespace monitoring --version "$KPS_VERSION" \
  -f k8s/monitoring/kps-values.yaml -f "$am_values" \
  --set-file 'alertmanager.templateFiles.slack\.tmpl=alertmanager/templates/slack.tmpl' \
  --wait --timeout 10m

step "Grafana dashboards"
k -n monitoring create configmap storefront-dashboards \
  --from-file=storefront.json=grafana/dashboards/storefront.json --from-file=slo.json=grafana/dashboards/slo.json \
  --dry-run=client -o yaml | k label --local -f - grafana_dashboard=1 -o yaml | k apply -f -

step "storefront-api image"
docker build -q -t storefront-api:dev ./app
kind load docker-image storefront-api:dev --name storefront

step "storefront workloads and SLO rules"
k apply -k k8s/overlays/kind
k -n storefront rollout status deploy/postgres --timeout=300s
k -n storefront rollout restart deploy/storefront-api >/dev/null # pick up a freshly loaded :dev image
k -n storefront rollout status deploy/storefront-api --timeout=300s

step "done"
echo "Prometheus:    kubectl --context $CTX -n monitoring port-forward svc/prometheus-operated 9090"
echo "Grafana:       kubectl --context $CTX -n monitoring port-forward svc/kps-grafana 3000:80   (admin/admin)"
echo "Alertmanager:  kubectl --context $CTX -n monitoring port-forward svc/alertmanager-operated 9093"
echo "Alert log:     kubectl --context $CTX -n monitoring logs -f deploy/alert-logger"
