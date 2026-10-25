#!/bin/bash
# The k3s soak drill (docs/k3s.md): on top of the steady k6 soak, a slow burn that should open a ticket and never
# page, then a fast burn that should page. Each one is remediated by setting the rate back (k3s-fault.sh), a fixed
# time after its alert fires. Logs a timeline line every minute (snap.py) plus EVENT lines: the raw material for the
# postmortems. Real Slack notifications go out.
#
#   SLOW_AT=2026-10-26T08:00:00Z PAGE_AT=2026-10-27T16:00:00Z END_AT=2026-10-28T07:25:00Z \
#     bash scripts/experiments/k3s-soak-drill.sh >> soak-drill.log 2>&1
#
# Runs on your machine, and does nothing while it sleeps (keep-awake.ps1 helps; closing the lid still sleeps).
# Times are compared with the clock, so a sleep delays steps instead of skipping them. Progress is kept in
# soak-drill.state, so starting it again resumes where it stopped. If it dies mid-burn, the fault stays on:
# bash scripts/experiments/k3s-fault.sh 0.001 remediation
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PYTHON="${PYTHON:-python}"
: "${SLOW_AT:?}" "${PAGE_AT:?}" "${END_AT:?}"
SLOW_RATE=${SLOW_RATE:-0.02}             # 4x burn: exp2
PAGE_RATE=${PAGE_RATE:-0.30}             # 60x burn: exp1
BASE_RATE=0.001
TICKET_RESPONSE_MIN=${TICKET_RESPONSE_MIN:-30} # a ticket is worked soon, not dropped-everything
PAGE_RESPONSE_MIN=${PAGE_RESPONSE_MIN:-5}      # as exp1
SLOW_MAX_H=${SLOW_MAX_H:-14}             # revert anyway if no ticket by then
PAGE_MAX_MIN=${PAGE_MAX_MIN:-60}         # revert anyway if no page by then
STATE="${STATE:-$REPO/soak-drill.state}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/storefront-k3s.yaml}"
# MSYS_NO_PATHCONV below also stops Git Bash converting this for kubectl.exe, so hand it a Windows path.
command -v cygpath >/dev/null && KUBECONFIG=$(cygpath -w "$KUBECONFIG")
server_ip=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https://([^:]+):.*#\1#')
export PROM="${PROM:-http://prometheus.$server_ip.sslip.io}"

event() { echo "$(date -u +%H:%M:%S) EVENT $*"; }
epoch() { date -u -d "$1" +%s; }
fault() { bash "$HERE/k3s-fault.sh" "$@" || event "k3s-fault.sh $* failed"; }
snapshot() {
  MSYS_NO_PATHCONV=1 kubectl --context k3s-storefront -n monitoring create job --from=cronjob/grafana-snapshots \
    "snap-$(date -u +%m%d-%H%M)-$1" >/dev/null && event "snapshot job snap-...-$1 started"
}
# firing, pending or inactive for the checkout availability alert of one severity; ? if Prometheus can't be reached
alert() {
  curl -s --max-time 10 "$PROM/api/v1/alerts" | "$PYTHON" -c "
import json,sys
try:
    a=[x for x in json.load(sys.stdin)['data']['alerts'] if x['labels']['alertname']=='StorefrontCheckoutAvailabilityBudgetBurn' and x['labels'].get('severity')=='$1']
    print(a[0]['state'] if a else 'inactive')
except Exception:
    print('?')"
}

phase=baseline since=$(date -u +%s)
# shellcheck disable=SC1090
[ -s "$STATE" ] && . "$STATE"
set_phase() { phase=$1 since=$(date -u +%s); printf 'phase=%s since=%s\n' "$phase" "$since" > "$STATE"; event "phase $phase"; }
event "drill running in phase $phase: slow burn $SLOW_RATE at $SLOW_AT, page burn $PAGE_RATE at $PAGE_AT, end $END_AT"
prev_ticket="" prev_page=""

while [ "$phase" != done ]; do
  now=$(date -u +%s) mins=$(( ($(date -u +%s) - since) / 60 ))
  ticket=$(alert ticket) page=$(alert page)
  [ "$ticket" != "$prev_ticket" ] && [ -n "$prev_ticket" ] && event "ticket alert: $prev_ticket -> $ticket"
  [ "$page" != "$prev_page" ] && [ -n "$prev_page" ] && event "page alert: $prev_page -> $page"
  prev_ticket=$ticket prev_page=$page
  "$PYTHON" "$HERE/snap.py" "$phase"

  case $phase in
    baseline)
      [ "$now" -ge "$(epoch "$SLOW_AT")" ] && { fault "$SLOW_RATE" "slow burn"; set_phase slow; } ;;
    slow)
      [ "$page" = firing ] && event "PAGE FIRED DURING THE SLOW BURN: it should only open a ticket"
      if [ "$ticket" = firing ]; then
        snapshot ticket-fired; set_phase slow-ticket
      elif [ "$mins" -ge $((SLOW_MAX_H * 60)) ]; then
        event "no ticket after ${SLOW_MAX_H}h of slow burn, remediating anyway"
        fault "$BASE_RATE" "remediation, no ticket"; set_phase recovered-slow
      fi ;;
    slow-ticket)
      [ "$mins" -ge "$TICKET_RESPONSE_MIN" ] && { fault "$BASE_RATE" "remediation"; set_phase recovered-slow; } ;;
    recovered-slow)
      [ "$now" -ge "$(epoch "$PAGE_AT")" ] && { fault "$PAGE_RATE" "fast burn"; set_phase fast; } ;;
    fast)
      if [ "$page" = firing ]; then
        snapshot page-fired; set_phase fast-page
      elif [ "$mins" -ge "$PAGE_MAX_MIN" ]; then
        event "no page after ${PAGE_MAX_MIN} min of fast burn, remediating anyway"
        fault "$BASE_RATE" "remediation, no page"; set_phase recovered-fast
      fi ;;
    fast-page)
      [ "$mins" -ge "$PAGE_RESPONSE_MIN" ] && { fault "$BASE_RATE" "remediation"; set_phase recovered-fast; } ;;
    recovered-fast)
      if [ "$now" -ge "$(epoch "$END_AT")" ]; then
        snapshot end && sleep 240
        bucket="storefront-k3s-backups-$(aws sts get-caller-identity --query Account --output text)"
        aws s3 sync "s3://$bucket/grafana-snapshots/" "$REPO/grafana-snapshots/" --no-progress >/dev/null &&
          event "snapshots downloaded to grafana-snapshots/"
        set_phase done
      fi ;;
  esac
  sleep 60
done
event "drill finished. Tear down with: make down && make unkeep"
