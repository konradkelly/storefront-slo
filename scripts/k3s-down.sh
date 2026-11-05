#!/bin/bash
# Destroys the k3s environment: instances, Elastic IP, VPC, IAM and parameters. terraform/aws/bootstrap (state bucket,
# backup bucket, budget, CI role) is kept, so the account costs about $0/day afterwards and the next `make up` restores
# the database. `make wipe-db` starts it empty instead.
#   bash scripts/k3s-down.sh      (or: make down)
#
# Also run nightly by .github/workflows/k3s-nightly-destroy.yml, with the same Terraform commands.
set -euo pipefail
cd "$(dirname "$0")/.."

tf() { terraform -chdir=terraform/aws/k3s "$@"; }
account=$(aws sts get-caller-identity --query Account --output text)
tf init -input=false -reconfigure -backend-config="bucket=storefront-pulse-tfstate-$account" >/dev/null
# A local copy of the dashboard pictures (k8s/monitoring/grafana-snapshots.yaml).
aws s3 sync "s3://storefront-k3s-backups-$account/grafana-snapshots/" grafana-snapshots/ --no-progress >/dev/null &&
  echo "Grafana snapshots saved in grafana-snapshots/" || true
tf destroy -input=false -auto-approve
rm -f "$HOME/.kube/storefront-k3s.yaml" terraform/aws/k3s/admin.auto.tfvars.json
echo "k3s environment destroyed."
