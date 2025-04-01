locals {
  # Parse the file path to extract the environment and stack
  path_components = split("/", path_relative_to_include())
  
  # Common tags for all resources
  common_tags = {
    ManagedBy   = "Terragrunt"
    Environment = "Production"
    Project     = "ArgoCD-Setup"
  }
}

# Remote state configuration
remote_state {
  backend = "s3"
  config = {
    bucket         = "eks-terraform-state-${get_aws_account_id()}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
    
    # Improve state locking with exponential backoff and TTL
    dynamodb_table_tags = {
      Name = "Terraform State Lock Table"
      Project = "ArgoCD-Setup"
    }
    
    # Configure S3 bucket details
    s3_bucket_tags = {
      Name = "Terraform State Storage"
      Project = "ArgoCD-Setup" 
    }
    
    # Force SSL for security
    force_path_style = false
    skip_bucket_versioning = false
    skip_bucket_ssencryption = false
    
    # Configure locking behavior
    skip_bucket_root_access = true
    skip_metadata_api_check = false
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

# Generate providers.tf file with provider configurations
generate "providers" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "us-east-1"
  
  # Configure robust retry behavior for AWS API calls
  max_retries = 25
  retry_mode = "standard"

  # Add explicit configuration for API operations
  skip_metadata_api_check = true
  skip_requesting_account_id = false
  
  # Default tags to apply to all resources
  default_tags {
    tags = {
      ManagedBy = "Terragrunt"
      Project = "ArgoCD-Setup"
    }
  }
}

provider "random" {
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}
EOF
}

# Configure terraform version requirements
terraform {
  extra_arguments "common_vars" {
    commands = [
      "plan",
      "apply",
      "destroy",
      "import",
      "push",
      "refresh",
    ]

    # Increase parallelism and configure lock timeouts
    arguments = [
      "-parallelism=30",
      "-lock-timeout=30m"
    ]
  }
}

# Inputs that are common to all stacks
inputs = {
  region = "us-east-1"
  tags   = local.common_tags
} 