variable "region" {
  type    = string
  default = "us-east-1"
}

variable "admin_cidrs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Who may reach the cluster's public API endpoint. scripts/eks-up.sh passes your current public IP as a /32.
    Empty (the default, used by the nightly destroy) turns the public endpoint off; the nodes use the private one.
  EOT
}

variable "cluster_name" {
  type    = string
  default = "storefront-eks"
}

variable "kubernetes_version" {
  type        = string
  default     = "1.35"
  description = <<-EOT
    1.35: standard support until 2027-03-26 (aws eks describe-cluster-versions). 1.34, what kind and k3s run, leaves
    standard support on 2026-12-01, and extended support costs $0.60/hr instead of $0.10. One minor ahead of kind,
    k3s and the 1.34 kubectl is within Kubernetes' version skew policy.
  EOT
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium" # 2 vCPU / 4 GiB, the same as the k3s agents; the control plane isn't on a node here
}

variable "node_count" {
  type        = number
  default     = 3
  description = "One per zone: the node group spreads them over the private subnets, one subnet per zone."
}

variable "max_pods" {
  type        = number
  default     = 40
  description = <<-EOT
    Pods per node. Without prefix delegation the VPC CNI fits 17 on a t3.medium (one IP per pod, limited by ENIs),
    and this stack needs about 22 per node: 43 pods on k3s, plus EKS's per-node agents and a scaled-up canary. With
    prefix delegation it could be 110. 40 leaves room over 22 without letting one node take more pods than its
    3.3 GiB can hold. It doesn't change the kubelet's memory reservation: on 2026-11-21 each node reserved 542 MiB,
    which is 255 MiB + 11 MiB x 17 pods (the ENI limit) plus the 100 MiB eviction threshold.
  EOT
}

variable "zone_count" {
  type    = number
  default = 3
}

variable "node_volume_gb" {
  type        = number
  default     = 30
  description = "Each node's root disk: images and logs. Postgres gets its own EBS volume per instance."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.50.0.0/16"
  description = "Not 10.40.0.0/16 (k3s), so the two VPCs could be peered during the cutover."
}
