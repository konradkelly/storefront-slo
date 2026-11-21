output "region" {
  value = var.region
}

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "kubernetes_version" {
  value = aws_eks_cluster.main.version
}

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "For the AWS Load Balancer Controller, which can't read it from instance metadata (hop limit 1)."
}

output "nat_public_ip" {
  value       = aws_eip.nat.public_ip
  description = "Every outbound connection from the cluster comes from this address."
}
