#!/bin/bash
# Phase 4b: from the EKS cluster (terraform/aws/eks) to the storefront on it, with the same monitoring, SLO rules and
# canary as kind and k3s. Safe to rerun: it re-applies, and updates who may reach the API and the load balancer if
# your public IP changed. The script makes the cluster, the kubeconfig and the Secrets; Argo CD installs everything
# else from GitHub (k8s/platform, values-eks.yaml). docs/eks.md has the details.
#   bash scripts/eks-up.sh        (or: make eks-up)
#
# COSTS MONEY while it exists: the EKS control plane ($0.10/hr) + 3 t3.medium nodes + a NAT gateway + a Network Load
# Balancer + 4 public IPv4 + 90 GB gp3 ≈ $0.33/hr ≈ $8/day, plus $0.045 per GB through the NAT. `make eks-down`
# (scripts/eks-down.sh) stops that, and .github/workflows/k3s-nightly-destroy.yml runs it every night in case you
# forget.
#
# Needs: terraform >= 1.10, aws CLI (logged in; it also signs every kubectl call), kubectl. Before the first run:
# bash scripts/secrets-push.sh (the Secrets' values), and one make up (the database here is restored from k3s's
# archive).
set -euo pipefail
cd "$(dirname "$0")/.."

CTX=eks-storefront
export KUBECONFIG="$HOME/.kube/storefront-eks.yaml" # its own file: never merged into your main kubeconfig
source scripts/lib/bootstrap.sh # k(), step()
tf() { terraform -chdir=terraform/aws/eks "$@"; }

step "Terraform: VPC (private subnets, NAT gateway), EKS control plane, 3 nodes, add-ons, IAM roles (15-20 minutes)"
account=$(aws sts get-caller-identity --query Account --output text)
tf init -input=false -reconfigure -backend-config="bucket=storefront-pulse-tfstate-$account" >/dev/null
my_ip=$(curl -sf https://checkip.amazonaws.com | tr -d '[:space:]')
echo "Kubernetes API's public endpoint open to $my_ip/32 only"
# A tfvars file instead of -var: Git Bash would rewrite a "/32" argument as a Windows path.
printf '{"admin_cidrs": ["%s/32"]}\n' "$my_ip" > terraform/aws/eks/admin.auto.tfvars.json
tf apply -input=false -auto-approve
region=$(tf output -raw region)
cluster=$(tf output -raw cluster_name)

step "kubeconfig (kubectl gets a token from the aws CLI on every call)"
mkdir -p "$HOME/.kube"
aws eks update-kubeconfig --region "$region" --name "$cluster" --alias "$CTX" --kubeconfig "$KUBECONFIG" >/dev/null
chmod 600 "$KUBECONFIG"
echo "Wrote $KUBECONFIG (context $CTX)"

step "nodes"
k wait --for=condition=Ready nodes --all --timeout=600s
k get nodes -L topology.kubernetes.io/zone -L node.kubernetes.io/instance-type

step "Secrets: External Secrets makes them from Parameter Store"
# The Slack webhooks, the Grafana Cloud token and the database app password are in Parameter Store under /storefront/
# (scripts/secrets-push.sh), and External Secrets turns them into Secrets (k8s/cluster/eks-secrets,
# k8s/overlays/eks/db-app-secret.yaml). No S3 credentials: the Postgres pods get theirs from Pod Identity. Checked
# here, because a missing one would only show up as an app that never gets Healthy.
for name in slack/page-url slack/ticket-url grafana-cloud/url grafana-cloud/user grafana-cloud/token db/app-password; do
  MSYS_NO_PATHCONV=1 aws ssm get-parameter --name "/storefront/$name" --query Parameter.Name --output text >/dev/null 2>&1 ||
    { echo "Parameter /storefront/$name is missing: run bash scripts/secrets-push.sh" >&2; exit 1; }
done
gc_url=$(MSYS_NO_PATHCONV=1 aws ssm get-parameter --name /storefront/grafana-cloud/url --query Parameter.Value --output text | tr -d '\r')
echo "All six parameters exist. Sending curated metrics to $gc_url"

step "Database: a replica of the k3s database (slice 3)"
# The EKS database is restored from the k3s archive (storefront-db/ in the bucket) and keeps replaying it, until
# scripts/db-switchover.sh makes it the primary (k8s/overlays/eks, docs/eks.md). It needs the archive, not k3s itself.
bucket="storefront-k3s-backups-$account"
archive="s3://$bucket/eks"
if k -n storefront get cluster storefront-db >/dev/null 2>&1; then
  echo "The database exists: keeping it and its archive"
else
  # The restore starts from k3s's newest base backup. k3s takes one as soon as its database exists (immediate: true).
  done_backups=0
  for f in $(aws s3 ls "s3://$bucket/storefront-db/storefront-db/base/" --recursive | awk '/backup\.info$/ {print $4}'); do
    aws s3 cp "s3://$bucket/$f" - | grep -q '^status=DONE' && done_backups=$((done_backups + 1))
  done
  if [ "$done_backups" = 0 ]; then
    echo "No completed base backup in s3://$bucket/storefront-db/storefront-db/ to restore from." >&2
    echo "Bring k3s up once (make up) and wait for its first backup." >&2
    exit 1
  fi
  echo "k3s's archive has $done_backups completed base backup(s)"
  # A database archives only into an empty folder ("Expected empty archive"), so a previous EKS run's archive moves to
  # eks/storefront-db-previous/ first, replacing the one before. The k3s archive is never touched here.
  if [ -n "$(aws s3 ls "$archive/storefront-db/" 2>/dev/null)" ]; then
    echo "Moving the previous EKS database's archive to $archive/storefront-db-previous/"
    aws s3 rm "$archive/storefront-db-previous/" --recursive --only-show-errors
    aws s3 cp "$archive/storefront-db/" "$archive/storefront-db-previous/" --recursive --only-show-errors
    aws s3 rm "$archive/storefront-db/" --recursive --only-show-errors
  fi
fi

step "Argo CD, then the platform and the storefront from git"
# The NLB gets the Elastic IPs Terraform made, so its address is known now, before it exists. The monitoring UIs use
# sslip.io: <name>.<ip>.sslip.io resolves to <ip> without any DNS setup.
nlb_ip=$(tf output -raw nlb_public_ip)
DOMAIN="$nlb_ip.sslip.io" GRAFANA_CLOUD_URL="$gc_url" VPC_ID="$(tf output -raw vpc_id)" \
  NLB_EIP_ALLOCATIONS="$(tf output -raw nlb_eip_allocation_ids)" ADMIN_CIDR="$my_ip/32" \
  bash scripts/argocd-up.sh eks

step "done"
echo "Storefront:    http://$nlb_ip/products   (the NLB can take 2-3 minutes after Argo CD to register Envoy)"
echo "Grafana:       http://grafana.$nlb_ip.sslip.io   (admin/admin; reachable from $my_ip only)"
echo "Prometheus:    http://prometheus.$nlb_ip.sslip.io"
echo "Alertmanager:  http://alertmanager.$nlb_ip.sslip.io"
echo "kubectl:       kubectl --kubeconfig $KUBECONFIG get nodes"
echo "Node shell:    aws ssm start-session --target <instance-id>   (kubectl get nodes -o wide shows the names)"
echo "Tear down:     make eks-down   (or bash scripts/eks-down.sh)"
