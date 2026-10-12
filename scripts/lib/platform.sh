#!/bin/bash
# The platform every cluster gets, the same versions and values on kind and k3s: monitoring, CloudNativePG,
# metrics-server, KEDA, Envoy Gateway. Sourced by scripts/kind-up.sh and scripts/k3s-up.sh, which set CTX (the
# kubeconfig context) first. Every call names that context, so other clusters are never touched.
#
# Run from the repo root.

KPS_VERSION=91.9.0
CNPG_VERSION=0.29.1 # chart; operator 1.30.1
METRICS_SERVER_VERSION=3.14.0 # chart; app 0.9.0
KEDA_VERSION=2.21.0
ENVOY_GATEWAY_VERSION=1.9.2 # Gateway API implementation; ingress-nginx was retired in March 2026
CERT_MANAGER_VERSION=v1.21.2 # needed by the Barman Cloud plugin (its TLS certificates)
BARMAN_PLUGIN_VERSION=0.8.1 # chart; plugin v0.15.1

k() { kubectl --context "$CTX" "$@"; }
step() { echo; echo "== $*"; }

helm_repo() { # name url
  helm repo add "$1" "$2" >/dev/null 2>&1 || true
  helm repo update "$1" >/dev/null
}

install_monitoring() { # [extra kube-prometheus-stack helm args, e.g. -f values.yaml]
  step "monitoring namespace, Slack secret, alert logger"
  k create namespace monitoring --dry-run=client -o yaml | k apply -f -
  local secret_args=() f
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
  helm_repo prometheus-community https://prometheus-community.github.io/helm-charts
  # alertmanager.yml goes in as alertmanager.config (a map), which the chart writes out unchanged. The chart's
  # stringConfig only works with tplConfig: true, and that would run Helm's template engine over the Slack
  # {{ template ... }} calls, which only Alertmanager can resolve.
  local am_values
  am_values=$(mktemp)
  { echo "alertmanager:"; echo "  config:"; sed 's/^/    /' alertmanager/alertmanager.yml; } > "$am_values"
  helm upgrade --install kps prometheus-community/kube-prometheus-stack \
    --kube-context "$CTX" --namespace monitoring --version "$KPS_VERSION" \
    -f k8s/monitoring/kps-values.yaml -f "$am_values" \
    --set-file 'alertmanager.templateFiles.slack\.tmpl=alertmanager/templates/slack.tmpl' \
    "$@" --wait --timeout 10m
  rm -f "$am_values"

  step "Grafana dashboards"
  k -n monitoring create configmap storefront-dashboards \
    --from-file=storefront.json=grafana/dashboards/storefront.json --from-file=slo.json=grafana/dashboards/slo.json \
    --dry-run=client -o yaml | k label --local -f - grafana_dashboard=1 -o yaml | k apply -f -
}

install_cnpg() {
  step "CloudNativePG operator $CNPG_VERSION (must exist before the storefront Cluster resource)"
  helm_repo cnpg https://cloudnative-pg.github.io/charts
  helm upgrade --install cnpg cnpg/cloudnative-pg \
    --kube-context "$CTX" --namespace cnpg-system --create-namespace --version "$CNPG_VERSION" \
    -f k8s/monitoring/cnpg-values.yaml --wait --timeout 5m
}

# Object-store backups for CloudNativePG: cert-manager, then the Barman Cloud plugin next to the operator.
install_backup_plugin() {
  step "cert-manager $CERT_MANAGER_VERSION"
  helm_repo jetstack https://charts.jetstack.io
  helm upgrade --install cert-manager jetstack/cert-manager \
    --kube-context "$CTX" --namespace cert-manager --create-namespace --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true --wait --timeout 5m

  step "Barman Cloud plugin $BARMAN_PLUGIN_VERSION (must exist before a Cluster that archives through it)"
  helm_repo cnpg https://cloudnative-pg.github.io/charts
  helm upgrade --install barman-cloud cnpg/plugin-barman-cloud \
    --kube-context "$CTX" --namespace cnpg-system --version "$BARMAN_PLUGIN_VERSION" --wait --timeout 5m
}

install_metrics_server() {
  step "metrics-server $METRICS_SERVER_VERSION (pod CPU for kubectl top and the KEDA cpu trigger)"
  helm_repo metrics-server https://kubernetes-sigs.github.io/metrics-server/
  helm upgrade --install metrics-server metrics-server/metrics-server \
    --kube-context "$CTX" --namespace kube-system --version "$METRICS_SERVER_VERSION" \
    -f k8s/monitoring/metrics-server-values.yaml --wait --timeout 5m
}

install_keda() {
  step "KEDA $KEDA_VERSION (must exist before the storefront ScaledObject)"
  helm_repo kedacore https://kedacore.github.io/charts
  helm upgrade --install keda kedacore/keda \
    --kube-context "$CTX" --namespace keda --create-namespace --version "$KEDA_VERSION" \
    -f k8s/monitoring/keda-values.yaml --wait --timeout 5m
}

install_gateway() { # gateway manifest (k8s/gateway/gateway.yaml on kind)
  step "Envoy Gateway $ENVOY_GATEWAY_VERSION + the cluster Gateway (must exist before the storefront HTTPRoute)"
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "$ENVOY_GATEWAY_VERSION" \
    --kube-context "$CTX" --namespace envoy-gateway-system --create-namespace --wait --timeout 6m
  k apply -f "$1"
  k -n gateway wait --for=condition=Programmed gateway/storefront --timeout=600s
}
