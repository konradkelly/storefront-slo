#!/bin/bash
# Experiment 3 (kind): steady checkout load, delete the CloudNativePG primary pod, measure the failover.
# Prints a per-second timeline of the Cluster status, the k6 summary, and app 5xx counts (raw counters too,
# because increase() misses the first sample of a newly created error series).
# Needs the kind environment from scripts/kind-up.sh. Takes about 13 minutes.
#   bash scripts/experiments/exp3-db-failover.sh
set -u
cd "$(dirname "$0")/../.."
k() { MSYS_NO_PATHCONV=1 kubectl --context kind-storefront "$@"; }
ts() { date -u +%H:%M:%S; }
raw5xx() { k -n storefront exec deploy/storefront-api -- sh -c 'wget -qO- http://localhost:8080/actuator/prometheus 2>/dev/null || curl -s localhost:8080/actuator/prometheus' | awk '/^http_server_requests_seconds_count\{.*status="5/ {n+=$NF} END {print n+0}'; }

k -n storefront create configmap k6-script --from-file=loadtest/checkout.js --dry-run=client -o yaml | k apply -f - >/dev/null
k -n storefront delete job k6-failover --ignore-not-found >/dev/null
sed -e 's/name: k6-load/name: k6-failover/' -e 's/value: browse/value: checkout-stress/' k8s/loadtest/k6-job.yaml |
  "${PYTHON:-python}" -c "
import sys,yaml
d=yaml.safe_load(sys.stdin)
env=d['spec']['template']['spec']['containers'][0]['env']
env+= [{'name':'VUS','value':'10'},{'name':'DURATION','value':'12m'}]
print(yaml.safe_dump(d))" | k apply -f - >/dev/null
echo "$(ts) EVENT k6 started: checkout-stress, 10 VUs, 12m"
start=$(date -u +%s)
before5xx=$(raw5xx)
echo "$(ts) raw 5xx counter at start: $before5xx"

sleep 180
primary=$(k -n storefront get cluster storefront-db -o jsonpath='{.status.currentPrimary}')
echo "$(ts) EVENT deleting primary pod $primary"
del=$(date -u +%s)
k -n storefront delete pod "$primary" --wait=false >/dev/null

prev=""
for i in $(seq 1 150); do
  line=$(k -n storefront get cluster storefront-db -o jsonpath='{.status.currentPrimary} {.status.targetPrimary} ready={.status.readyInstances} {.status.phase}')
  if [ "$line" != "$prev" ]; then echo "$(ts) +$(( $(date -u +%s) - del ))s cluster: $line"; prev="$line"; fi
  sleep 1
done

echo "$(ts) EVENT waiting for k6 to finish"
k -n storefront wait --for=condition=complete job/k6-failover --timeout=900s >/dev/null 2>&1
echo "--- k6 summary"
k -n storefront logs job/k6-failover | grep -E "checks_succeeded|checks_failed|http_req_failed|http_reqs|iterations\.|ERRO" | grep -v "running (" | head -12
echo "--- app 5xx and checkout outcomes during the run (Prometheus)"
end=$(date -u +%s)
win=$(( end - start ))
P='/api/v1/namespaces/monitoring/services/prometheus-operated:9090/proxy/api/v1/query'
q() { k get --raw "$P?query=$("${PYTHON:-python}" -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1")" | "${PYTHON:-python}" -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print('; '.join(' '.join(f'{k}={v}' for k,v in x['metric'].items() if k in ('uri','status','method')) + ' -> ' + str(round(float(x['value'][1]))) for x in r) or 'none')"; }
echo "5xx by endpoint:  $(q "sum by (uri, status) (increase(http_server_requests_seconds_count{application=\"storefront-api\", status=~\"5..\"}[${win}s]))")"
echo "checkouts:        $(q "sum by (status) (increase(storefront_checkouts_total{application=\"storefront-api\"}[${win}s]))")"
echo "orders by status: $(q "sum by (status) (increase(http_server_requests_seconds_count{application=\"storefront-api\", uri=\"/orders\"}[${win}s]))")"
echo "raw 5xx counter: start=$before5xx end=$(raw5xx) (app counters, no increase() blind spot)"
echo "delete_epoch=$del start_epoch=$start end_epoch=$end"
