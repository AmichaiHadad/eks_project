#!/usr/bin/env pwsh
# Script to properly deploy ArgoCD to the EKS cluster with HTTPS support

<#
.SYNOPSIS
Deploys ArgoCD to EKS cluster with proper cleanup and validation

.DESCRIPTION
Performs:
- Complete cleanup of previous installations
- Terraform-based deployment using Terragrunt
- Health checks for ArgoCD components
- Load balancer configuration
- Credential generation and security

.PREREQUISITES
- Terraform & Terragrunt installed
- AWS CLI authenticated
- kubectl configured for EKS
- PowerShell 7+

.USAGE
.\deploy-argocd.ps1
#>

$ErrorActionPreference = "Stop"
Write-Host "Starting ArgoCD deployment process with HTTPS support..." -ForegroundColor Cyan

# Verify EKS cluster is running and accessible
Write-Host "Verifying EKS cluster access..." -ForegroundColor Yellow
try {
  $clusterInfo = kubectl cluster-info
  if (-not $?) { throw "Failed to connect to Kubernetes cluster" }
  Write-Host "Successfully connected to the cluster" -ForegroundColor Green
}
catch {
  Write-Host "Error: Cannot connect to the EKS cluster. Please check your kubeconfig." -ForegroundColor Red
  Write-Host "Run: aws eks update-kubeconfig --region us-east-1 --name eks-cluster" -ForegroundColor Yellow
  exit 1
}

# Check for management nodes
Write-Host "Checking for management nodes..." -ForegroundColor Yellow
$managementNodes = kubectl get nodes -l role=management --no-headers 2>$null

if (-not $managementNodes) {
  Write-Host "Warning: No nodes with label 'role=management' found." -ForegroundColor Red
  Write-Host "ArgoCD is configured to run on management nodes." -ForegroundColor Red
    
  $proceed = Read-Host "Do you want to proceed anyway? (y/n)"
  if ($proceed -ne "y") {
    exit 1
  }
}

# Clean up any existing ArgoCD installation
Write-Host "Cleaning up any existing ArgoCD installation..." -ForegroundColor Yellow
$argocdNamespace = kubectl get namespace argocd --ignore-not-found --no-headers

