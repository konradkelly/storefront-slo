#!/bin/bash
# Experiment 2: slow burn. 2% payment failures (4x): should open a ticket and never page.
# Also records what the removed threshold alert ("failure ratio > 5% for 5m") would have seen.
# WARNING: clears Prometheus storage (docker compose rm -sfv prometheus) and recreates the API.
# Run from Git Bash with the Compose stack up. See scripts/experiments/README.md.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python}"
BASELINE_MIN="${BASELINE_MIN:-60}"
cd "$HERE/../.."
event() { echo "$(date -u +%H:%M:%S) EVENT $*"; }
old_ratio() {
  curl -s --get localhost:9090/api/v1/query --data-urlencode \
    'query=sum(rate(storefront_checkouts_total{status!="success"}[5m])) / sum(rate(storefront_checkouts_total[5m]))' |
    "$PYTHON" -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(f\"{float(r[0]['value'][1])*100:.1f}%\" if r else '-')"
}
snap() { echo "$("$PYTHON" "$HERE/snap.py" "$1") | old-threshold-ratio5m=$(old_ratio)"; }
state() {
  curl -s localhost:9090/api/v1/alerts | "$PYTHON" -c "
import json,sys
a=[x for x in json.load(sys.stdin)['data']['alerts'] if x['labels']['alertname']=='StorefrontCheckoutAvailabilityBudgetBurn' and x['labels'].get('severity')=='$1']
print(a[0]['state'] if a else 'inactive')"
}

event "clearing Prometheus storage"
docker compose rm -sfv prometheus >/dev/null 2>&1
docker compose up -d prometheus >/dev/null 2>&1
PAYMENT_FAILURE_RATE=0.001 docker compose up -d storefront-api >/dev/null 2>&1
until curl -sf localhost:9090/-/ready >/dev/null && curl -sf localhost:8080/actuator/health >/dev/null; do sleep 3; done
docker rm -f k6-exp >/dev/null 2>&1
docker compose --profile load run -d --name k6-exp --no-deps -e DURATION=4h -e VUS=30 k6 >/dev/null 2>&1
event "k6 browse profile started, 30 VUs (baseline, 0.1% payment failures)"

for i in $(seq 1 "$BASELINE_MIN"); do snap baseline; sleep 60; done

event "SLOW BURN START: PAYMENT_FAILURE_RATE=0.02 (API recreated)"
PAYMENT_FAILURE_RATE=0.02 docker compose up -d storefront-api >/dev/null 2>&1
until curl -sf localhost:8080/actuator/health >/dev/null; do sleep 2; done

ticket=""; paged=""
for i in $(seq 1 150); do
  snap burn
  [ -z "$paged" ] && [ "$(state page)" != "inactive" ] && paged=1 && event "PAGE became $(state page) (unexpected)"
  if [ -z "$ticket" ] && [ "$(state ticket)" = "firing" ]; then ticket=$i; event "TICKET FIRING in Prometheus"; fi
  # Keep burning 30 minutes after the ticket to show the page stays quiet.
  [ -n "$ticket" ] && [ $((i - ticket)) -ge 30 ] && break
  sleep 60
done

event "RECOVERY: PAYMENT_FAILURE_RATE=0.001 (API recreated)"
PAYMENT_FAILURE_RATE=0.001 docker compose up -d storefront-api >/dev/null 2>&1
docker rm -f k6-exp >/dev/null 2>&1
event "done; page ever pending/firing: ${paged:-no}. alert-logger notifications during the experiment:"
docker compose logs --no-log-prefix --since 4h alert-logger | grep -v "TEST\|SlackSetup"
