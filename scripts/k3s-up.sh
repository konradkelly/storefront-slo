#!/bin/bash
# Phase 4a: from an empty AWS account (plus terraform/aws/bootstrap, applied once) to the storefront on k3s with
# the same monitoring, SLO rules and dashboards as kind. Safe to rerun: it also re-applies on an existing cluster
# and updates the security group if your public IP changed. The script makes the machines, the kubeconfig and the
# Secrets; Argo CD installs everything else from GitHub (k8s/platform, values-k3s.yaml).
#   bash scripts/k3s-up.sh        (or: make up)
#
# COSTS MONEY while it exists: a t3.large server + 2 t3.medium agents + 3 public IPv4 + 90 GB gp3 ≈ $0.19/hr
# ≈ $4.60/day.
# `make down` (scripts/k3s-down.sh) stops that, and .github/workflows/k3s-nightly-destroy.yml runs it every night in
# case you forget. Only the backup bucket stays, at under a cent a month.
#
# Needs: terraform >= 1.10, aws CLI (logged in), kubectl, curl.
set -euo pipefail
cd "$(dirname "$0")/.."

CTX=k3s-storefront
export KUBECONFIG="$HOME/.kube/storefront-k3s.yaml" # its own file: never merged into your main kubeconfig
source scripts/lib/bootstrap.sh # k(), step(), the Slack Secret
tf() { terraform -chdir=terraform/aws/k3s "$@"; }

step "Terraform: VPC, security group, IAM, 1 server + 2 agents"
account=$(aws sts get-caller-identity --query Account --output text)
bucket="storefront-k3s-backups-$account"
aws s3api head-bucket --bucket "$bucket" 2>/dev/null || {
  echo "No bucket $bucket: apply terraform/aws/bootstrap first (docs/k3s.md)"; exit 1; }