if ($argocdNamespace) {
  Write-Host "Existing ArgoCD namespace found. Cleaning up..." -ForegroundColor Yellow
    
  # Add this in the cleanup section after deleting applications and appprojects
  Write-Host "Cleaning up previous deployments and replicasets..." -ForegroundColor Yellow
  kubectl delete deployment argocd-server -n argocd --ignore-not-found
  kubectl delete replicaset -n argocd -l app.kubernetes.io/name=argocd-server --ignore-not-found
  kubectl delete pods -n argocd -l app.kubernetes.io/name=argocd-server --force --grace-period=0

  # Add this after deleting the namespace
  Write-Host "Ensuring all argocd-server resources are removed..." -ForegroundColor Yellow
  kubectl delete replicaset -n argocd -l app.kubernetes.io/name=argocd-server --ignore-not-found
  kubectl delete pods -n argocd -l app.kubernetes.io/name=argocd-server --force --grace-period=0
  Start-Sleep -Seconds 5  # Give Kubernetes time to process deletions

  # Add this after applying the Helm chart
  Write-Host "Ensuring single replica deployment..." -ForegroundColor Yellow
  kubectl patch deployment argocd-server -n argocd -p '{"spec":{"replicas":1}}'
  kubectl rollout status deployment argocd-server -n argocd --timeout=120s 

  # Check for Helm releases in the argocd namespace
  $helmReleases = helm list -n argocd --short
    
  if ($helmReleases) {
    Write-Host "Uninstalling Helm releases in argocd namespace..." -ForegroundColor Yellow
    foreach ($release in $helmReleases) {
      Write-Host "Uninstalling Helm release: $release" -ForegroundColor Yellow
      # Add --no-hooks and explicitly delete CRDs
      helm uninstall $release -n argocd --no-hooks
    }

    # Force delete CRDs that were preserved by Helm's resource policy
    Write-Host "Cleaning up ArgoCD CRDs..." -ForegroundColor Yellow
    kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io --ignore-not-found --force --grace-period=0 --cascade=background
  }
    
  # Delete any custom resources that might block namespace deletion
  Write-Host "Deleting ArgoCD custom resources..." -ForegroundColor Yellow
  kubectl delete applications --all -n argocd --ignore-not-found
  kubectl delete appprojects --all -n argocd --ignore-not-found

  
  # Delete the namespace
  Write-Host "Deleting argocd namespace..." -ForegroundColor Yellow
  kubectl delete namespace argocd --ignore-not-found
    
  # Wait for namespace to be fully deleted
  Write-Host "Waiting for namespace to be fully deleted..." -ForegroundColor Yellow
  $timeoutSeconds = 120
  $elapsed = 0
  $intervalSeconds = 5
    
  while ($elapsed -lt $timeoutSeconds) {
    $namespaceExists = kubectl get namespace argocd --ignore-not-found --no-headers
    if (-not $namespaceExists) {
      Write-Host "Namespace successfully deleted!" -ForegroundColor Green
      break
    }
        
    Write-Host "Waiting for namespace deletion... ($elapsed seconds elapsed)" -ForegroundColor Yellow
    Start-Sleep -Seconds $intervalSeconds
    $elapsed += $intervalSeconds
        
    # If it takes too long, try to force delete
    if ($elapsed -eq 60) {
      Write-Host "Attempting to force delete namespace..." -ForegroundColor Yellow
      kubectl get namespace argocd -o json | `
        ConvertFrom-Json | `
        ForEach-Object {
        $_.spec.finalizers = @()
        $_ 
      } | `
        ConvertTo-Json | `
        kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f -
    }
  }
    
  if ($elapsed -ge $timeoutSeconds) {
    Write-Host "Warning: Namespace deletion timed out. Proceeding anyway." -ForegroundColor Red
  }


}

# Clean Terragrunt cache
Write-Host "Cleaning Terragrunt cache..." -ForegroundColor Yellow
if (Test-Path "terragrunt/argocd/.terragrunt-cache") {
  Remove-Item -Path "terragrunt/argocd/.terragrunt-cache" -Recurse -Force
}

# Deploy ArgoCD using Terragrunt
Write-Host "Deploying ArgoCD using Terragrunt..." -ForegroundColor Green
Set-Location -Path "terragrunt/argocd"

Write-Host "Running terragrunt init..." -ForegroundColor Yellow
terragrunt init --reconfigure -lock=false

if ($LASTEXITCODE -ne 0) {
  Write-Host "Error: Terragrunt init failed" -ForegroundColor Red
  exit 1
}

Write-Host "Running terragrunt apply..." -ForegroundColor Yellow
terragrunt apply -auto-approve -lock=false

if ($LASTEXITCODE -ne 0) {
  Write-Host "Error: Terragrunt apply failed" -ForegroundColor Red
  exit 1
}

# Wait for LB to stabilize
Write-Host "Waiting for LoadBalancer to initialize (2-3 minutes)..." -ForegroundColor Yellow
Start-Sleep -Seconds 120

# Wait for ArgoCD pods to be ready
Write-Host "Waiting for ArgoCD pods to be ready..." -ForegroundColor Yellow
$timeoutSeconds = 300
$elapsed = 0
$intervalSeconds = 10
$allReady = $false

while ($elapsed -lt $timeoutSeconds) {
  $pods = kubectl get pods -n argocd -o jsonpath='{.items[*].status.phase}' 2>$null
  $podCount = ($pods -split " ").Count
  $runningCount = ($pods -split " " | Where-Object { $_ -eq "Running" }).Count
    
  if ($podCount -gt 0 -and $podCount -eq $runningCount) {
    $allReady = $true
    break
  }
    
  Write-Host "Waiting for pods to be ready... ($elapsed seconds elapsed)" -ForegroundColor Yellow
  Start-Sleep -Seconds $intervalSeconds
  $elapsed += $intervalSeconds
}

