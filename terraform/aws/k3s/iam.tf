# Node identity. Both roles get SSM Session Manager (shell access with port 22 closed) and read the join token.
# Only the server may write the kubeconfig parameter.
#
# Pods get none of this. The instances require IMDSv2 with a hop limit of 1 (nodes.tf), so a request from a pod,
# which crosses one extra network hop, never gets a token back. Self-managed nodes have no per-pod identity, so the
# one workload that needs AWS (Postgres backups) gets a long-lived access key instead: see backups.tf.

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  for_each           = toset(["server", "agent"])
  name               = "storefront-k3s-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each   = aws_iam_role.node
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_token" {
  for_each = aws_iam_role.node
  name     = "read-join-token"
  role     = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = aws_ssm_parameter.token.arn
    }]
  })
}

resource "aws_iam_role_policy" "publish_kubeconfig" {
  name = "publish-kubeconfig"
  role = aws_iam_role.node["server"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ssm:PutParameter"
      Resource = aws_ssm_parameter.kubeconfig.arn
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  for_each = aws_iam_role.node
  name     = "storefront-k3s-${each.key}"
  role     = each.value.name
}

# --- Cluster secrets in Parameter Store (SecureString, AWS-managed key) ---------------------------------------------

# The join token never appears in user_data, which anyone with ec2:DescribeInstanceAttribute can read.
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "token" {
  name  = "/storefront-k3s/token"
  type  = "SecureString"
  value = random_password.k3s_token.result
}

# The server overwrites this with its admin kubeconfig once k3s is up; scripts/k3s-up.sh reads it from here.
# Terraform creates the parameter (so destroy removes it) and then ignores its value.
resource "aws_ssm_parameter" "kubeconfig" {
  name  = "/storefront-k3s/kubeconfig"
  type  = "SecureString"
  tier  = "Intelligent-Tiering" # a kubeconfig with embedded certs can exceed the 4 KB standard tier
  value = "pending"
  lifecycle {
    ignore_changes = [value, tier]
  }
}
