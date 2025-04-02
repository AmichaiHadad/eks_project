Write-Host "Checking EKS node availability and labels..." -ForegroundColor Cyan

# Get all nodes
Write-Host "`nListing all nodes:" -ForegroundColor Yellow
kubectl get nodes

# Check for nodes with the management role/tier
Write-Host "`nChecking for management nodes:" -ForegroundColor Yellow
kubectl get nodes -l role=management

# Check node details including taints
Write-Host "`nChecking node details and taints:" -ForegroundColor Yellow
kubectl get nodes -o json | ConvertFrom-Json | ForEach-Object { 
    $node = $_.items 
    foreach ($n in $node) {
        Write-Host "`nNode: $($n.metadata.name)" -ForegroundColor Green
        Write-Host "Labels:" -ForegroundColor Green
        $n.metadata.labels | ConvertTo-Json -Depth 1
        
        Write-Host "Taints:" -ForegroundColor Green
        if ($n.spec.taints) {
            $n.spec.taints | ConvertTo-Json -Depth 1
        }
        else {
            Write-Host "No taints"
        }
    }
}

# Check failing pods
Write-Host "`nChecking failing pods in argocd namespace:" -ForegroundColor Yellow
kubectl get pods -n argocd

# Check pod scheduling issues
Write-Host "`nChecking pod scheduling issues:" -ForegroundColor Yellow
kubectl get events -n argocd | Select-String -Pattern "fail|error|unable|cannot|taint"

# Check specific pod details for the ones failing
Write-Host "`nChecking details of failing applicationset-controller pod:" -ForegroundColor Yellow
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller

Write-Host "`nChecking details of failing dex-server pod:" -ForegroundColor Yellow
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-dex-server

Write-Host "`nChecking node capacity:" -ForegroundColor Yellow
kubectl describe nodes | Select-String -Pattern "Capacity|Allocatable" -Context 0, 5 