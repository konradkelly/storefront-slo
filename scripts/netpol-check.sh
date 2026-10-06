#!/bin/bash
# Checks the storefront NetworkPolicies both ways: what should connect does, and what shouldn't is blocked.
# Starts short-lived test pods (restricted-compliant) that try a TCP connection and report it.
#   bash scripts/netpol-check.sh
set -u
cd "$(dirname "$0")/.."
k() { MSYS_NO_PATHCONV=1 kubectl --context kind-storefront "$@"; }
fails=0

# probe <name> <labels or ""> <host> <port> <expect: ALLOW|DENY>
probe() {
  local name=$1 labels=$2 host=$3 port=$4 expect=$5
  local lbl=""; [ -n "$labels" ] && lbl="--labels=$labels"
  local out
  # Not `run -i --rm`: the pod can finish before kubectl attaches, and the output is lost.
  k -n storefront delete pod "np-$name" --ignore-not-found >/dev/null 2>&1
  k -n storefront run "np-$name" --image=python:3.13.16-alpine --restart=Never $lbl \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"np","image":"python:3.13.16-alpine","securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},"command":["python","-c","import socket,sys\ntry:\n  socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=4).close(); print(\"ALLOW\")\nexcept Exception as e:\n  print(\"DENY\", type(e).__name__)","'"$host"'","'"$port"'"]}]}}' >/dev/null
  k -n storefront wait --for=jsonpath='{.status.phase}'=Succeeded "pod/np-$name" --timeout=90s >/dev/null 2>&1
  out=$(k -n storefront logs "np-$name" 2>&1 | grep -E "^(ALLOW|DENY)" | tail -1)
  k -n storefront delete pod "np-$name" --ignore-not-found --wait=false >/dev/null 2>&1
  local got=${out%% *}
  local mark="ok"; [ "$got" != "$expect" ] && { mark="UNEXPECTED"; fails=$((fails+1)); }
  printf '%-10s %-40s expect %-5s got %-28s %s\n' "$mark" "${labels:-<no labels>} -> $host:$port" "$expect" "$out" ""
}

echo "== from test pods"
probe lt-api   app.kubernetes.io/component=loadtest storefront-api        8080 ALLOW
probe lt-db    app.kubernetes.io/component=loadtest storefront-db-rw      5432 DENY
probe any-api  ""                                   storefront-api        8080 DENY
probe any-db   ""                                   storefront-db-rw      5432 DENY
probe any-web  ""                                   1.1.1.1               443  DENY

echo "== from the app (curl in the app image)"
p=$(k -n storefront get pods -l app=storefront-api --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
code=$(k -n storefront exec "$p" -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 localhost:8080/actuator/health)
[ "$code" = "200" ] && echo "ok         app health (includes its Postgres connection)        200" || { echo "UNEXPECTED app health: $code"; fails=$((fails+1)); }
if k -n storefront exec "$p" -- curl -s -o /dev/null --connect-timeout 4 https://1.1.1.1 >/dev/null 2>&1; then
  echo "UNEXPECTED app -> internet 1.1.1.1:443 connected"; fails=$((fails+1))
else
  echo "ok         app -> internet 1.1.1.1:443                       blocked"
fi

echo "== Prometheus scrapes (allowed from the monitoring namespace)"
k get --raw '/api/v1/namespaces/monitoring/services/prometheus-operated:9090/proxy/api/v1/targets?state=active' |
  "${PYTHON:-python}" -c "
import json,sys
t=[x for x in json.load(sys.stdin)['data']['activeTargets'] if x['labels'].get('namespace')=='storefront']
bad=[x for x in t if x['health']!='up']
for x in t: print(f\"{'ok' if x['health']=='up' else 'UNEXPECTED':10} {x['scrapePool']:45} {x['labels'].get('pod','')[:32]:32} {x['health']} {x['lastError'][:60]}\")
sys.exit(1 if bad or not t else 0)" || fails=$((fails+1))

echo "== CloudNativePG"
k -n storefront get cluster storefront-db -o jsonpath='phase={.status.phase} ready={.status.readyInstances}/{.status.instances}{"\n"}'
echo; [ "$fails" -eq 0 ] && echo "ALL CHECKS AS EXPECTED" || echo "$fails UNEXPECTED RESULT(S)"
exit "$fails"
