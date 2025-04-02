#!/usr/bin/env pwsh
# Script to debug and fix ArgoCD HTTPS issues

<#
.SYNOPSIS
Diagnoses and fixes HTTPS/TLS configuration issues for ArgoCD

.DESCRIPTION
Checks:
- TLS certificate secrets
- Load balancer annotations
- ArgoCD server configuration
- SSL handshake validity

Automatically applies fixes for:
- Certificate mismatches
- Service misconfigurations
- Security policy issues

.PREREQUISITES
- OpenSSL installed
- kubectl access to cluster
- PowerShell 7+

.USAGE
.\debug-argocd-tls.ps1
#>

$ErrorActionPreference = "Stop"
Write-Host "ArgoCD TLS Debugging and Fixing Script" -ForegroundColor Cyan

# Get ELB domain
$ELB_DOMAIN = kubectl get svc argocd-server-lb -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
Write-Host "LoadBalancer domain: $ELB_DOMAIN" -ForegroundColor Green

# Check for ArgoCD server pod
$serverPodName = kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}' 2>$null
if (-not $serverPodName) {
    Write-Host "❌ No ArgoCD server pod found! Deployment may have failed completely." -ForegroundColor Red
    Write-Host "Checking all pods in argocd namespace:" -ForegroundColor Yellow
    kubectl get pods -n argocd
    
    $continue = Read-Host -Prompt "Do you want to continue with TLS troubleshooting anyway? (y/n)"
    if ($continue -ne "y") {
        Write-Host "Exiting. Please fix the ArgoCD deployment first." -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host "✅ ArgoCD server pod found: $serverPodName" -ForegroundColor Green
}

# 1. Check if the TLS secret exists
Write-Host "`n1. Checking TLS secret..." -ForegroundColor Yellow
$tlsSecret = kubectl get secret argocd-server-tls -n argocd --ignore-not-found -o json | ConvertFrom-Json
if ($tlsSecret) {
    Write-Host "  ✅ TLS secret exists" -ForegroundColor Green
    
    # Check if the secret has proper data
    if ($tlsSecret.data.'tls.crt' -and $tlsSecret.data.'tls.key') {
        Write-Host "  ✅ TLS secret has necessary certificate and key data" -ForegroundColor Green
    }
    else {
        Write-Host "  ❌ TLS secret is missing certificate or key data" -ForegroundColor Red
    }
}
else {
    Write-Host "  ❌ TLS secret 'argocd-server-tls' not found" -ForegroundColor Red
    
    # Regenerate the certificate
    Write-Host "`nRegenerating TLS certificate..." -ForegroundColor Yellow
    $CERT_DIR = "tls-cert"
    New-Item -Path $CERT_DIR -ItemType Directory -Force | Out-Null
    
    # Use a very simple certificate configuration with minimal information
    $CERT_CN = "argocd.local"
    $KEY_PATH = Join-Path $CERT_DIR "argocd-tls.key"
    $CERT_PATH = Join-Path $CERT_DIR "argocd-tls.crt"
    
    # Generate private key
    openssl genrsa -out $KEY_PATH 2048
    
    # Create simple config with only the minimal required fields
    $CONFIG_PATH = Join-Path $CERT_DIR "simple-openssl.cnf"
    @"
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = $CERT_CN
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = $ELB_DOMAIN
"@ | Set-Content -Path $CONFIG_PATH
    
    # Generate simple certificate
    openssl req -new -x509 -key $KEY_PATH -out $CERT_PATH -config $CONFIG_PATH -days 365
    
    # Create the TLS secret
    kubectl create secret tls argocd-server-tls -n argocd --cert=$CERT_PATH --key=$KEY_PATH --dry-run=client -o yaml | kubectl apply -f -
    Write-Host "  ✅ TLS secret recreated" -ForegroundColor Green
}

# 2. Check ArgoCD server deployment
Write-Host "`n2. Checking ArgoCD server deployment..." -ForegroundColor Yellow
$deployment = kubectl get deployment argocd-server -n argocd -o json | ConvertFrom-Json
$containers = $deployment.spec.template.spec.containers
$foundServer = $false
$needsConfigFix = $false

# Check if the deployment has the TLS args
foreach ($container in $containers) {
    if ($container.name -eq "argocd-server") {
        $foundServer = $true
        $args = $container.args
        if (-not $args) { $args = $container.command }
        
        # Check for --tlsCertPath and --tlsKeyPath which would conflict with ELB TLS termination
        $hasTlsCertPath = $args -contains "--tlsCertPath"
        $hasTlsKeyPath = $args -contains "--tlsKeyPath"
        $hasInsecure = $args -contains "--insecure"
        
        if ($hasTlsCertPath -or $hasTlsKeyPath) {
            Write-Host "  ❌ ArgoCD server has TLS args (--tlsCertPath or --tlsKeyPath) which CONFLICTS with AWS ELB TLS termination" -ForegroundColor Red
            Write-Host "  The best practice is to let AWS ELB handle TLS termination, not the ArgoCD server" -ForegroundColor Yellow
            $needsConfigFix = $true
        }
        else {
            Write-Host "  ✅ ArgoCD server doesn't have TLS args that would conflict with AWS ELB" -ForegroundColor Green
        }
        
        if ($hasInsecure) {
            Write-Host "  ✅ ArgoCD server has --insecure flag, which is CORRECT for AWS ELB TLS termination" -ForegroundColor Green
        }
        else {
            Write-Host "  ❌ ArgoCD server is MISSING --insecure flag, which is REQUIRED for AWS ELB TLS termination" -ForegroundColor Red
            $needsConfigFix = $true
        }
        
        # Check volume mounts
        $foundTlsMount = $false
        foreach ($mount in $container.volumeMounts) {
            if ($mount.name -eq "argocd-server-tls") {
                $foundTlsMount = $true
                Write-Host "  ❌ ArgoCD server has TLS volume mounted at $($mount.mountPath) which is NOT needed for AWS ELB TLS" -ForegroundColor Red
                $needsConfigFix = $true
                break
            }
        }
        if (-not $foundTlsMount) {
            Write-Host "  ✅ ArgoCD server doesn't have TLS volume mounted, which is CORRECT for AWS ELB TLS termination" -ForegroundColor Green
        }
        break
    }
}

if (-not $foundServer) {
    Write-Host "  ❌ ArgoCD server container not found in deployment" -ForegroundColor Red
}

# 3. Check LoadBalancer service
Write-Host "`n3. Checking LoadBalancer service..." -ForegroundColor Yellow
$service = kubectl get svc argocd-server-lb -n argocd -o json | ConvertFrom-Json
$annotations = $service.metadata.annotations
$needsServiceFix = $false

# The correct configuration should have:
# - aws-load-balancer-backend-protocol: "http" (not https)
# - aws-load-balancer-ssl-ports: "443" or "https"
# - aws-load-balancer-ssl-negotiation-policy: present

$backendProtocol = $annotations.'service.beta.kubernetes.io/aws-load-balancer-backend-protocol'
$sslPorts = $annotations.'service.beta.kubernetes.io/aws-load-balancer-ssl-ports'
$sslPolicy = $annotations.'service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy'

# Check backend protocol - should be HTTP for ELB TLS termination
if ($backendProtocol -eq "http") {
    Write-Host "  ✅ LoadBalancer has CORRECT backend protocol: http" -ForegroundColor Green
}
elseif ($backendProtocol -eq "https") {
    Write-Host "  ❌ LoadBalancer has INCORRECT backend protocol: https. Should be http!" -ForegroundColor Red
    $needsServiceFix = $true
}
else {
    Write-Host "  ❓ LoadBalancer backend protocol: $backendProtocol (should be 'http')" -ForegroundColor Yellow
    $needsServiceFix = $true
}

# Check SSL ports
if ($sslPorts -eq "443" -or $sslPorts -eq "https") {
    Write-Host "  ✅ LoadBalancer has SSL ports configured correctly: $sslPorts" -ForegroundColor Green
}
else {
    Write-Host "  ❓ LoadBalancer SSL ports: $sslPorts (should be '443' or 'https')" -ForegroundColor Yellow
    $needsServiceFix = $true
}

# Check SSL policy
if ($sslPolicy) {
    Write-Host "  ✅ LoadBalancer has SSL negotiation policy: $sslPolicy" -ForegroundColor Green
}
else {
    Write-Host "  ❌ LoadBalancer is missing SSL negotiation policy" -ForegroundColor Red
    $needsServiceFix = $true
}

# Check if service has https port defined
$hasHttpsPort = $false
foreach ($port in $service.spec.ports) {
    if ($port.name -eq "https" -and $port.port -eq 443) {
        $hasHttpsPort = $true
        
        # Check target port - should be 8080 (HTTP port) for ELB TLS termination
        if ($port.targetPort -eq 8080) {
            Write-Host "  ✅ LoadBalancer HTTPS port has correct targetPort: 8080" -ForegroundColor Green
        }
        else {
            Write-Host "  ❌ LoadBalancer HTTPS port has incorrect targetPort: $($port.targetPort) (should be 8080)" -ForegroundColor Red
            $needsServiceFix = $true
        }
    }
}
if (-not $hasHttpsPort) {
    Write-Host "  ❌ LoadBalancer is missing HTTPS port definition" -ForegroundColor Red
    $needsServiceFix = $true
}

# 4. Fix identified issues
Write-Host "`n4. Fixing identified issues..." -ForegroundColor Yellow

# Fix ArgoCD server deployment if needed
if ($needsConfigFix) {
    Write-Host "  🛠️ Fixing ArgoCD server deployment..." -ForegroundColor Yellow
    
    # Create a JSON patch that sets ONLY the --insecure flag and removes TLS args
    $SERVER_PATCH_FILE = Join-Path "tls-cert" "server-patch.json"
    
    @"
[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/command",
    "value": [
      "argocd-server",
      "--staticassets",
      "/shared/app",
      "--insecure"
    ]
  }
]
"@ | Set-Content -Path $SERVER_PATCH_FILE
    
    # Apply the JSON patch
    kubectl patch deployment argocd-server -n argocd --type json --patch-file $SERVER_PATCH_FILE
    Write-Host "  ✅ Patched ArgoCD server deployment to use ONLY --insecure flag" -ForegroundColor Green
}

