# =============================================================================
# OpenClaw - Terraform Variables (us-east-1)
# =============================================================================

variable "environment" {
  description = "Deployment environment (staging, production)"
  type        = string
  default     = "production"
}

variable "cluster_version" {
  description = "Kubernetes cluster version"
  type        = string
  default     = "1.32"
}

variable "node_instance_types" {
  description = "EC2 instance types for EKS node groups"
  type        = list(string)
  default     = ["m7i.large", "m7i.xlarge"]
}

variable "node_group_min_size" {
  description = "Minimum node count per AZ"
  type        = number
  default     = 2
}

variable "node_group_max_size" {
  description = "Maximum node count per AZ"
  type        = number
  default     = 10
}

variable "node_group_desired_size" {
  description = "Desired node count per AZ"
  type        = number
  default     = 3
}

variable "enable_spot_instances" {
  description = "Use spot instances for stateless workloads"
  type        = bool
  default     = true
}

variable "allowed_regions" {
  description = "List of regions for data residency compliance"
  type        = list(string)
  default     = ["us-east-1", "us-west-2", "eu-west-1", "eu-central-1"]
}
