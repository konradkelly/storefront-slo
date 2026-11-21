# The EKS environment (Phase 4b): everything `make eks-down` destroys. Run through scripts/eks-up.sh / eks-down.sh,
# which pass the state bucket (from terraform/aws/bootstrap) as -backend-config so no account ID lives here.
#
# Its own stack and VPC, not the k3s one: the cutover runs both clusters at once, and `make down` destroys the k3s
# VPC. The two clusters share only the backup bucket, which is how the database moves (docs/eks.md).
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    key          = "eks/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true # S3-native lock file; no DynamoDB table
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "storefront-pulse", Stack = "eks", ManagedBy = "terraform" }
  }
}
