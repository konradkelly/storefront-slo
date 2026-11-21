# Nodes and pods in private subnets, with no public IPs; they reach the internet through a NAT gateway in a public
# subnet. The public subnets hold only the NAT gateway and the internet-facing load balancer.
#
# One NAT gateway, not one per zone: $0.045/hr plus $0.045 per GB, against $0.135/hr for three. The cost of that: if
# the NAT's zone fails, every node loses outbound traffic (image pulls, GHCR, the AWS APIs), not just that zone's.
# S3 goes through a gateway endpoint instead, which is free, so the Postgres backups and the layers of EKS's own
# images (ECR serves them from S3) never touch the NAT.

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"] # skip Local Zones and Wavelength
  }
}

locals {
  zones = slice(sort(data.aws_availability_zones.available.names), 0, var.zone_count)
  # Load balancer controllers find subnets by these tags. "shared": other clusters may use the subnets too.
  cluster_tag = { "kubernetes.io/cluster/${var.cluster_name}" = "shared" }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # EKS needs both for the private API endpoint
  tags                 = { Name = var.cluster_name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = var.cluster_name }
}

resource "aws_subnet" "public" {
  count             = length(local.zones)
  vpc_id            = aws_vpc.main.id
  availability_zone = local.zones[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index) # 10.50.0.0/24, 10.50.1.0/24, 10.50.2.0/24
  tags = merge(local.cluster_tag, {
    Name                     = "${var.cluster_name}-public-${local.zones[count.index]}"
    "kubernetes.io/role/elb" = "1" # internet-facing load balancers go here
  })
}

# /19s (8190 addresses each): with prefix delegation every node takes /28 blocks of 16 addresses for its pods.
resource "aws_subnet" "private" {
  count             = length(local.zones)
  vpc_id            = aws_vpc.main.id
  availability_zone = local.zones[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 3, count.index + 1) # 10.50.32.0/19, 10.50.64.0/19, 10.50.96.0/19
  tags = merge(local.cluster_tag, {
    Name                              = "${var.cluster_name}-private-${local.zones[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-nat" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = var.cluster_name }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "${var.cluster_name}-private" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${var.cluster_name}-s3" }
}

# The VPC's default security group allows all traffic between its members. Empty it, so nothing can fall back on it.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}
