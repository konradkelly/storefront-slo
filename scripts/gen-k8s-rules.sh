#!/bin/sh
# Wraps the Prometheus rule files in PrometheusRule resources for kube-prometheus-stack, so Compose and
# kind share one source of rules. Run from the repo root after editing anything in prometheus/rules/:
#   sh scripts/gen-k8s-rules.sh
set -eu

# gen <source> <output> <PrometheusRule name>
gen() {
  {
    echo "# GENERATED from $1 by scripts/gen-k8s-rules.sh. Edit the source and rerun; don't edit this file."
    echo "apiVersion: monitoring.coreos.com/v1"
    echo "kind: PrometheusRule"
    echo "metadata:"
    echo "  name: $3"
    echo "  namespace: storefront"
    echo "  labels:"
    echo "    release: kps"
    echo "spec:"
    # Drop the source's leading comment block and indent everything under spec:.
    sed -n '/^groups:/,$p' "$1" | sed 's/^\(.\)/  \1/'
  } > "$2"
  echo "wrote $2"
}

gen prometheus/rules/slo.yml k8s/base/slo-rules.yaml storefront-slo-rules
gen prometheus/rules/slo-alerts.yml k8s/base/slo-alerts.yaml storefront-slo-alerts
