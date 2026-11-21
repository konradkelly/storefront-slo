# The EKS control plane, one managed node group with a node in each zone, and EKS's add-ons at pinned versions.
#
# What this replaces from k3s (docs/k3s.md, "What I had to run myself"): the control plane runs across three zones on
# AWS's side, not on a node the scheduler can fill; nodes come from a managed node group, which AWS replaces and
# upgrades; the zone labels come from the cloud provider, not user_data; and CoreDNS runs two replicas.

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # EKS would otherwise install its own unmanaged VPC CNI, kube-proxy and CoreDNS. The add-ons below replace them,
  # at pinned versions and with this repo's configuration.
  bootstrap_self_managed_addons = false

  # Access entries (EKS API), not the aws-auth ConfigMap. Whoever runs `terraform apply` (scripts/eks-up.sh) becomes
  # cluster admin. The nightly destroy needs no Kubernetes access: it only calls AWS APIs.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # When the version leaves standard support, upgrade it rather than move to extended support at $0.60/hr.
  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id # the control plane's network interfaces, one per zone
    endpoint_private_access = true                     # nodes reach the API inside the VPC
    endpoint_public_access  = length(var.admin_cidrs) > 0
    public_access_cidrs     = length(var.admin_cidrs) > 0 ? var.admin_cidrs : null
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# --- Nodes -----------------------------------------------------------------------------------------------------------

resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-node-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # pods are one hop further away, so they can't get the node role
  }

  block_device_mappings {
    device_name = "/dev/xvda" # the AL2023 EKS AMI's root volume
    ebs {
      volume_type           = "gp3"
      volume_size           = var.node_volume_gb
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Merged by nodeadm with the configuration EKS generates for the node group (cluster endpoint, CA, labels).
  user_data = base64encode(<<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="//"

    --//
    Content-Type: application/node.eks.aws

    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          maxPods: ${var.max_pods}

    --//--
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-node" }
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "main"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = [var.node_instance_type]
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count
  }

  update_config {
    max_unavailable = 1 # replace nodes one at a time: the PDBs and the zone spread keep the API up
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  # The VPC CNI, kube-proxy and the Pod Identity agent must exist before the nodes, or the nodes never get Ready.
  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
    aws_eks_addon.pod_identity_agent,
  ]
}

# --- Add-ons ---------------------------------------------------------------------------------------------------------

# AWS's default version for each add-on on Kubernetes 1.35, looked up on 2026-11-21 with
#   aws eks describe-addon-versions --kubernetes-version 1.35 --addon-name <name>
# Upgrade one at a time, like the charts in k8s/platform/values.yaml.
locals {
  addon_versions = {
    vpc-cni                = "v1.22.4-eksbuild.14"
    kube-proxy             = "v1.35.3-eksbuild.69"
    eks-pod-identity-agent = "v1.4.1-eksbuild.3"
    coredns                = "v1.13.2-eksbuild.75"
    aws-ebs-csi-driver     = "v1.68.1-eksbuild.1"
  }
}

# Pod IPs come from the VPC. Prefix delegation gives each node /28 blocks instead of single IPs, so a t3.medium can
# hold more than 17 pods (var.max_pods). enableNetworkPolicy: the CNI's node agent enforces NetworkPolicy, which k3s
# did with kube-router and kind with Calico.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "vpc-cni"
  addon_version = local.addon_versions["vpc-cni"]
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = local.addon_versions["kube-proxy"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = local.addon_versions["eks-pod-identity-agent"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# Two replicas by default, spread over nodes. On k3s the only CoreDNS ran on the server, and stopping the server
# took DNS down with it (docs/postmortems/2026-10-29-k3s-control-plane-stop.md).
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = local.addon_versions["coredns"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main] # its pods need nodes before the add-on reports ACTIVE
}

# Volumes for PersistentVolumeClaims (Postgres), replacing k3s's local-path directories on a node's disk. An EBS volume
# outlives its node and can be attached to another node in the same zone. The extra tag lets scripts/eks-down.sh find
# volumes a deleted claim left behind, since Terraform doesn't own them.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = local.addon_versions["aws-ebs-csi-driver"]
  configuration_values = jsonencode({
    controller = {
      extraVolumeTags = { "storefront/cluster" = var.cluster_name }
    }
  })
  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main, aws_iam_role_policy_attachment.ebs_csi]
}
