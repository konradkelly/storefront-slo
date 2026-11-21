#!/bin/bash
# Destroys the EKS environment (terraform/aws/eks). The backup bucket and the rest of terraform/aws/bootstrap stay.
#   bash scripts/eks-down.sh      (or: make eks-down)
#
# Also run nightly by .github/workflows/k3s-nightly-destroy.yml, so it uses AWS APIs only, never kubectl.
#
# Kubernetes creates AWS resources that Terraform doesn't own: load balancers and their security groups (AWS Load
# Balancer Controller), EBS volumes (EBS CSI driver), and network interfaces (VPC CNI). A load balancer, security group
# or interface left behind stops the VPC from being deleted, and a volume keeps costing money. So, in order:
#   1. delete the nodes, which stops those controllers from creating anything new;
#   2. delete the load balancers and target groups, found by the tag the controller puts on them;
#   3. destroy the cluster. The controller added rules to the cluster's security group that point at its own groups,
#      and AWS won't delete a group something still points at. Destroying the cluster deletes that group and its rules;
#   4. delete the controller's security groups and the interfaces the VPC CNI left;
#   5. destroy everything else (the VPC, NAT gateway, Elastic IPs, IAM);
#   6. delete volumes that only came free when the nodes went.
# Postgres's volumes go too, as on k3s: its backups in S3 are what survive (docs/eks.md).
set -euo pipefail
cd "$(dirname "$0")/.."

tf() { terraform -chdir=terraform/aws/eks "$@"; }
account=$(aws sts get-caller-identity --query Account --output text)
tf init -input=false -reconfigure -backend-config="bucket=storefront-pulse-tfstate-$account" >/dev/null
if ! tf state list 2>/dev/null | grep -q .; then
  echo "Nothing in the EKS state: nothing to destroy."
  exit 0
fi
cluster=$(tf output -raw cluster_name 2>/dev/null || echo storefront-eks)
vpc=$(tf output -raw vpc_id 2>/dev/null || true)
export AWS_REGION=$(tf output -raw region 2>/dev/null || echo us-east-1)
# The load balancer controller tags what it creates with elbv2.k8s.aws/cluster=<cluster name>.
lbc_cluster_tag() {
  aws elbv2 describe-tags --resource-arns "$1" \
    --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" --output text
}

if tf state list | grep -qx 'aws_eks_node_group.main'; then
  echo "== Deleting the nodes first"
  tf destroy -input=false -auto-approve -target=aws_eks_node_group.main
fi

echo "== Load balancers and target groups the load balancer controller left"
for lb in $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text); do
  if [ "$(lbc_cluster_tag "$lb")" = "$cluster" ]; then
    echo "deleting load balancer $lb"
    aws elbv2 delete-load-balancer --load-balancer-arn "$lb"
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$lb"
  fi
done
for tg in $(aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text); do
  if [ "$(lbc_cluster_tag "$tg")" = "$cluster" ]; then
    echo "deleting target group $tg"
    aws elbv2 delete-target-group --target-group-arn "$tg"
  fi
done

if tf state list | grep -qx 'aws_eks_cluster.main'; then
  echo "== The cluster, and with it the security group that points at the controller's"
  tf destroy -input=false -auto-approve -target=aws_eks_cluster.main
fi

if [ -n "$vpc" ]; then
  echo "== Security groups the load balancer controller left"
  for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" \
      "Name=tag:elbv2.k8s.aws/cluster,Values=$cluster" --query 'SecurityGroups[].GroupId' --output text); do
    echo "deleting security group $sg"
    # A deleted load balancer's interfaces can take a minute or two to let go of the group.
    deleted=false
    for _ in $(seq 18); do
      aws ec2 delete-security-group --group-id "$sg" 2>/dev/null && { deleted=true; break; }
      sleep 10
    done
    $deleted || echo "WARNING: $sg is still in use after 3 minutes; deleting the VPC will fail until it's gone"
  done
  echo "== Network interfaces the VPC CNI left"
  for eni in $(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" "Name=status,Values=available" \
      "Name=tag:cluster.k8s.amazonaws.com/name,Values=$cluster" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
    echo "deleting network interface $eni"
    aws ec2 delete-network-interface --network-interface-id "$eni"
  done
fi

echo "== Everything else"
tf destroy -input=false -auto-approve

echo "== EBS volumes the CSI driver left (only ones no instance uses)"
for vol in $(aws ec2 describe-volumes --filters "Name=tag:storefront/cluster,Values=$cluster" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' --output text); do
  echo "deleting volume $vol"
  aws ec2 delete-volume --volume-id "$vol"
done

rm -f "$HOME/.kube/storefront-eks.yaml" terraform/aws/eks/admin.auto.tfvars.json
echo "EKS environment destroyed."
