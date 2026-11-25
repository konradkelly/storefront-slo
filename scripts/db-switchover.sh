#!/bin/bash
# Moves the database's primary role between k3s and EKS with CloudNativePG's planned switchover, then checks that no
# data was lost and that the old primary now follows the new one. Slice 3's rehearsal (docs/eks.md) runs it both ways:
#   bash scripts/db-switchover.sh eks    # k3s -> EKS
#   bash scripts/db-switchover.sh k3s    # EKS -> k3s, back to how git has it
# Needs both clusters up (make up, make eks-up) and their kubeconfigs in ~/.kube.
#
# How it works (k8s/overlays/k3s and k8s/overlays/eks have the topology):
#   1. let the new primary catch up first, so the write stop is short: switch WAL on the old one and wait until the
#      replica has replayed past that point from S3;
#   2. demote the old primary (its `replica.primary` names the other cluster). It stops writes, archives its last WAL
#      and writes a demotion token: its last position, timeline and system identifier;
#   3. promote the new primary with that token. CloudNativePG first replays up to the token's position, so nothing
#      written before the demotion is lost, then promotes. Without a token it would fail over instead, and the old
#      primary would have to be rebuilt;
#   4. compare the data on both sides, take a base backup on the new timeline, and check the old primary replays it.
#
# `primary` and the token are overrides on each cluster's storefront Argo CD Application (spec.source.kustomize
# .patches), not git, because steps 2 and 3 must reach the two clusters in that order. The root app leaves that field
# alone (scripts/argocd-up.sh), so the override survives Argo CD and reruns of make up/eks-up, and the soak drill
# removes only its own patch from the list. Deleting the storefront Application would drop it.
#
# The app's traffic doesn't move: each cluster's app uses its own database, so the old side's writes fail from step 2
# on. Moving traffic is the cutover's DNS step (slice 5).
set -euo pipefail
cd "$(dirname "$0")/.."

to=${1:-}
case "$to" in
  eks) from=k3s ;;
  k3s) from=eks ;;
  *) echo "usage: $0 eks|k3s   (the cluster whose database becomes the primary)" >&2; exit 2 ;;
esac
git_primary=k3s # what both overlays say

kc() {
  local c=$1 f="$HOME/.kube/storefront-$1.yaml"
  shift
  command -v cygpath >/dev/null && f=$(cygpath -w "$f")
  MSYS_NO_PATHCONV=1 kubectl --kubeconfig "$f" --context "$c-storefront" "$@"
}
pod() { kc "$1" -n storefront get cluster storefront-db -o jsonpath='{.status.currentPrimary}'; }
sql() { kc "$1" -n storefront exec "$(pod "$1")" -c postgres -- psql -d storefront -AtXq -c "$2"; }
in_recovery() { sql "$1" 'select pg_is_in_recovery()'; }
now() { date +%s; }
say() { echo "== $(date +%T) $*"; }
# wait_for <seconds> <description> <command...>: retries the command every 5 s
wait_for() {
  local limit=$1 what=$2 start
  shift 2
  start=$(now)
  until "$@" >/dev/null 2>&1; do
    [ $(($(now) - start)) -ge "$limit" ] && { echo "Gave up after ${limit}s waiting for $what" >&2; exit 1; }
    sleep 5
  done
  echo "   $what: $(($(now) - start))s"
}
replayed_past() { [ "$(sql "$1" "select pg_last_wal_replay_lsn() >= '$2'::pg_lsn")" = t ]; }
is_primary() { [ "$(in_recovery "$1")" = f ]; }
is_replica() { [ "$(in_recovery "$1")" = t ]; }
demotion_token() { kc "$1" -n storefront get cluster storefront-db -o jsonpath='{.status.demotionToken}'; }
has_token() { [ -n "$(demotion_token "$1")" ]; }
backup_done() { [ "$(kc "$1" -n storefront get backup "$2" -o jsonpath='{.status.phase}')" = completed ]; }
timeline() { sql "$1" "select ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int"; }

# Every row of every table, hashed, so equal means the same data, not only the same counts.
fingerprint() {
  sql "$1" "select (select count(*) from orders) || ' orders, ' || (select count(*) from order_lines) || ' order lines, '
    || (select count(*) from cart_items) || ' cart items, ' || (select count(*) from product) || ' products; md5 '
    || (select md5(string_agg(x, '|' order by x)) from (
          select 'p' || t::text from product t union all select 'c' || t::text from cart_items t
          union all select 'o' || t::text from orders t union all select 'l' || t::text from order_lines t) s(x))"
}

