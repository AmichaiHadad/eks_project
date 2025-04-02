include {
  path = find_in_parent_folders()
}

# Point to the Terraform configuration
terraform {
  source = "../../terraform/argocd"
}

# Define inputs specific to this module
inputs = {
  # Use the same cluster name as defined in the EKS Terragrunt configuration
  cluster_name = "eks-cluster"
  
  # Use the latest stable version of Argo CD Helm chart
  argocd_helm_chart_version = "5.51.4"
  
  # Set to true to create the namespace
  create_namespace = true
  
  # Region to use
  region = "us-east-1"

  # ACM Certificate ARN
  acm_cert_arn = ""
} 
