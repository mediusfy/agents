# =============================================================================
# OpenClaw - Multi-Region Infrastructure (eu-west-1)
# =============================================================================
# Data residency region for EU compliance (GDPR)
# =============================================================================

terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket         = "openclaw-terraform-state"
    key            = "eu-west-1/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "openclaw-terraform-locks"
  }
}

provider "aws" {
  region = "eu-west-1"
  default_tags {
    tags = {
      Environment = local.environment
      ManagedBy   = "OpenClaw-SRE"
      Region      = "eu-west-1"
      Project     = "openclaw"
    }
  }
}

locals {
  environment    = var.environment
  cluster_name   = "openclaw-${local.environment}-eu-west-1"
  azs            = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  vpc_cidr       = "10.1.0.0/16"
  private_subnets = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
  public_subnets  = ["10.1.101.0/24", "10.1.102.0/24", "10.1.103.0/24"]
}
