# Account-level pieces that outlive any cluster: the Terraform state bucket, the cost budget, and the role GitHub
# Actions assumes (OIDC, no stored keys) for the nightly destroy. Applied once by hand; `make down` never touches it.
#
# State for this stack is local (terraform.tfstate here, gitignored): it creates the bucket the other stacks keep
# their state in. Losing it is recoverable with `terraform import`. Everything here costs ~$0 per month.
#
#   cd terraform/aws/bootstrap && terraform init && terraform apply

terraform {
  required_version = ">= 1.10" # S3 backend native locking (use_lockfile) in the stacks that use this bucket
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "storefront-pulse", Stack = "bootstrap", ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "storefront-pulse-tfstate-${local.account_id}"
}

# --- Terraform state -------------------------------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" } # a bad apply can be undone by restoring the previous state version
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

# --- Cost guardrail --------------------------------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "storefront-pulse-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_email]
    }
  }

  # Forecast catches "I forgot to run make down" days before the actual spend does.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}

# --- GitHub Actions → AWS through OIDC -------------------------------------------------------------------------------

# An account has one provider per issuer URL, and this account already has GitHub's, so look it up instead of
# creating it. Set create_github_oidc_provider = true in a fresh account.
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  github_oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# Only workflows on this repo's main branch can assume the role. Scheduled runs always use the default branch, so
# the nightly destroy matches; a pull request (sub = repo:...:pull_request) never does.
data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_k3s" {
  name                 = "storefront-k3s-github"
  description          = "GitHub Actions (main branch) manages the k3s stack: nightly destroy"
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
}

# Enough to refresh and destroy the k3s stack (terraform/aws/k3s), and nothing outside it where IAM allows scoping:
# IAM, S3 and SSM are limited to the stack's names. EC2 is limited to the region, because many EC2 delete calls
# can't be scoped by tag. Tighten further if this account ever holds anything that matters.
data "aws_iam_policy_document" "github_k3s" {
  statement {
    sid       = "StateBucket"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/k3s/*"]
  }
  statement {
    sid       = "EC2InRegion"
    actions   = ["ec2:*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
  statement {
    sid     = "StackIAM"
    actions = ["iam:Get*", "iam:List*", "iam:Delete*", "iam:Detach*", "iam:Remove*", "iam:Tag*", "iam:Untag*", "iam:PassRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/storefront-k3s-*",
      "arn:aws:iam::${local.account_id}:instance-profile/storefront-k3s-*",
      "arn:aws:iam::${local.account_id}:user/storefront-k3s-*",
      "arn:aws:iam::${local.account_id}:policy/storefront-k3s-*",
    ]
  }
  statement {
    sid       = "StackBuckets"
    actions   = ["s3:Get*", "s3:List*", "s3:DeleteObject*", "s3:DeleteBucket*", "s3:PutBucket*"]
    resources = ["arn:aws:s3:::storefront-k3s-*", "arn:aws:s3:::storefront-k3s-*/*"]
  }
  statement {
    sid       = "StackParameters"
    actions   = ["ssm:GetParameter*", "ssm:DeleteParameter*", "ssm:ListTagsForResource"]
    resources = ["arn:aws:ssm:${var.region}:${local.account_id}:parameter/storefront-k3s/*"]
  }
  statement {
    sid       = "Lookups"
    actions   = ["ssm:DescribeParameters", "ssm:GetParameter", "sts:GetCallerIdentity"]
    resources = ["*"] # includes the public AL2023 AMI parameter under /aws/service/
  }
}

resource "aws_iam_role_policy" "github_k3s" {
  name   = "manage-k3s-stack"
  role   = aws_iam_role.github_k3s.id
  policy = data.aws_iam_policy_document.github_k3s.json
}