# Fix LoadBalancer service if needed
if ($needsServiceFix) {
    Write-Host "  🛠️ Fixing LoadBalancer service..." -ForegroundColor Yellow
    $SERVICE_PATCH_FILE = Join-Path "tls-cert" "service-patch.yaml"
    
    @"
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
    service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy: "ELBSecurityPolicy-TLS-1-2-2017-01"
spec:
  ports:
  - name: http
    port: 80
    targetPort: 8080
  - name: https
    port: 443
    targetPort: 8080
"@ | Set-Content -Path $SERVICE_PATCH_FILE
    
    # Apply the patch
    kubectl patch service argocd-server-lb -n argocd --patch-file $SERVICE_PATCH_FILE
    Write-Host "  ✅ Patched LoadBalancer service with correct TLS configuration" -ForegroundColor Green
    
    # The critical change is setting backend protocol to "http" instead of "https"
    Write-Host "  ⚠️ Important: Changed LoadBalancer backend protocol to HTTP (ELB will terminate TLS)" -ForegroundColor Yellow
}

# Only restart if fixes were applied
if ($needsConfigFix -or $needsServiceFix) {
    Write-Host "`n5. Restarting ArgoCD server deployment..." -ForegroundColor Yellow
    kubectl rollout restart deployment argocd-server -n argocd
    
    # Wait for restart with a detailed progress display
    Write-Host "   Waiting for ArgoCD server to restart (can take 1-2 minutes)..." -ForegroundColor Yellow
    
    $totalWait = 0
    $maxWait = 120
    $interval = 5
    $ready = $false
    
    while (-not $ready -and $totalWait -lt $maxWait) {
        $deployment = kubectl rollout status deployment argocd-server -n argocd --timeout=1s 2>&1
        if ($deployment -match "successfully rolled out") {
            $ready = $true
            break
        }
        
        $totalWait += $interval
        $percent = [math]::Min(100, [int](($totalWait / $maxWait) * 100))
        Write-Host "   Progress: $percent% ($totalWait seconds elapsed)" -ForegroundColor Yellow
        Start-Sleep -Seconds $interval
    }
    
    if ($ready) {
        Write-Host "  ✅ ArgoCD server restarted successfully" -ForegroundColor Green
    }
    else {
        Write-Host "  ⚠️ Timeout waiting for ArgoCD server restart. This is not necessarily an error." -ForegroundColor Yellow
        Write-Host "     The changes are still applied, but the server might still be restarting." -ForegroundColor Yellow
    }
}
else {
    Write-Host "`n✅ No issues requiring fixes were found!" -ForegroundColor Green
}

