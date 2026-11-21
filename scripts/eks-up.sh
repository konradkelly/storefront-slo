#!/bin/bash
# Phase 4b: the EKS cluster (terraform/aws/eks). Safe to rerun: it re-applies, and updates the API endpoint's allow
# list if your public IP changed. For now it stops at a working cluster; Argo CD and the platform come next
# (docs/eks.md).
#   bash scripts/eks-up.sh        (or: make eks-up)
#
# COSTS MONEY while it exists: the EKS control plane ($0.10/hr) + 3 t3.medium nodes + a NAT gateway + 90 GB gp3
# ≈ $0.28/hr ≈ $6.80/day, plus $0.045 per GB through the NAT. `make eks-down` (scripts/eks-down.sh) stops that, and
# .github/workflows/k3s-nightly-destroy.yml runs it every night in case you forget.
#
# Needs: terraform >= 1.10, aws CLI (logged in; it also signs every kubectl call), kubectl.
set -euo pipefail
cd "$(dirname "$0")/.."

CTX=eks-storefront
export KUBECONFIG="$HOME/.kube/storefront-eks.yaml" # its own file: never merged into your main kubeconfig
source scripts/lib/bootstrap.sh # k(), step()
tf() { terraform -chdir=terraform/aws/eks "$@"; }

step "Terraform: VPC (private subnets, NAT gateway), EKS control plane, 3 nodes, add-ons (15-20 minutes)"
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

step "done"
echo "kubectl:     kubectl --kubeconfig $KUBECONFIG get nodes"
echo "Node shell:  aws ssm start-session --target <instance-id>   (kubectl get nodes -o wide shows the names)"
echo "Tear down:   make eks-down   (or bash scripts/eks-down.sh)"
