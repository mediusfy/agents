# =============================================================================
# IAM Roles & IRSA
# =============================================================================
# OIDC provider + IRSA roles for fine-grained pod identity
# =============================================================================

data "aws_iam_policy_document" "oidc_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }

    principals {
      identifiers = [module.eks.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

# VPC CNI IRSA
module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name_prefix       = "${local.cluster_name}-vpc-cni-"
  attach_vpc_cni_policy  = true
  vpc_cni_enable_ipv4    = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
}

# EBS CSI Driver IRSA
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name_prefix             = "${local.cluster_name}-ebs-csi-"
  attach_ebs_csi_policy        = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# External Secrets IRSA
module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name_prefix = "${local.cluster_name}-external-secrets-"
  attach_custom_policy = true
  custom_policy_name   = "${local.cluster_name}-secrets-reader"

  custom_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets",
          "kms:Decrypt"
        ]
        Resource = [
          "arn:aws:secretsmanager:us-east-1:*:secret:openclaw-*",
          "arn:aws:kms:us-east-1:*:key/*"
        ]
      }
    ]
  })

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

# Application IRSA for entity-management
module "app_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name_prefix = "${local.cluster_name}-entity-mgmt-"
  attach_custom_policy = true
  custom_policy_name   = "${local.cluster_name}-entity-management"

  custom_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags",
          "rds:DescribeDBInstances",
          "rds:DescribeDBClusters"
        ]
        Resource = ["*"]
      }
    ]
  })

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["entity-management:entity-management-sa"]
    }
  }
}
