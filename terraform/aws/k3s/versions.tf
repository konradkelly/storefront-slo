# The k3s environment (Phase 4a): everything `make down` destroys. Run through scripts/k3s-up.sh / k3s-down.sh,
# which pass the state bucket (from terraform/aws/bootstrap) as -backend-config so no account ID lives here.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  backend "s3" {
    key          = "k3s/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true # S3-native lock file; no DynamoDB table
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "storefront-pulse", Stack = "k3s", ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}
