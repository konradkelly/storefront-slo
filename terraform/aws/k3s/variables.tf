variable "region" {
  type    = string
  default = "us-east-1"
}

variable "admin_cidrs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Who may reach the Kubernetes API (6443) and the Gateway (80). scripts/k3s-up.sh passes your current public IP
    as a /32. Empty (the default, used by the nightly destroy) opens nothing; reach the cluster through an SSM
    port-forward instead.
  EOT
}

variable "k3s_version" {
  type        = string
  default     = "v1.34.12+k3s1" # same Kubernetes minor as kind (kindest/node v1.34) and kubectl
  description = "Changing it replaces every node (user_data changes)."
}

variable "instance_type" {
  type    = string
  default = "t3.medium" # 2 vCPU / 4 GiB; three of them hold the same stack as the kind lab
}

variable "agent_count" {
  type        = number
  default     = 2
  description = "Agents are spread round-robin over the zones after the server's, so 2 agents = one node per zone."
}

variable "zone_count" {
  type    = number
  default = 3
}

variable "root_volume_gb" {
  type        = number
  default     = 30
  description = "Holds images and local-path volumes (Postgres data lives on this disk in 4a)."
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}
