Write-Host "Fixing Argo CD deployment issues..." -ForegroundColor Cyan

$valuesPath = "terraform/argocd/values.yaml"

# Backup the original values file
Copy-Item $valuesPath "${valuesPath}.bak"
Write-Host "Backed up original values file to ${valuesPath}.bak" -ForegroundColor Green

# Read the current content
$content = Get-Content $valuesPath -Raw

# Create a new version of values.yaml with relaxed node scheduling constraints
$newContent = @"
## Argo CD Helm chart values
global:
  image:
    tag: v2.9.3
  securityContext:
    runAsUser: 999
    runAsGroup: 999
    fsGroup: 999

# Server configurations
server:
  extraArgs:
    - --insecure # Disable strict TLS verification (remove in production)
  
  # Optional node selection - if nodes with these labels exist
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: role
            operator: In
            values:
            - management
  
  # Make tolerations more flexible
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "management"
      effect: "NoSchedule"
    - key: "dedicated"
      operator: "Exists"
      effect: "NoSchedule"

  # Use the custom admin password secret - this is now using base64 encoding
  admin:
    enabled: true
    passwordSecret:
      name: \${admin_password_secret_name}
      key: password
    createSecret: false

  # Configure the server's resources
  resources:
    limits:
      cpu: 300m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 128Mi

  # Optional RBAC configuration for users
  rbacConfig:
    policy.csv: |
      # Basic RBAC policy
      g, admin, role:admin
      g, reader, role:readonly

      # Add custom roles as needed
      g, deployer, role:deployer

    # Define a custom role with specific permissions
    policy.default: role:readonly
    scopes: "[groups, preferred_username]"

# Configure repository server
repoServer:
  # Optional node selection - if nodes with these labels exist
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: role
            operator: In
            values:
            - management
  
  # Make tolerations more flexible
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "management"
      effect: "NoSchedule"
    - key: "dedicated"
      operator: "Exists"
      effect: "NoSchedule"

  resources:
    limits:
      cpu: 300m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 128Mi

# Configure application controller
controller:
  # Optional node selection - if nodes with these labels exist
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: role
            operator: In
            values:
            - management
  
  # Make tolerations more flexible
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "management"
      effect: "NoSchedule"
    - key: "dedicated"
      operator: "Exists"
      effect: "NoSchedule"

  resources:
    limits:
      cpu: 500m
      memory: 1Gi
    requests:
      cpu: 250m
      memory: 256Mi

# Configure Redis for caching
redis:
  # Optional node selection - if nodes with these labels exist
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: role
            operator: In
            values:
            - management
  
  # Make tolerations more flexible
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "management"
      effect: "NoSchedule"
    - key: "dedicated"
      operator: "Exists"
      effect: "NoSchedule"

  resources:
    limits:
      cpu: 200m
      memory: 256Mi
    requests:
      cpu: 100m
      memory: 128Mi

# Configure applicationset controller
applicationSet:
  # Optional node selection - if nodes with these labels exist
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: role
            operator: In
            values:
            - management
  
  # Make tolerations more flexible
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "management"
      effect: "NoSchedule"
    - key: "dedicated"
      operator: "Exists"
      effect: "NoSchedule"

# Configure dex server
dex:
  # Optional node selection - if nodes with these labels exist
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: role
            operator: In
            values:
            - management
  
  # Make tolerations more flexible
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "management"
      effect: "NoSchedule"
    - key: "dedicated"
      operator: "Exists"
      effect: "NoSchedule"

# Configure initial repositories
configs:
  repositories:
    # Add your Git repositories here
    my-private-repo:
      url: https://github.com/example/private-repo.git
      type: git
      # For private repositories, add credentials
      # passwordSecret:
      #   name: repo-secret
      #   key: password
      # usernameSecret:
      #   name: repo-secret
      #   key: username

  # Configure SSO credentials if needed
  # dex.config: |
  #   connectors:
  #     - type: github
  #       id: github
  #       name: GitHub
  #       config:
  #         clientID: <your-client-id>
  #         clientSecret: <your-client-secret>
  #         orgs:
  #           - name: your-org-name

# Configure resource customizations
resourceCustomizations:
  # Add custom health checks or resource handling
  health.lua: |
    health_status = {}
    if obj.status ~= nil then
      if obj.status.conditions ~= nil then
        for i, condition in ipairs(obj.status.conditions) do
          if condition.type == "Ready" and condition.status == "True" then
            health_status.status = "Healthy"
            health_status.message = condition.message
            return health_status
          end
        end
      end
    end
    health_status.status = "Progressing"
    health_status.message = "Waiting for resource to become Ready"
    return health_status
"@

# Write the new content to the file
Set-Content -Path $valuesPath -Value $newContent
Write-Host "Updated values file with relaxed node scheduling constraints" -ForegroundColor Green

# Now we need to update the helm_release in main.tf to recreate the chart
$mainTfPath = "terraform/argocd/main.tf"
$mainTfContent = Get-Content $mainTfPath -Raw

# Add create_namespace = true to helm_release
if ($mainTfContent -notmatch "create_namespace\s*=\s*true") {
    $modifiedContent = $mainTfContent -replace "(resource\s+`"helm_release`"\s+`"argocd`"\s+\{.*?name\s*=\s*`"argocd`")", "`$1`n  create_namespace     = true" 
    Set-Content -Path $mainTfPath -Value $modifiedContent
    Write-Host "Added create_namespace = true to helm_release in main.tf" -ForegroundColor Green
}
else {
    Write-Host "create_namespace = true is already in main.tf" -ForegroundColor Yellow
}

# Clean up any existing resources to ensure a fresh deployment
Write-Host "`nCleaning up existing Argo CD deployment..." -ForegroundColor Cyan
kubectl delete ns argocd --ignore-not-found

# Wait for the namespace to be fully deleted
$timeoutSeconds = 120
$elapsed = 0
$intervalSeconds = 5

while ($elapsed -lt $timeoutSeconds) {
    $namespaceExists = kubectl get ns argocd --no-headers --ignore-not-found
    if (-not $namespaceExists) {
        Write-Host "Namespace successfully deleted!" -ForegroundColor Green
        break
    }
    
    Write-Host "Waiting for namespace deletion... ($elapsed seconds elapsed)" -ForegroundColor Yellow
    Start-Sleep -Seconds $intervalSeconds
    $elapsed += $intervalSeconds
}

# Clean Terragrunt cache
Write-Host "`nCleaning Terragrunt cache..." -ForegroundColor Cyan
Remove-Item -Path "terragrunt/argocd/.terragrunt-cache" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`nReady to redeploy Argo CD with improved configuration:" -ForegroundColor Green
Write-Host "1. Now run: cd terragrunt/argocd" -ForegroundColor Cyan
Write-Host "2. Then run: terragrunt apply -auto-approve" -ForegroundColor Cyan 