tf init -input=false -reconfigure -backend-config="bucket=storefront-pulse-tfstate-$account" >/dev/null
my_ip=$(curl -sf https://checkip.amazonaws.com | tr -d '[:space:]')
echo "Kubernetes API and HTTP open to $my_ip/32 only"
# A tfvars file instead of -var: Git Bash would rewrite a "/32" argument as a Windows path.
printf '{"admin_cidrs": ["%s/32"]}\n' "$my_ip" > terraform/aws/k3s/admin.auto.tfvars.json
tf apply -input=false -auto-approve
server_ip=$(tf output -raw server_public_ip)
region=$(tf output -raw region)

step "kubeconfig (the server publishes it to SSM Parameter Store once k3s is up)"
param=$(tf output -raw kubeconfig_parameter)
for i in $(seq 90); do
  # MSYS_NO_PATHCONV: Git Bash would rewrite the "/storefront-k3s/..." name as a Windows path.
  value=$(MSYS_NO_PATHCONV=1 aws ssm get-parameter --region "$region" --name "$param" --with-decryption --query Parameter.Value --output text)
  [ "$value" != pending ] && break
  [ "$i" = 90 ] && { echo "k3s didn't publish a kubeconfig in 15 minutes. Read /var/log/storefront-k3s-init.log on the server:"; \
    echo "  aws ssm start-session --target $(tf output -raw server_instance_id)"; exit 1; }
  sleep 10
done
mkdir -p "$HOME/.kube"
(umask 077 && printf '%s\n' "$value" > "$KUBECONFIG")
echo "Wrote $KUBECONFIG (context $CTX)"

step "nodes"
until [ "$(k get nodes --no-headers 2>/dev/null | wc -l)" -ge 3 ]; do sleep 5; done
k wait --for=condition=Ready nodes --all --timeout=600s
k get nodes -L topology.kubernetes.io/zone

step "Secrets (the only cluster state that isn't in git)"
create_slack_secret
# Grafana Cloud remote write keeps a curated set of metrics after make down (k8s/platform/files/kps-remote-write.yaml).
gc_env=k8s/monitoring/secrets/grafana-cloud.env
gc_url=
if [ -s "$gc_env" ]; then
  gc() { sed -n "s/^$1=//p" "$gc_env" | tr -d '\r' | tail -1; }
  gc_url=$(gc GRAFANA_CLOUD_PROM_URL) gc_user=$(gc GRAFANA_CLOUD_PROM_USER) gc_token=$(gc GRAFANA_CLOUD_TOKEN)
  [ -n "$gc_url" ] && [ -n "$gc_user" ] && [ -n "$gc_token" ] || { echo "$gc_env needs GRAFANA_CLOUD_PROM_URL, _USER and _TOKEN"; exit 1; }
  gc_creds=$(mktemp)
  (umask 077 && printf 'username=%s\npassword=%s\n' "$gc_user" "$gc_token" > "$gc_creds")
  k -n monitoring create secret generic grafana-cloud --from-env-file="$gc_creds" --dry-run=client -o yaml | k apply -f -
  rm -f "$gc_creds"
  echo "Sending curated metrics to $gc_url"
else
  echo "No $gc_env: metrics stay in the cluster and are gone after make down (see k8s/monitoring/secrets/README.md)"
fi
# S3 credentials for Postgres backups (k8s/overlays/k3s/backups.yaml) and the hourly Grafana snapshots
# (k8s/monitoring/grafana-snapshots.yaml).
k apply -f k8s/base/namespace.yaml # with its Pod Security labels; Argo CD adopts it
creds=$(mktemp)
(umask 077 && {
  echo "ACCESS_KEY_ID=$(tf output -raw backup_access_key_id)"
  echo "ACCESS_SECRET_KEY=$(tf output -raw backup_secret_access_key)"
  echo "AWS_REGION=$region"
} > "$creds")
k -n storefront create secret generic storefront-backup-s3 --from-env-file="$creds" --dry-run=client -o yaml | k apply -f -
echo "BUCKET=$bucket" >> "$creds" # kubectl 1.36 refuses --from-env-file with --from-literal
k -n monitoring create secret generic grafana-snapshots-s3 --from-env-file="$creds" --dry-run=client -o yaml | k apply -f -
rm -f "$creds"

step "Database: new, restored from S3, or the one already running"
# The bucket outlives the instances (make down, the nightly destroy, a changed boot script), and their volumes don't. So
# a new database usually finds the previous one's archive. It restores from it (k8s/overlays/k3s-restore), and since a
# database only archives into an empty folder, the archive moves from storefront-db/ to storefront-db-previous/ first.
# The move copies everything before deleting anything, and deletes the backup.info files first, so a rerun after an
# interruption never mistakes a half-moved archive for a complete one.
#
# A backup restores only if every WAL segment from its start to its end reached the archive. On 2026-11-12 one was
# marked DONE without its last segment, because the old database had stopped archiving, and every restore failed
# with "WAL ends before end of online backup": CloudNativePG restores the newest backup. So the backup.info of a
# backup missing WAL moves to unrestorable/, which hides the backup from the restore, and the newest complete one
# is used instead. With none complete, stop: falling back to an older archive would delete this one (below).
archive="s3://$bucket/storefront-db"
wal_segments() { # $1 to $2, two segment names on one timeline. 16 MiB segments: 256 to each 4 GiB "log" number.
  local tli=${1:0:8} n
  for ((n = 16#${1:8:8} * 256 + 16#${1:16:8}; n <= 16#${2:8:8} * 256 + 16#${2:16:8}; n++)); do
    printf '%s%08X%08X\n' "$tli" $((n / 256)) $((n % 256))
  done
}
has_base_backup() { # a completed base backup in this archive folder, with all its WAL archived
  local f id info seg wals found=1 hidden=0
  wals=$(aws s3 ls "$archive/$1/wals/" --recursive | awk '{print $4}' | sed 's#.*/##' || true)
  for f in $(aws s3 ls "$archive/$1/base/" --recursive | awk '/backup\.info$/ {print $4}'); do
    info=$(aws s3 cp "s3://$bucket/$f" -)
    grep -q '^status=DONE' <<<"$info" || continue
    id=$(basename "$(dirname "$f")")
    for seg in $(wal_segments "$(sed -n 's/^begin_wal=//p' <<<"$info")" "$(sed -n 's/^end_wal=//p' <<<"$info")"); do
      # A segment, compressed or not. Not a .partial, nor a backup's history file (<segment>.<offset>.backup).
      grep -qxE "$seg(\.(gz|bz2|xz|lz4|zst|snappy))?" <<<"$wals" && continue
      echo "Backup $id needs WAL $seg, which never reached $archive/$1: moving its backup.info to unrestorable/"
      aws s3 mv "s3://$bucket/$f" "$archive/$1/unrestorable/$id.backup.info" --only-show-errors
      hidden=1
      continue 2
    done
    found=0
  done
  if [ "$found" = 1 ] && [ "$hidden" = 1 ]; then
    echo "No backup in $archive/$1 has all its WAL. Stopping rather than restore an older archive and delete this" >&2
    echo "one. Choose by hand: docs/k3s.md, \"Keeping the data\"." >&2
    exit 1
  fi
  return "$found"
}
storefront_path=k8s/overlays/k3s
if k -n storefront get cluster storefront-db >/dev/null 2>&1; then
  # Its bootstrap only mattered when it was created: keep the overlay it was created with.
  storefront_path=$(k -n argocd get application storefront -o jsonpath='{.spec.source.path}' 2>/dev/null || true)
  storefront_path=${storefront_path:-k8s/overlays/k3s}
  echo "The database exists: keeping $storefront_path"
elif has_base_backup storefront-db; then
  echo "The previous database's archive is in $archive/storefront-db: moving it to storefront-db-previous to restore from"
  aws s3 rm "$archive/storefront-db-previous/" --recursive --only-show-errors # an older one, superseded
  aws s3 cp "$archive/storefront-db/" "$archive/storefront-db-previous/" --recursive --only-show-errors
  aws s3 rm "$archive/storefront-db/" --recursive --exclude '*' --include '*backup.info' --only-show-errors
  aws s3 rm "$archive/storefront-db/" --recursive --only-show-errors
  storefront_path=k8s/overlays/k3s-restore
elif has_base_backup storefront-db-previous; then
  echo "Restoring from $archive/storefront-db-previous (moved there by an earlier run)"
  storefront_path=k8s/overlays/k3s-restore
else
  echo "No base backup in $archive: a new, empty database"
fi
# What's left in storefront-db/ without a base backup is WAL that can't be restored, and it would stop the new
# database from archiving ("Expected empty archive").
if ! k -n storefront get cluster storefront-db >/dev/null 2>&1 && [ -n "$(aws s3 ls "$archive/storefront-db/")" ]; then
  echo "Removing WAL without a base backup from $archive/storefront-db"
  aws s3 rm "$archive/storefront-db/" --recursive --only-show-errors
fi

step "Argo CD, then the platform and the storefront from git"
# *.localhost only works on your own machine, so the monitoring UIs use sslip.io: <name>.<ip>.sslip.io resolves to
# <ip> without any DNS setup.
DOMAIN="$server_ip.sslip.io" GRAFANA_CLOUD_URL="$gc_url" STOREFRONT_PATH="$storefront_path" \
  bash scripts/argocd-up.sh k3s

step "done"
echo "Storefront:    http://$server_ip/products"
echo "Grafana:       http://grafana.$server_ip.sslip.io   (admin/admin; reachable from $my_ip only)"
echo "Prometheus:    http://prometheus.$server_ip.sslip.io"
echo "Alertmanager:  http://alertmanager.$server_ip.sslip.io"
echo "kubectl:       kubectl --kubeconfig $KUBECONFIG get nodes"
echo "Node shell:    aws ssm start-session --target $(tf output -raw server_instance_id)"
echo "Tear down:     make down   (or bash scripts/k3s-down.sh)"
