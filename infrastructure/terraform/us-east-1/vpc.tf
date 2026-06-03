# =============================================================================
# VPC Module
# =============================================================================
# Immutable VPC with 3 AZs, private/public subnets, NAT Gateways
# Network segmentation for security compliance
# =============================================================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.18"

  name = "${local.cluster_name}-vpc"
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = true
  enable_dns_hostnames   = true
  enable_dns_support     = true
  enable_vpn_gateway     = false

  # Protect against accidental deletion
  manage_default_security_group  = false

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = local.cluster_name
  }

  tags = {
    Name = local.cluster_name
  }
}
