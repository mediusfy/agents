module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.34"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true

  enable_cluster_creator_admin_permissions = false

  cluster_addons = {
    coredns = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent = true
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
    }
    aws-ebs-csi-driver = {
      most_recent = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    system = {
      name           = "system"
      use_name_prefix = true
      subnet_ids     = module.vpc.private_subnets

      min_size     = 2
      max_size     = 6
      desired_size = 2

      instance_types = ["m7i.large"]
      capacity_type  = "ON_DEMAND"

      taints = {
        system = {
          key    = "node.kubernetes.io/type"
          value  = "system"
          effect = "NO_SCHEDULE"
        }
      }

      labels = { "node.kubernetes.io/role" = "system" }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      tags = { "k8s.io/cluster-autoscaler/enabled" = "true" }
    }

    application-spot = {
      name           = "application-spot"
      use_name_prefix = true
      subnet_ids     = module.vpc.private_subnets

      min_size     = 2
      max_size     = 10
      desired_size = 3

      instance_types = var.node_instance_types
      capacity_type  = "SPOT"

      labels = {
        "node.kubernetes.io/role"      = "application"
        "karpenter.sh/capacity-type"   = "spot"
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      tags = { "k8s.io/cluster-autoscaler/enabled" = "true" }
    }
  }

  manage_aws_auth_configmap = true

  tags = { Name = local.cluster_name }
}

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

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name_prefix = "${local.cluster_name}-ebs-csi-"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

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
          "kms:Decrypt"
        ]
        Resource = [
          "arn:aws:secretsmanager:eu-west-1:*:secret:openclaw-*",
          "arn:aws:kms:eu-west-1:*:key/*"
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
          "rds:DescribeDBInstances"
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
