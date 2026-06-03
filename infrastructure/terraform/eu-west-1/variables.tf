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
