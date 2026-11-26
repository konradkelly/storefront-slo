# What the platform on the cluster needs from AWS (docs/eks.md, slice 2): addresses for the load balancer, and a
# role for each workload that calls AWS, handed to it through EKS Pod Identity.

data "aws_caller_identity" "current" {}

locals {
  # Created by terraform/aws/bootstrap; the k3s database archives here too, under storefront-db/.
  backup_bucket_arn = "arn:aws:s3:::storefront-k3s-backups-${data.aws_caller_identity.current.account_id}"
}

# --- The Network Load Balancer's addresses ---------------------------------------------------------------------------

# The AWS Load Balancer Controller creates the NLB in front of Envoy Gateway when Argo CD syncs the Gateway, so its
# addresses would only be known halfway through the sync. These are known before it: one per zone (the NLB needs one
# per subnet), passed to the Gateway's Service (k8s/gateway/gateway-eks.yaml), and the first one is the domain the
# monitoring UIs answer on (<name>.<ip>.sslip.io). An NLB's public IPv4 costs $0.005/hr each whether it's an
# Elastic IP or not.
resource "aws_eip" "nlb" {
  count  = length(local.zones)
  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-nlb-${local.zones[count.index]}" }
}

# --- AWS Load Balancer Controller ------------------------------------------------------------------------------------

# lbc-iam-policy.json is the controller project's published policy for v3.6.3, unchanged:
#   https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.3/docs/install/iam_policy.json
# Update it with the chart (k8s/platform/values.yaml). Creating, changing and deleting load balancers and security
# groups is limited to resources tagged elbv2.k8s.aws/cluster, which the controller puts on everything it makes.
resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-lbc"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "lbc" {
  name   = "aws-load-balancer-controller"
  role   = aws_iam_role.lbc.id
  policy = file("${path.module}/lbc-iam-policy.json")
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller" # the chart's default name
  role_arn        = aws_iam_role.lbc.arn
}

# --- Postgres backups ------------------------------------------------------------------------------------------------

# The Barman Cloud sidecar in each Postgres pod archives WAL and base backups to S3. On k3s that took a static access
# key in a Secret (terraform/aws/k3s/backups.tf). Here CloudNativePG's pods run as the service account named after the
# Cluster, and Pod Identity gives them this role's short-lived credentials (inheritFromIAMRole, k8s/overlays/eks).
#
# Writes only under eks/, so the EKS database can never change the k3s archive (storefront-db/). It may read that
# archive: the EKS database is restored from it and replays it as k3s's replica (k8s/overlays/eks). HeadBucket, which
# Barman calls first, needs s3:ListBucket on the whole bucket.
resource "aws_iam_role" "backups" {
  name               = "${var.cluster_name}-backups"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "backups" {
  name = "eks-archive"
  role = aws_iam_role.backups.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = local.backup_bucket_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${local.backup_bucket_arn}/eks/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${local.backup_bucket_arn}/storefront-db/*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "backups" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "storefront"
  service_account = "storefront-db" # CloudNativePG names it after the Cluster (k8s/base/postgres.yaml)
  role_arn        = aws_iam_role.backups.arn
}

# --- External Secrets ------------------------------------------------------------------------------------------------

# External Secrets (k8s/platform, values-eks.yaml) reads the parameters under /storefront/ in Parameter Store and turns
# them into Kubernetes Secrets: the Slack webhooks, the Grafana Cloud token, the database app password. scripts/
# secrets-push.sh puts them there, so the values are in neither git nor Terraform state.
#
# Read-only, and only /storefront/. SecureString parameters use the AWS-managed aws/ssm key, whose key policy lets any
# principal in the account decrypt through Parameter Store, so no kms:Decrypt here.
resource "aws_iam_role" "external_secrets" {
  name               = "${var.cluster_name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "read-storefront-parameters"
  role = aws_iam_role.external_secrets.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/storefront/*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "external-secrets"
  service_account = "external-secrets" # the chart's controller, named after the release (k8s/platform/values.yaml)
  role_arn        = aws_iam_role.external_secrets.arn
}
