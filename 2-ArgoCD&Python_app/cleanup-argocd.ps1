Write-Host "Starting Argo CD cleanup process..." -ForegroundColor Cyan

# Check if Argo CD namespace exists
$argocdNamespace = kubectl get ns argocd --no-headers --ignore-not-found
if ($argocdNamespace) {
    Write-Host "Argo CD namespace found. Proceeding with cleanup..." -ForegroundColor Yellow
    
    # Check if there are any helm releases
    $helmReleases = helm list -n argocd --no-headers
    if ($helmReleases) {
        Write-Host "Found Helm releases in the argocd namespace. Uninstalling..." -ForegroundColor Yellow
        helm uninstall argocd -n argocd
        
        # Wait a bit for the uninstallation to complete
        Write-Host "Waiting for Helm uninstallation to complete..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }
    else {
        Write-Host "No Helm releases found in argocd namespace." -ForegroundColor Green
    }
    
    # Delete the namespace
    Write-Host "Deleting the argocd namespace..." -ForegroundColor Yellow
    kubectl delete ns argocd --wait=false
    
    # Wait for namespace deletion
    Write-Host "Waiting for namespace deletion (this might take a few minutes)..." -ForegroundColor Yellow
    $timeoutSeconds = 300
    $elapsed = 0
    $intervalSeconds = 5
    
    while ($elapsed -lt $timeoutSeconds) {
        $namespaceExists = kubectl get ns argocd --no-headers --ignore-not-found
        if (-not $namespaceExists) {
            Write-Host "Namespace successfully deleted!" -ForegroundColor Green
            break
        }
        
        Write-Host "Namespace still terminating... ($elapsed seconds elapsed)" -ForegroundColor Yellow
        Start-Sleep -Seconds $intervalSeconds
        $elapsed += $intervalSeconds
    }
    
    if ($elapsed -ge $timeoutSeconds) {
        Write-Host "Warning: Namespace deletion is taking longer than expected. You may need to check for stuck finalizers." -ForegroundColor Red
        
        # Provide command to force delete namespace if needed
        Write-Host "To force delete the namespace, you might need to run:" -ForegroundColor Magenta
        Write-Host "kubectl get namespace argocd -o json | ConvertFrom-Json | ForEach-Object { `$_.spec.finalizers = @(); `$_ } | ConvertTo-Json | kubectl replace --raw /api/v1/namespaces/argocd/finalize -f -" -ForegroundColor Magenta
    }
}
else {
    Write-Host "Argo CD namespace not found. Nothing to clean up." -ForegroundColor Green
}

Write-Host "Cleanup process completed!" -ForegroundColor Green
Write-Host "You can now deploy Argo CD using Terragrunt:" -ForegroundColor Cyan
Write-Host "cd terragrunt/argocd" -ForegroundColor Cyan
Write-Host "terragrunt apply" -ForegroundColor Cyan 