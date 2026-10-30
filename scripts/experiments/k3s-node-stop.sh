#!/bin/bash
# Phase 4a experiment (k3s): stop one node's EC2 instance under load, start it again, and log what users and the
# cluster saw. Two probers (prober.py) run on this machine:
#   eip    through the server's Elastic IP, where all real traffic enters
#   agent  through an agent's own address (ServiceLB listens on every node): what a load balancer in front of all
#          nodes would have kept serving
# In-cluster load (k6, k8s/loadtest/k6-job.yaml) should already be running, on a node this run doesn't stop.
#   bash scripts/experiments/k3s-node-stop.sh server     # the control plane
#   bash scripts/experiments/k3s-node-stop.sh agent-1    # an agent, by its index in terraform/aws/k3s
# BASELINE_MIN (5), STOP_MIN (10) and RECOVERY_MIN (15) set the phases. Takes about 35 minutes.
set -u
cd "$(dirname "$0")/../.."
target=${1:?usage: k3s-node-stop.sh server|agent-N}
BASELINE_MIN=${BASELINE_MIN:-5} STOP_MIN=${STOP_MIN:-10} RECOVERY_MIN=${RECOVERY_MIN:-15}
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/storefront-k3s.yaml}"
command -v cygpath >/dev/null && KUBECONFIG=$(cygpath -w "$KUBECONFIG")
k() { MSYS_NO_PATHCONV=1 kubectl --context k3s-storefront --request-timeout=5s "$@"; }
tf() { terraform -chdir=terraform/aws/k3s "$@"; }
ts() { date -u +%H:%M:%S; }
event() { echo "$(ts) EVENT $*"; }
region=$(tf output -raw region)
ec2() { aws ec2 --region "$region" "$@"; }

agents=($(tf output -json agent_instance_ids | tr -d '[]" \r\n' | tr , ' '))
server=$(tf output -raw server_instance_id)
eip=$(tf output -raw server_public_ip)
case $target in
  server) id=$server probe_agent=${agents[0]} ;;
  agent-*) i=${target#agent-}; id=${agents[$i]:?no $target}; probe_agent=${agents[$(( (i + 1) % ${#agents[@]} ))]} ;;
  *) echo "usage: k3s-node-stop.sh server|agent-N"; exit 1 ;;
esac
private_ip() { ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text; }
node=$(k get nodes -o jsonpath="{.items[?(@.status.addresses[0].address=='$(private_ip "$id")')].metadata.name}")
agent_ip=$(ec2 describe-instances --instance-ids "$probe_agent" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

out=${OUT:-k3s-node-stop-$target-$(date -u +%m%d-%H%M)}
mkdir -p "$out"
total_s=$(( (BASELINE_MIN + STOP_MIN + RECOVERY_MIN + 8) * 60 ))
BASE_URL=http://$eip DURATION_S=$total_s "${PYTHON:-python}" -u scripts/experiments/prober.py > "$out/prober-eip.log" 2>&1 &
p1=$!
BASE_URL=http://$agent_ip DURATION_S=$total_s "${PYTHON:-python}" -u scripts/experiments/prober.py > "$out/prober-agent.log" 2>&1 &
p2=$!
trap 'kill $p1 $p2 2>/dev/null' EXIT

# Where everything runs decides what a node takes with it.
k get pods -A --no-headers -o custom-columns=N:.spec.nodeName,NS:.metadata.namespace,P:.metadata.name |
  awk '{print $1, $2, $3}' | sort > "$out/placement.txt"
event "target $target = $id = node $node; probers via $eip (eip) and $agent_ip (agent); placement in $out/placement.txt"
grep "^$node " "$out/placement.txt" | awk '{print "    on " $1 ": " $2 "/" $3}'

# One state line: nodes, API replicas, database, and each prober's latest 10 s window.
state() {
  local nodes api db
  nodes=$(k get nodes --no-headers 2>/dev/null | awk '{printf "%s=%s ", $1, $2}') || true
  api=$(k -n storefront get deploy storefront-api -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)
  db=$(k -n storefront get cluster storefront-db -o jsonpath='{.status.currentPrimary} {.status.readyInstances}/{.status.instances} {.status.phase}' 2>/dev/null)
  echo "$(ts) STATE nodes: ${nodes:-API unreachable}| api ${api:--} | db ${db:--}" \
    "| eip $(grep window "$out/prober-eip.log" | tail -1 | cut -d' ' -f3-4)" \
    "| agent $(grep window "$out/prober-agent.log" | tail -1 | cut -d' ' -f3-4)"
}
watch_for() { local end=$((SECONDS + $1 * 60)); while [ $SECONDS -lt $end ]; do state; sleep 30; done; }

watch_for "$BASELINE_MIN"
event "stop-instances $id"
ec2 stop-instances --instance-ids "$id" >/dev/null
ec2 wait instance-stopped --instance-ids "$id" && event "instance stopped"
watch_for "$STOP_MIN"
event "start-instances $id"
ec2 start-instances --instance-ids "$id" >/dev/null
ec2 wait instance-running --instance-ids "$id" && event "instance running"
until k get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  state; sleep 15
done
event "node $node Ready"
watch_for "$RECOVERY_MIN"
k -n storefront get pods -o wide > "$out/storefront-pods-after.txt"

kill $p1 $p2 2>/dev/null
echo "--- probers (FAIL lines: first, last, count by error)"
for p in eip agent; do
  f="$out/prober-$p.log"
  echo "$p: $(grep -c FAIL "$f") failed requests, first $(grep FAIL "$f" | head -1 | cut -d' ' -f1)," \
    "last $(grep FAIL "$f" | tail -1 | cut -d' ' -f1), last total: $(grep window "$f" | tail -1 | cut -d'|' -f2)"
  grep FAIL "$f" | awk '{print "    " $3, $4, $6}' | sort | uniq -c | sort -rn | head -5
done
