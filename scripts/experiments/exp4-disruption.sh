#!/bin/bash
# Experiment 4 (kind): what do routine disruptions cost? Under steady checkout load, run
#   1. a rolling restart (what every deploy does), then
#   2. a node drain of the app's pods (what a node upgrade or scale-down does; goes through the eviction API,
#      so a PodDisruptionBudget applies),
# and log every failed request with a timestamp from prober.py, a separate pod whose counts don't reset when
# app pods restart.
# Needs the kind environment from scripts/kind-up.sh. Takes about 12 minutes.
#   bash scripts/experiments/exp4-disruption.sh
set -u
cd "$(dirname "$0")/../.."
k() { MSYS_NO_PATHCONV=1 kubectl --context kind-storefront "$@"; }
ts() { date -u +%H:%M:%S; }
event() { echo "$(ts) EVENT $*"; }

k -n storefront delete job k6-disruption --ignore-not-found >/dev/null
k -n storefront delete pod prober --ignore-not-found >/dev/null
k -n storefront create configmap k6-script --from-file=loadtest/checkout.js --dry-run=client -o yaml | k apply -f - >/dev/null
k -n storefront create configmap prober-script --from-file=prober.py=scripts/experiments/prober.py --dry-run=client -o yaml | k apply -f - >/dev/null

sed -e 's/name: k6-load/name: k6-disruption/' -e 's/value: browse/value: checkout-stress/' k8s/loadtest/k6-job.yaml |
  "${PYTHON:-python}" -c "
import sys,yaml
d=yaml.safe_load(sys.stdin)
d['spec']['template']['spec']['containers'][0]['env'] += [{'name':'VUS','value':'10'},{'name':'DURATION','value':'11m'}]
print(yaml.safe_dump(d))" | k apply -f - >/dev/null
k -n storefront run prober --image=python:3.13.16-alpine --restart=Never --env=DURATION_S=660 --labels=app.kubernetes.io/component=loadtest \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"prober","image":"python:3.13.16-alpine","command":["python","-u","/app/prober.py"],"env":[{"name":"DURATION_S","value":"660"}],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},"volumeMounts":[{"name":"s","mountPath":"/app"}]}],"volumes":[{"name":"s","configMap":{"name":"prober-script"}}]}}' >/dev/null
k -n storefront wait --for=condition=Ready pod/prober --timeout=120s >/dev/null
event "load + prober started; replicas=$(k -n storefront get deploy storefront-api -o jsonpath='{.spec.replicas}'), pdb=$(k -n storefront get pdb -o name 2>/dev/null | tr '\n' ' ')"
sleep 120

event "1. rolling restart"
k -n storefront rollout restart deploy/storefront-api >/dev/null
k -n storefront rollout status deploy/storefront-api --timeout=600s >/dev/null
event "1. rollout complete"
sleep 90

node=$(k -n storefront get pods -l app=storefront-api -o jsonpath='{.items[0].spec.nodeName}')
event "2. drain app pods from $node"
# Like a real drain: evict (respecting the PodDisruptionBudget), keep the node cordoned for a maintenance window,
# then bring it back. Don't wait for replacements before uncordoning; they may need this node.
k drain "$node" --pod-selector=app=storefront-api --ignore-daemonsets --delete-emptydir-data --timeout=600s 2>&1 | grep -vE "^node/|evicting pod" | sed 's/^/    /'
event "2. evictions done; maintenance window (node cordoned)"
k -n storefront wait --for=jsonpath='{.status.availableReplicas}'=3 deploy/storefront-api --timeout=90s >/dev/null 2>&1 &&
  event "2. replacement Ready while node still cordoned" || event "2. replacement NOT Ready within 90s while cordoned"
k uncordon "$node" >/dev/null
event "2. $node uncordoned"
k -n storefront rollout status deploy/storefront-api --timeout=600s >/dev/null

k -n storefront wait --for=jsonpath='{.status.phase}'=Succeeded pod/prober --timeout=900s >/dev/null 2>&1
echo "--- prober failures and 10s windows with failures:"
k -n storefront logs prober | grep -E "FAIL|fail=[1-9]|DONE"
echo "--- k6:"
k -n storefront wait --for=condition=complete job/k6-disruption --timeout=300s >/dev/null 2>&1
k -n storefront logs job/k6-disruption | grep -E "http_req_failed|http_reqs|checks_failed" | grep -v "running ("
k -n storefront delete pod prober --ignore-not-found >/dev/null
