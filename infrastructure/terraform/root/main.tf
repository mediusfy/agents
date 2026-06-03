# =============================================================================
# OpenClaw Root Terraform Configuration
# =============================================================================
# Orchestrates multi-region infrastructure deployment.
# Uses Terragrunt or root module to compose regions.
# =============================================================================

terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket         = "openclaw-terraform-state"
    key            = "root/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "openclaw-terraform-locks"
  }
}

locals {
  environment = "production"
  regions = {
    primary = "us-east-1"
    dr      = "eu-west-1"
  }
}

module "us_east_1" {
  source = "../us-east-1"

  environment = local.environment
}

module "eu_west_1" {
  source = "../eu-west-1"

  environment = local.environment
}

# =============================================================================
# Global Resources (account-level, region-agnostic)
# =============================================================================

# Route53 Health Checks for cross-region failover
resource "aws_route53_health_check" "entity_mgmt_primary" {
  fqdn              = module.us_east_1.cluster_endpoint_health_check_domain
  port              = 80
  type              = "HTTP"
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 10

  tags = {
    Name = "entity-management-us-east-1"
  }
}

resource "aws_route53_health_check" "entity_mgmt_dr" {
  fqdn              = module.eu_west_1.cluster_endpoint_health_check_domain
  port              = 80
  type              = "HTTP"
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 10

  tags = {
    Name = "entity-management-eu-west-1"
  }
}

# Global IAM for cross-region operations
resource "aws_iam_role" "cross_region_replication" {
  name = "openclaw-cross-region-replication"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonRDSReplicationRole"]
}

# DynamoDB global table for session/app state
resource "aws_dynamodb_table" "openclaw_global_state" {
  name           = "openclaw-global-state"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "PK"
  range_key      = "SK"
  stream_enabled = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  replica {
    region_name = "eu-west-1"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name        = "openclaw-global-state"
    Environment = local.environment
  }
}

# Global ACM Certificate (used by both regions)
resource "aws_acm_certificate" "openclaw_api" {
  domain_name       = "api.openclaw.io"
  validation_method = "DNS"

  subject_alternative_names = [
    "*.us-east-1.api.openclaw.io",
    "*.eu-west-1.api.openclaw.io",
  ]

  lifecycle {
    create_before_destroy = true
  }
  tags = {
    Environment = local.environment
  }
}
