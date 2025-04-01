variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "eks-cluster"
}

variable "argocd_helm_chart_version" {
  description = "Version of the Argo CD Helm chart"
  type        = string
  default     = "5.51.4"  # Use a specific version for consistency
}

variable "create_namespace" {
  description = "Whether to create the argocd namespace"
  type        = bool
  default     = false  # Default to false since it seems to already exist
}

# Variable for bcrypt function
variable "bcrypt_hash_function" {
  description = "Function to generate bcrypt hash"
  type        = string
  default     = "bcrypt"
} 