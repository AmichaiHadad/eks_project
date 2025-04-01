#!/usr/bin/env pwsh
# Script to properly deploy ArgoCD to the EKS cluster

$ErrorActionPreference = "Stop"
Write-Host "Starting ArgoCD deployment process..." -ForegroundColor Cyan

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
    
    # Check for Helm releases in the argocd namespace
    $helmReleases = helm list -n argocd --short
    
    if ($helmReleases) {
        Write-Host "Uninstalling Helm releases in argocd namespace..." -ForegroundColor Yellow
        foreach ($release in $helmReleases -split "`n") {
            if ($release.Trim()) {
                Write-Host "Uninstalling Helm release: $release" -ForegroundColor Yellow
                helm uninstall $release -n argocd
            }
        }
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
terragrunt init --reconfigure

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

# Get the ArgoCD admin password
Write-Host "Retrieving ArgoCD admin password..." -ForegroundColor Yellow
$password = terragrunt output -raw argocd_admin_password

# Get the ArgoCD server URL
Write-Host "Retrieving ArgoCD server URL..." -ForegroundColor Yellow
$serverUrl = terragrunt output -raw argocd_server_url

# Save credentials to a file
$credentialsPath = "../../argocd-credentials.txt"
Set-Content -Path $credentialsPath -Value @"
ArgoCD Server URL: $serverUrl
Username: admin
Password: $password
"@

# Return to original directory
Set-Location -Path "../.."

Write-Host "`nArgoCD has been deployed successfully!" -ForegroundColor Green
Write-Host "Server URL: $serverUrl" -ForegroundColor Cyan
Write-Host "Username: admin" -ForegroundColor Cyan
Write-Host "Password: $password" -ForegroundColor Cyan
Write-Host "`nCredentials have been saved to: $credentialsPath" -ForegroundColor Yellow
Write-Host "`nTo login using the CLI:" -ForegroundColor Yellow
Write-Host "argocd login $serverUrl --username admin --password '$password' --insecure" -ForegroundColor Yellow
Write-Host "`nAfter logging in, change the default password using:" -ForegroundColor Yellow
Write-Host "argocd account update-password" -ForegroundColor Yellow 