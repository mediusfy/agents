# =============================================================================
# OpenClaw - Multi-Region Infrastructure (us-east-1)
# =============================================================================
# Terraform version: 1.10.x
# Provider versions pinned for immutability
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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket         = "openclaw-terraform-state"
    key            = "us-east-1/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "openclaw-terraform-locks"
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Environment = local.environment
      ManagedBy   = "OpenClaw-SRE"
      Region      = "us-east-1"
      Project     = "openclaw"
    }
  }
}

locals {
  environment    = var.environment
  cluster_name   = "openclaw-${local.environment}-us-east-1"
  azs            = ["us-east-1a", "us-east-1b", "us-east-1c"]
  vpc_cidr       = "10.0.0.0/16"
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}