# override <cluster> <primary> [token]: sets this tool's patch on the Cluster; none at all when it matches git.
override() {
  local c=$1 primary=$2 token=${3:-} body
  body=$(kc "$c" -n argocd get application storefront -o json | python -c '
import json, sys
app, primary, token, git_primary = json.load(sys.stdin), sys.argv[1], sys.argv[2], sys.argv[3]
patches = [p for p in (app["spec"]["source"].get("kustomize") or {}).get("patches") or []
           if p.get("target", {}).get("kind") != "Cluster"]
if primary != git_primary or token:
    ops = [{"op": "replace", "path": "/spec/replica/primary", "value": primary}]
    if token:
        ops.append({"op": "add", "path": "/spec/replica/promotionToken", "value": token})
    patches.append({"target": {"kind": "Cluster", "name": "storefront-db"}, "patch": json.dumps(ops)})
print(json.dumps({"metadata": {"resourceVersion": app["metadata"]["resourceVersion"]},
                  "spec": {"source": {"kustomize": {"patches": patches} if patches else None}}}))
' "$primary" "$token" "$git_primary")
  kc "$c" -n argocd patch application storefront --type merge -p "$body" >/dev/null
}
spec_primary() { kc "$1" -n storefront get cluster storefront-db -o jsonpath='{.spec.replica.primary}'; }

say "Checking: $from is the primary, $to its replica"
for c in k3s eks; do
  kc "$c" -n storefront get cluster storefront-db >/dev/null || { echo "No database on $c" >&2; exit 1; }
done
is_primary "$from" || { echo "$from's database isn't the primary: nothing to switch from" >&2; exit 1; }
! is_primary "$to" || { echo "$to's database is already a primary" >&2; exit 1; }
[ "$(spec_primary "$to")" = "$from" ] || { echo "$to's Cluster doesn't name $from as the primary" >&2; exit 1; }
for c in "$from" "$to"; do
  echo "   $c: $(kc "$c" -n storefront get cluster storefront-db -o jsonpath='{.status.phase}'), primary pod $(pod "$c")"
done

say "Letting $to catch up before writes stop"
lsn=$(sql "$from" 'select pg_current_wal_lsn()')
sql "$from" 'select pg_switch_wal()' >/dev/null
wait_for 900 "$to replayed past $lsn from the archive" replayed_past "$to" "$lsn"

say "Demoting $from: writes stop here"
stopped=$(now)
override "$from" "$to"
wait_for 300 "$from's demotion token" has_token "$from"
token=$(demotion_token "$from")
# Postgres restarts as a replica after the shutdown checkpoint the token describes.
wait_for 300 "$from back up as a replica" is_replica "$from"
before=$(fingerprint "$from")
echo "   $from at demotion: $before"

say "Promoting $to with the token"
override "$to" "$to" "$token"
wait_for 900 "$to promoted" is_primary "$to"
echo "   writes stopped for $(($(now) - stopped))s"
after=$(fingerprint "$to")
echo "   $to after promotion: $after"
if [ "$before" != "$after" ]; then
  # The app on $to can write from the moment of promotion, so with traffic on $to a difference can be a new write.
  echo "DATA DIFFERS between the demoted $from and the promoted $to. Unless $to's app wrote in the seconds since" >&2
  echo "promotion, rows were lost: stop and look before writing anything." >&2
  exit 1
fi
echo "   same data on both sides"
sql "$to" 'select txid_current()' >/dev/null && echo "   $to accepts writes"
# The token is only read at promotion. Keep `primary` (or nothing, when it's what git says).
override "$to" "$to"

say "A base backup on $to's new timeline"
# The archive's newest base backup is what a restore starts from (make up on k3s, make eks-up), and it should be on
# the timeline this database writes now.
backup="switchover-$(date -u +%Y%m%d%H%M%S)"
kc "$to" -n storefront create -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $backup
  namespace: storefront
spec:
  cluster:
    name: storefront-db
  target: primary
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
wait_for 900 "backup $backup completed" backup_done "$to" "$backup"

say "Checking $from now follows $to"
# CloudNativePG restarts the new primary once, a few seconds after promotion (2026-11-25: 50 s after).
sleep 30
wait_for 300 "$to accepting connections" is_primary "$to"
lsn=$(sql "$to" 'select pg_current_wal_lsn()')
sql "$to" 'select pg_switch_wal()' >/dev/null
wait_for 900 "$from replayed past $lsn from $to's archive" replayed_past "$from" "$lsn"
echo "   $to writes timeline $(timeline "$to")"

say "Done: $to's database is the primary, and $from's replays it"
echo "The app on $from now gets errors on every write. Switch back: bash scripts/db-switchover.sh $from"
