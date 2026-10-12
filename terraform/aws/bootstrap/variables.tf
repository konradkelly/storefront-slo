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

variable "github_repository" {
  type    = string
  default = "konradkelly/storefront-slo"
}

variable "create_github_oidc_provider" {
  type        = bool
  default     = false
  description = "false when the account already has GitHub's OIDC provider (one per account)."
}
