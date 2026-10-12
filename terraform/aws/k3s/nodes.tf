# One k3s server and var.agent_count agents on Amazon Linux 2023, one per zone. k3s is installed by user_data
# (templates/), pinned to var.k3s_version.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# The server's address survives a stop/start (the Phase 4a experiment stops it), so its certificate SAN and the
# kubeconfig stay valid. Released on destroy; like any public IPv4 it costs $0.005/hr only while it exists.
resource "aws_eip" "server" {
  domain = "vpc"
  tags   = { Name = "storefront-k3s-server" }
}

locals {
  common_tpl = {
    region      = var.region
    k3s_version = var.k3s_version
    token_param = aws_ssm_parameter.token.name
  }
}

resource "aws_instance" "server" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.node["server"].name

  user_data = templatefile("${path.module}/templates/server.sh.tftpl", merge(local.common_tpl, {
    public_ip        = aws_eip.server.public_ip
    kubeconfig_param = aws_ssm_parameter.kubeconfig.name
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # pods are one hop further away, so they can't get a token
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  tags = { Name = "storefront-k3s-server" }

  lifecycle {
    ignore_changes = [ami] # a newer AL2023 image must not replace the running cluster
  }
}

resource "aws_eip_association" "server" {
  instance_id   = aws_instance.server.id
  allocation_id = aws_eip.server.id
}

resource "aws_instance" "agent" {
  count                  = var.agent_count
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[(count.index + 1) % length(aws_subnet.public)].id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.node["agent"].name

  user_data = templatefile("${path.module}/templates/agent.sh.tftpl", merge(local.common_tpl, {
    server_ip = aws_instance.server.private_ip # stable across stop/start
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  tags = { Name = "storefront-k3s-agent-${count.index}" }

  lifecycle {
    ignore_changes = [ami]
  }
}
