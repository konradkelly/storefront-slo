# Postgres base backups and WAL archive (CloudNativePG + Barman Cloud plugin, k8s/overlays/k3s/backups.yaml).
#
# The bucket lives and dies with this environment (force_destroy), so `make down` leaves nothing that costs money.
# It protects against losing a node's disk during the environment's lifetime. That is the weak point of
# local-path storage, and the WAL archive also lets a diverged instance pg_rewind instead of being rebuilt (2.1).
# Backups that survive a teardown are a Phase 4b item.

resource "aws_s3_bucket" "backups" {
  # Must match destinationPath in k8s/overlays/k3s/backups.yaml.
  bucket        = "storefront-k3s-backups-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
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
        Resource = aws_s3_bucket.backups.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.backups.arn}/*"
      },
    ]
  })
}

resource "aws_iam_access_key" "backup" {
  user = aws_iam_user.backup.name
}
