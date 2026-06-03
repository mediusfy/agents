variable "provider" {
  description = "Cloud provider: aws or gcp"
  type        = string
  validation {
    condition     = contains(["aws", "gcp"], var.provider)
    error_message = "Provider must be 'aws' or 'gcp'."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "region" {
  description = "Cloud region"
  type        = string
  default     = "eu-west-1"
}

variable "instance_class" {
  description = "AWS RDS instance class"
  type        = string
  default     = "db.t4g.medium"
}

variable "gcp_tier" {
  description = "GCP Cloud SQL tier"
  type        = string
  default     = "db-custom-2-8192"
}

variable "allocated_storage_gb" {
  description = "Allocated storage in GB"
  type        = number
  default     = 100
}

variable "max_allocated_storage_gb" {
  description = "Maximum storage auto-scaling limit in GB"
  type        = number
  default     = 500
}

variable "security_group_ids" {
  description = "AWS security group IDs for RDS"
  type        = list(string)
  default     = []
}

variable "db_subnet_group_name" {
  description = "AWS DB subnet group name"
  type        = string
  default     = ""
}

variable "private_network_id" {
  description = "GCP VPC network ID for private services"
  type        = string
  default     = ""
}
