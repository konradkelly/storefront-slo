#!/bin/bash
# Phase 4a: from an empty AWS account (plus terraform/aws/bootstrap, applied once) to the storefront on k3s with
# the same monitoring, SLO rules and dashboards as kind. Safe to rerun: it also re-applies on an existing cluster
# and updates the security group if your public IP changed. The script makes the machines, the kubeconfig and the
# Secrets; Argo CD installs everything else from GitHub (k8s/platform, values-k3s.yaml).
#   bash scripts/k3s-up.sh        (or: make up)
#
# COSTS MONEY while it exists: 3 x t3.medium + 3 public IPv4 + 90 GB gp3 ≈ $0.15/hr ≈ $3.60/day.
# `make down` (scripts/k3s-down.sh) returns the account to $0/day, and .github/workflows/k3s-nightly-destroy.yml
# runs it every night in case you forget.
#
# Needs: terraform >= 1.10, aws CLI (logged in), kubectl, curl.
set -euo pipefail
cd "$(dirname "$0")/.."

CTX=k3s-storefront
export KUBECONFIG="$HOME/.kube/storefront-k3s.yaml" # its own file: never merged into your main kubeconfig
source scripts/lib/bootstrap.sh # k(), step(), the Slack Secret
tf() { terraform -chdir=terraform/aws/k3s "$@"; }

step "Terraform: VPC, security group, IAM, 1 server + 2 agents, backup bucket"
account=$(aws sts get-caller-identity --query Account --output text)
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
echo "BUCKET=$(tf output -raw backup_bucket)" >> "$creds" # kubectl 1.36 refuses --from-env-file with --from-literal
k -n monitoring create secret generic grafana-snapshots-s3 --from-env-file="$creds" --dry-run=client -o yaml | k apply -f -
rm -f "$creds"

step "Argo CD, then the platform and the storefront from git"
# *.localhost only works on your own machine, so the monitoring UIs use sslip.io: <name>.<ip>.sslip.io resolves to
# <ip> without any DNS setup.
DOMAIN="$server_ip.sslip.io" GRAFANA_CLOUD_URL="$gc_url" bash scripts/argocd-up.sh k3s

step "done"
echo "Storefront:    http://$server_ip/products"
echo "Grafana:       http://grafana.$server_ip.sslip.io   (admin/admin; reachable from $my_ip only)"
echo "Prometheus:    http://prometheus.$server_ip.sslip.io"
echo "Alertmanager:  http://alertmanager.$server_ip.sslip.io"
echo "kubectl:       kubectl --kubeconfig $KUBECONFIG get nodes"
echo "Node shell:    aws ssm start-session --target $(tf output -raw server_instance_id)"
echo "Tear down:     make down   (or bash scripts/k3s-down.sh)"