# 6. Final SSL connection test
Write-Host "`n6. Testing SSL connectivity..." -ForegroundColor Yellow
Write-Host "  Note: AWS ELB can take 3-5 minutes to update its TLS configuration" -ForegroundColor Yellow
Write-Host "  Waiting 30 seconds before testing SSL connection..." -ForegroundColor Yellow
Start-Sleep -Seconds 30

# Create temporary directory if it doesn't exist
$CERT_DIR = "tls-cert"
New-Item -Path $CERT_DIR -ItemType Directory -Force | Out-Null

# Run the openssl command and capture its output
$tempFile = Join-Path $CERT_DIR "openssl-output.txt"
$opensslArgs = "s_client -connect ${ELB_DOMAIN}:443 -servername ${ELB_DOMAIN} -showcerts -timeout 10"
Write-Host "  Running: openssl $opensslArgs" -ForegroundColor Gray
Start-Process -FilePath "openssl" -ArgumentList $opensslArgs -RedirectStandardOutput $tempFile -RedirectStandardError "$tempFile.err" -NoNewWindow -Wait
$opensslExitCode = $LASTEXITCODE
$opensslOutput = Get-Content -Path $tempFile -ErrorAction SilentlyContinue
$opensslErrOutput = Get-Content -Path "$tempFile.err" -ErrorAction SilentlyContinue