if ($allReady) {
  Write-Host "All ArgoCD pods are running!" -ForegroundColor Green
}
else {
  Write-Host "Warning: Not all ArgoCD pods are running. Check status with:" -ForegroundColor Red
  Write-Host "kubectl get pods -n argocd" -ForegroundColor Yellow
}

# Get the new ELB domain after recreation with increased timeout
Write-Host "  Waiting for LoadBalancer domain (this may take a few minutes)..." -ForegroundColor Yellow
$retryCount = 0
$maxRetries = 24  # 2 minutes (24 * 5 seconds)
$ELB_DOMAIN = $null

while ($retryCount -lt $maxRetries -and -not $ELB_DOMAIN) {
  $retryCount++
  Start-Sleep -Seconds 5
  $ELB_DOMAIN = kubectl get svc argocd-server-lb -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
  if ($ELB_DOMAIN) {
    Write-Host "  ✓ New LoadBalancer domain: $ELB_DOMAIN" -ForegroundColor Green
    break
  }
  Write-Host "  Waiting for LoadBalancer domain... ($($retryCount * 5) seconds elapsed)" -ForegroundColor Yellow
}

if (-not $ELB_DOMAIN) {
  Write-Host "  Warning: Could not get new LoadBalancer domain" -ForegroundColor Red
}

# Wait for the ArgoCD server pod to restart
Write-Host "Waiting for ArgoCD server pod to restart..." -ForegroundColor Yellow
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=120s

# Wait a bit for AWS LoadBalancer to stabilize
Write-Host "Waiting for AWS LoadBalancer to stabilize (this may take a few minutes)..." -ForegroundColor Yellow
Write-Host "  The AWS ELB typically takes 3-5 minutes to fully update its configuration." -ForegroundColor Yellow
Start-Sleep -Seconds 30

# Get the ArgoCD admin password
Write-Host "Retrieving ArgoCD admin password..." -ForegroundColor Yellow
$password = kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" 
| ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }

# Make sure we have a valid ELB domain
if (-not $ELB_DOMAIN) {
  # Try one more time to get the ELB domain
  Write-Host "Attempting to get the LoadBalancer domain one more time..." -ForegroundColor Yellow
  $ELB_DOMAIN = kubectl get svc argocd-server-lb -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
    
  if (-not $ELB_DOMAIN) {
    Write-Host "Warning: Could not get LoadBalancer domain. Using placeholder for now." -ForegroundColor Red
    $ELB_DOMAIN = "<LoadBalancer-Domain-Not-Available>"
    Write-Host "You can get the ELB domain later with: kubectl get svc argocd-server-lb -n argocd" -ForegroundColor Yellow
  }
  else {
    Write-Host "Successfully retrieved LoadBalancer domain: $ELB_DOMAIN" -ForegroundColor Green
  }
}

# Save credentials to a file
$credentialsPath = "../../argocd-credentials.txt"
Set-Content -Path $credentialsPath -Value @"
ArgoCD Server URL: https://$ELB_DOMAIN
Username: admin
Password: $password
"@

# Return to original directory
Set-Location -Path "../.."

Write-Host "`nArgoCD has been deployed successfully with HTTPS!" -ForegroundColor Green
Write-Host "Server URL: https://$ELB_DOMAIN" -ForegroundColor Cyan
Write-Host "Username: admin" -ForegroundColor Cyan
Write-Host "Password: $password" -ForegroundColor Cyan
Write-Host "`nCredentials have been saved to: $credentialsPath" -ForegroundColor Yellow
Write-Host "`nTo login using the CLI:" -ForegroundColor Yellow
Write-Host "argocd login https://$ELB_DOMAIN --username admin --password '$password' --insecure" -ForegroundColor Yellow
Write-Host "`nAfter logging in, change the default password using:" -ForegroundColor Yellow
Write-Host "argocd account update-password" -ForegroundColor Yellow
Write-Host "`nNote: Your browser will show a security warning due to the self-signed certificate." -ForegroundColor Yellow
Write-Host "You can safely proceed through this warning for testing purposes." -ForegroundColor Yellow

