# One public subnet per zone and no NAT gateway: a NAT gateway alone would cost more than the three nodes
# (~$0.045/hr + data). Nodes get public IPv4 addresses for outbound traffic (image pulls, S3, SSM), and the security
# group admits nothing from the internet except admin_cidrs. Phase 4b adds private subnets to this VPC for EKS.

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"] # skip Local Zones and Wavelength
  }
}

locals {
  zones = slice(sort(data.aws_availability_zones.available.names), 0, var.zone_count)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "storefront-k3s" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "storefront-k3s" }
}

resource "aws_subnet" "public" {
  count                   = length(local.zones)
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.zones[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index) # 10.40.0.0/24, 10.40.1.0/24, ...
  map_public_ip_on_launch = true
  tags                    = { Name = "storefront-k3s-public-${local.zones[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "storefront-k3s-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# The VPC's default security group allows all traffic between its members. Empty it, so nothing can fall back on it.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}

resource "aws_security_group" "nodes" {
  name        = "storefront-k3s-nodes"
  description = "k3s nodes: all traffic between nodes, API and HTTP from admin_cidrs only, no SSH"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "storefront-k3s-nodes" }
}

# Node to node: the API (6443), kubelet (10250), flannel VXLAN (8472/udp), metrics, NodePorts and the ServiceLB
# hostPorts. One self-referencing rule instead of a port list that has to track k3s releases.
resource "aws_vpc_security_group_ingress_rule" "nodes_self" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  description                  = "all traffic between cluster nodes"
}

resource "aws_vpc_security_group_ingress_rule" "api" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  description       = "Kubernetes API from admin"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "Gateway (Envoy via ServiceLB) from admin"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "image pulls, S3, SSM, k3s install"
}
