# =============================================================================
# EKS Cluster Module
# =============================================================================
# Immutable, version-pinned EKS cluster with managed node groups.
# Security: IRSA, OIDC, restricted public access.
# =============================================================================

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.34"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = false
  cluster_endpoint_private_access          = true
  cluster_endpoint_public_access_cidrs     = []

  # Enhanced security: enable these for production
  enable_cluster_creator_admin_permissions = false

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
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

  # EKS Managed Node Groups - On-Demand for stateful workloads
  eks_managed_node_groups = {
    system = {
      name         = "system"
      use_name_prefix = true

      subnet_ids = module.vpc.private_subnets

      min_size     = 2
      max_size     = 6
      desired_size = 2

      instance_types = ["m7i.large"]

      capacity_type = "ON_DEMAND"

      taints = {
        system = {
          key    = "node.kubernetes.io/type"
          value  = "system"
          effect = "NO_SCHEDULE"
        }
      }

      labels = {
        "node.kubernetes.io/role" = "system"
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

      tags = {
        "k8s.io/cluster-autoscaler/enabled" = "true"
      }
    }

    # Spot for stateless workloads
    application-spot = {
      name         = "application-spot"
      use_name_prefix = true

      subnet_ids = module.vpc.private_subnets

      min_size     = 2
      max_size     = 10
      desired_size = 3

      instance_types = var.node_instance_types

      capacity_type = "SPOT"

      labels = {
        "node.kubernetes.io/role"       = "application"
        "karpenter.sh/capacity-type"    = "spot"
        "node.kubernetes.io/lifecycle"  = "spot"
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

      tags = {
        "k8s.io/cluster-autoscaler/enabled" = "true"
      }
    }
  }

  # Manage aws-auth configmap
  manage_aws_auth_configmap = true

  tags = {
    Name = local.cluster_name
  }
}
