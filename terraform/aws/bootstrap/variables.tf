variable "region" {
  type    = string
  default = "us-east-1"
}

variable "budget_email" {
  type        = string
  description = "Where budget alerts go. Set it in terraform.tfvars (gitignored)."
}

variable "monthly_budget_usd" {
  type        = string
  default     = "30"
  description = "The whole account's monthly spend that triggers alerts at 50/80/100% (and a 100% forecast)."
}

variable "github_oidc_subject_prefix" {
  type        = string
  default     = "repo:konradkelly@191545623/storefront-slo@1394399367"
  description = <<-EOT
    The repository part of the "sub" claim in GitHub's OIDC tokens. This repo uses GitHub's immutable subject format,
    owner@owner-id/repo@repo-id, so a renamed or re-created repository with the same name can never match.
    Check it with: gh api repos/<owner>/<repo>/actions/oidc/customization/sub (sub_claim_prefix).
  EOT
}

variable "create_github_oidc_provider" {
  type        = bool
  default     = false
  description = "false when the account already has GitHub's OIDC provider (one per account)."
}
