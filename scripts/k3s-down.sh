#!/bin/bash
# Destroys the k3s environment: instances, Elastic IP, VPC, IAM, parameters and the backup bucket with its contents.
# The account is back to $0/day afterwards. terraform/aws/bootstrap (state bucket, budget, CI role) is kept.
#   bash scripts/k3s-down.sh      (or: make down)
#
# Also run nightly by .github/workflows/k3s-nightly-destroy.yml, with the same Terraform commands.
set -euo pipefail
cd "$(dirname "$0")/.."

tf() { terraform -chdir=terraform/aws/k3s "$@"; }
account=$(aws sts get-caller-identity --query Account --output text)
tf init -input=false -reconfigure -backend-config="bucket=storefront-pulse-tfstate-$account" >/dev/null
tf destroy -input=false -auto-approve
rm -f "$HOME/.kube/storefront-k3s.yaml" terraform/aws/k3s/admin.auto.tfvars.json
echo "k3s environment destroyed."
