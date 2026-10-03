#!/bin/bash
# Experiment 1: fast burn. 30% payment failures until the page fires (+5 min), then recover.
# Timeline goes to stdout (one snapshot per minute) plus EVENT lines for each action.
# WARNING: clears Prometheus storage (docker compose rm -sfv prometheus) and recreates the API.
# Run from Git Bash with the Compose stack up. See scripts/experiments/README.md.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python}"
BASELINE_MIN="${BASELINE_MIN:-60}"
cd "$HERE/../.."
snap() { "$PYTHON" "$HERE/snap.py" "$1"; }
event() { echo "$(date -u +%H:%M:%S) EVENT $*"; }
page_state() {
  curl -s localhost:9090/api/v1/alerts | "$PYTHON" -c "
import json,sys
a=[x for x in json.load(sys.stdin)['data']['alerts'] if x['labels']['alertname']=='StorefrontCheckoutAvailabilityBudgetBurn' and x['labels'].get('severity')=='page']
print(a[0]['state'] if a else 'inactive')"
}

event "clearing Prometheus storage"
docker compose rm -sfv prometheus >/dev/null 2>&1
docker compose up -d prometheus >/dev/null 2>&1
PAYMENT_FAILURE_RATE=0.001 docker compose up -d storefront-api >/dev/null 2>&1
until curl -sf localhost:9090/-/ready >/dev/null && curl -sf localhost:8080/actuator/health >/dev/null; do sleep 3; done
docker rm -f k6-exp >/dev/null 2>&1
docker compose --profile load run -d --name k6-exp --no-deps -e DURATION=3h -e VUS=30 k6 >/dev/null 2>&1
event "k6 browse profile started, 30 VUs (baseline, 0.1% payment failures)"

for i in $(seq 1 "$BASELINE_MIN"); do snap baseline; sleep 60; done

event "OUTAGE START: PAYMENT_FAILURE_RATE=0.3 (API recreated)"
PAYMENT_FAILURE_RATE=0.3 docker compose up -d storefront-api >/dev/null 2>&1
until curl -sf localhost:8080/actuator/health >/dev/null; do sleep 2; done
event "API healthy with 0.3"

fired=""
for i in $(seq 1 60); do
  snap outage
  if [ -z "$fired" ] && [ "$(page_state)" = "firing" ]; then fired=1; event "PAGE FIRING in Prometheus"; break; fi
  sleep 60
done
for i in $(seq 1 5); do sleep 60; snap outage; done

event "RECOVERY: PAYMENT_FAILURE_RATE=0.001 (API recreated)"
PAYMENT_FAILURE_RATE=0.001 docker compose up -d storefront-api >/dev/null 2>&1
until curl -sf localhost:8080/actuator/health >/dev/null; do sleep 2; done
event "API healthy with 0.001"

cleared=""
for i in $(seq 1 40); do
  sleep 60
  snap recovery
  if [ -z "$cleared" ] && [ "$(page_state)" = "inactive" ]; then cleared=1; event "PAGE CLEARED in Prometheus"; fi
done

event "done; alert-logger notifications during the experiment:"
docker compose logs --no-log-prefix --since 3h alert-logger | grep -v "TEST\|SlackSetup"
