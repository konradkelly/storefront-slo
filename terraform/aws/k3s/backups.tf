# How the database and the Grafana snapshots reach the backup bucket. The bucket itself is in terraform/aws/bootstrap,
# so what's in it outlives `make down`.

locals {
  backup_bucket_arn = "arn:aws:s3:::storefront-k3s-backups-${data.aws_caller_identity.current.account_id}"
}

# THE 4a LIMITATION, on purpose: pods have no identity of their own here (IMDS is blocked for them, see iam.tf), so
# the backup sidecar authenticates with a static access key, which lives in a Kubernetes Secret and in Terraform
# state. It never expires, and anything that can read the Secret can use it. Phase 4b deletes this user: EKS Pod
# Identity gives the database pods a role, and the ObjectStore switches to inheritFromIAMRole.
resource "aws_iam_user" "backup" {
  name = "storefront-k3s-backup"
}

resource "aws_iam_user_policy" "backup" {
  name = "storefront-backups-bucket-only"
  user = aws_iam_user.backup.name
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
        Resource = "${local.backup_bucket_arn}/*"
      },
    ]
  })
}

resource "aws_iam_access_key" "backup" {
  user = aws_iam_user.backup.name
}
