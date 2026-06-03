variable "provider_aws_package" {
  description = "Crossplane AWS provider package URL"
  type        = string
  default     = "xpkg.upbound.io/upbound/provider-aws:v1.15.0"
}

variable "provider_kubernetes_package" {
  description = "Crossplane Kubernetes provider package URL"
  type        = string
  default     = "xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.0"
}

variable "provider_helm_package" {
  description = "Crossplane Helm provider package URL"
  type        = string
  default     = "xpkg.upbound.io/crossplane-contrib/provider-helm:v0.19.0"
}

variable "aws_credentials_json" {
  description = "JSON string of AWS credentials for Crossplane"
  type        = string
  sensitive   = true
}
