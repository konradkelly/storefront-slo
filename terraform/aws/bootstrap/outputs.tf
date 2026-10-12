output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "github_role_arn" {
  value       = aws_iam_role.github_k3s.arn
  description = "Set as the repository variable AWS_K3S_ROLE_ARN (gh variable set AWS_K3S_ROLE_ARN --body <arn>)."
}
