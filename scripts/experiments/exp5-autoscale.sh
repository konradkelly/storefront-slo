#!/bin/bash
# Experiment 5 (kind): how does the autoscaler react? 8 minutes of heavy checkout load, then 6 minutes idle.
# Every 15s: replicas, what the HPA sees, pod CPU, checkout p95. Works with the CPU HPA (hpa.yaml) and with KEDA
# (which creates its own HPA, keda-hpa-storefront-api).
# Needs the kind environment from scripts/kind-up.sh plus metrics-server. Takes about 15 minutes.
#   VUS=60 bash scripts/experiments/exp5-autoscale.sh
set -u
cd "$(dirname "$0")/../.."
k() { MSYS_NO_PATHCONV=1 kubectl --context kind-storefront "$@"; }
ts() { date -u +%H:%M:%S; }
VUS=${VUS:-60}
P='/api/v1/namespaces/monitoring/services/prometheus-operated:9090/proxy/api/v1/query'
prom() { k get --raw "$P?query=$("${PYTHON:-python}" -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1")" |
  "${PYTHON:-python}" -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(f\"{float(r[0]['value'][1]):.2f}\" if r else '-')"; }
ORD='application="storefront-api", uri="/orders", method="POST"'
sample() {
  hpa=$(k -n storefront get hpa -o jsonpath='{range .items[*]}{.metadata.name}:{range .status.currentMetrics[*]}{.resource.current.averageUtilization}{.external.current.averageValue}{.external.current.value} {end}{end}' 2>/dev/null)
  cpu=$(k -n storefront top pods -l app=storefront-api --no-headers 2>/dev/null | awk '{printf "%s ", $2}')
  p95=$(prom "histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{$ORD}[1m])))")
  rps=$(prom "sum(rate(http_server_requests_seconds_count{application=\"storefront-api\"}[1m]))")
  echo "$(ts) [$1] replicas=$(k -n storefront get deploy storefront-api -o jsonpath='{.status.readyReplicas}')/$(k -n storefront get deploy storefront-api -o jsonpath='{.spec.replicas}') hpa=[$hpa] pod-cpu=[$cpu] rps=$rps checkout-p95=${p95}s"
}

k -n storefront delete job k6-autoscale --ignore-not-found >/dev/null
k -n storefront create configmap k6-script --from-file=loadtest/checkout.js --dry-run=client -o yaml | k apply -f - >/dev/null
sed -e 's/name: k6-load/name: k6-autoscale/' -e 's/value: browse/value: checkout-stress/' k8s/loadtest/k6-job.yaml |
  "${PYTHON:-python}" -c "
import sys,yaml
d=yaml.safe_load(sys.stdin)
d['spec']['template']['spec']['containers'][0]['env'] += [{'name':'VUS','value':'$VUS'},{'name':'DURATION','value':'8m'}]
print(yaml.safe_dump(d))" | k apply -f - >/dev/null
echo "$(ts) EVENT load started: checkout-stress, $VUS VUs, 8m"
for i in $(seq 1 34); do sample load; sleep 15; done
k -n storefront wait --for=condition=complete job/k6-autoscale --timeout=300s >/dev/null 2>&1
echo "$(ts) EVENT load finished"
k -n storefront logs job/k6-autoscale | grep -E "http_req_duration|http_req_failed|http_reqs" | grep -v "running (" | sed 's/  */ /g'
for i in $(seq 1 24); do sample idle; sleep 15; done
k -n storefront delete job k6-autoscale --ignore-not-found >/dev/null