# Check if the output contains a successful handshake
$success = $false
if ($opensslOutput -match "SSL handshake has read" -and $opensslOutput -match "New, TLSv" -and $opensslExitCode -eq 0) {
    $success = $true
}

if ($success) {
    Write-Host "`n===== SUCCESS! SSL CONNECTION ESTABLISHED =====" -ForegroundColor Green
    Write-Host "✅ TLS connection to $ELB_DOMAIN was successful" -ForegroundColor Green
    Write-Host "✅ HTTPS is properly configured" -ForegroundColor Green
    Write-Host "✅ You can now access ArgoCD securely at https://$ELB_DOMAIN" -ForegroundColor Green
}
else {
    Write-Host "`n⚠️ SSL connection test not yet successful" -ForegroundColor Yellow
    Write-Host "This is NORMAL immediately after configuration changes. AWS ELB updates take time." -ForegroundColor Yellow
    
    # Show proper error message if there was one
    if ($opensslErrOutput) {
        Write-Host "Error details:" -ForegroundColor Red
        foreach ($line in $opensslErrOutput) {
            Write-Host "  $line" -ForegroundColor Red
        }
    }
    
    # Show first few lines of output if available
    if ($opensslOutput) {
        Write-Host "Output excerpt:" -ForegroundColor Gray
        for ($i = 0; $i -lt [Math]::Min(5, $opensslOutput.Count); $i++) {
            Write-Host "  $($opensslOutput[$i])" -ForegroundColor Gray
        }
    }
}

# End with advice
Write-Host "`n===================== IMPORTANT NEXT STEPS =====================" -ForegroundColor Magenta
Write-Host "1. AWS ELB needs 3-5 minutes to fully propagate TLS changes." -ForegroundColor White
Write-Host "2. Run this script again in 5 minutes if HTTPS still doesn't work." -ForegroundColor White
Write-Host "3. You can manually test with:" -ForegroundColor White
Write-Host "   openssl s_client -connect ${ELB_DOMAIN}:443 -servername ${ELB_DOMAIN}" -ForegroundColor Cyan
Write-Host "4. Try accessing ArgoCD at: https://$ELB_DOMAIN" -ForegroundColor White
Write-Host "5. Use these credentials:" -ForegroundColor White

# Try to get ArgoCD admin password
try {
    $password = (Get-Content -Path "argocd-credentials.txt" -ErrorAction SilentlyContinue | Select-String -Pattern "Password: " | ForEach-Object { $_ -replace "Password: ", "" }) 
    if ($password) {
        Write-Host "   Username: admin" -ForegroundColor Cyan
        Write-Host "   Password: $password" -ForegroundColor Cyan
    }
    else {
        Write-Host "   See argocd-credentials.txt for login details" -ForegroundColor Cyan
    }
}
catch {
    Write-Host "   See argocd-credentials.txt for login details" -ForegroundColor Cyan
} 