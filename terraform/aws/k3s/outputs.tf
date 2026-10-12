output "region" {
  value = var.region
}

output "server_public_ip" {
  value = aws_eip.server.public_ip
}

output "server_instance_id" {
  value       = aws_instance.server.id
  description = "For SSM: aws ssm start-session --target <id>"
}

output "agent_instance_ids" {
  value = aws_instance.agent[*].id
}

output "kubeconfig_parameter" {
  value = aws_ssm_parameter.kubeconfig.name
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}

output "backup_access_key_id" {
  value = aws_iam_access_key.backup.id
}

output "backup_secret_access_key" {
  value     = aws_iam_access_key.backup.secret
  sensitive = true
}
