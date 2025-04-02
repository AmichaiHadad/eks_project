data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

# Check if the argocd namespace already exists
data "kubernetes_namespace" "argocd" {
  count = var.create_namespace ? 0 : 1
  metadata {
    name = "argocd"
  }
}

# Only create namespace if it doesn't exist and create_namespace is true
resource "kubernetes_namespace" "argocd" {
  count = var.create_namespace ? 1 : 0
  metadata {
    name = "argocd"
    labels = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }
}

locals {
  namespace = var.create_namespace ? kubernetes_namespace.argocd[0].metadata[0].name : data.kubernetes_namespace.argocd[0].metadata[0].name
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_helm_chart_version
  namespace        = local.namespace
  create_namespace = true
  timeout          = 3600  # Increase timeout to 1 hour
  atomic           = false # Set to false to prevent rollback on failure
  cleanup_on_fail  = false # Don't try to clean up on failure
  wait             = true
  wait_for_jobs    = true
  recreate_pods    = false # Don't recreate pods, which can cause issues
  max_history      = 3
  
  # Force replacement to apply updated values
  force_update     = true
  replace          = true

  values = [
    templatefile("${path.module}/values.yaml", {
      admin_password_secret_name = kubernetes_secret.argocd_admin_password.metadata[0].name
    })
  ]

  depends_on = [
    kubernetes_secret.argocd_admin_password
  ]
}

# Generate a secure random password for the admin user
resource "random_password" "argocd_admin_password" {
  length           = 16
  special          = true
  override_special = "!@#$%^&*()_+"
}

# Store the password in a Kubernetes secret
resource "kubernetes_secret" "argocd_admin_password" {
  metadata {
    name      = "argocd-admin-password"
    namespace = local.namespace
  }

  data = {
    # Use base64 encoding for the password
    password = base64encode(random_password.argocd_admin_password.result)
  }

  type = "Opaque"
}

# Output the password for retrieval
output "argocd_admin_password" {
  value       = random_password.argocd_admin_password.result
  sensitive   = true
  description = "The admin password for Argo CD"
}

# Output the Argo CD server URL
output "argocd_server_url" {
  value       = "https://${kubernetes_service.argocd_server_lb.status.0.load_balancer.0.ingress.0.hostname}"
  description = "The URL to access Argo CD"
  depends_on  = [kubernetes_service.argocd_server_lb]
}

# Create a LoadBalancer service to expose the Argo CD server
resource "kubernetes_service" "argocd_server_lb" {
  metadata {
    name      = "argocd-server-lb"
    namespace = local.namespace
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"    = "http"
      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"           = "443"
      "service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy" = "ELBSecurityPolicy-TLS-1-2-2017-01"
    }
  }
  spec {
    selector = {
      "app.kubernetes.io/name" = "argocd-server"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
    port {
      name        = "https"
      port        = 443
      target_port = 8080
    }
    type = "LoadBalancer"
  }
  depends_on = [
    helm_release.argocd
  ]
} 


