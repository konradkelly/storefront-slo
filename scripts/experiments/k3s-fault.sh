#!/bin/bash
# Sets PAYMENT_FAILURE_RATE on k3s the only way that sticks: through git. Argo CD self-heals, so `kubectl set env`
# would be reverted within minutes. Commits k8s/overlays/k3s/payment-fault.yaml to main from a throwaway clone (your
# working tree is left alone), with [skip ci] so the release workflow doesn't roll out a new image in the middle of
# a drill. Then asks Argo CD to sync now, waits for the rollout, and takes a Grafana snapshot set.
#   bash scripts/experiments/k3s-fault.sh 0.02 "slow burn"
#   bash scripts/experiments/k3s-fault.sh 0.001 "remediation"      (0.001 is the base rate)
# Prints EVENT lines for the timeline. The push is what matters: if the cluster can't be reached (your IP changed),
# Argo CD still applies the commit, and only the waiting and the snapshot are skipped.
set -euo pipefail
rate=${1:?usage: k3s-fault.sh RATE [reason]}
reason=${2:-}
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FILE=k8s/overlays/k3s/payment-fault.yaml
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/storefront-k3s.yaml}"
k() { MSYS_NO_PATHCONV=1 kubectl --context k3s-storefront "$@"; }
event() { echo "$(date -u +%H:%M:%S) EVENT $*"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q --depth 50 --branch main "$(git -C "$REPO" remote get-url origin)" "$work"
current=$(sed -n 's/^ *value: "\(.*\)"$/\1/p' "$work/$FILE")
if [ "$current" = "$rate" ]; then
  event "PAYMENT_FAILURE_RATE is already $rate in git"
else
  sed -i "s/^\( *value: \)\"[^\"]*\"$/\1\"$rate\"/" "$work/$FILE"
  git -C "$work" commit -q -am "k3s fault: PAYMENT_FAILURE_RATE $current -> $rate${reason:+ ($reason)} [skip ci]"
  for _ in 1 2 3; do
    git -C "$work" push -q origin main && break
    git -C "$work" pull -q --rebase origin main # the release bot pushed in between
  done
  event "pushed $(git -C "$work" rev-parse --short HEAD): PAYMENT_FAILURE_RATE $current -> $rate${reason:+ ($reason)}"
fi

k -n argocd annotate application storefront argocd.argoproj.io/refresh=normal --overwrite >/dev/null ||
  { event "cluster unreachable: Argo CD will pick the commit up on its own (polls every 3 min)"; exit 0; }
live() {
  k -n storefront get deploy storefront-api \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PAYMENT_FAILURE_RATE")].value}'
}
for _ in $(seq 60); do [ "$(live)" = "$rate" ] && break; sleep 10; done
if [ "$(live)" != "$rate" ]; then
  event "Argo CD hasn't applied $rate after 10 min (live: $(live)). Check: kubectl -n argocd get application storefront"
  exit 1
fi
event "Argo CD applied PAYMENT_FAILURE_RATE=$rate, rolling out"
k -n storefront rollout status deploy/storefront-api --timeout=10m >/dev/null && event "rollout complete"
k -n monitoring create job --from=cronjob/grafana-snapshots "snap-$(date -u +%m%d-%H%M)-rate-${rate//./-}" >/dev/null &&
  event "snapshot job started"
