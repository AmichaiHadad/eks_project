# domain.ps1
# Script to configure ArgoCD with custom domain using Route53 and ACM

<#
.SYNOPSIS
Configures custom domain and TLS certificates for ArgoCD

.DESCRIPTION
Automates:
- Route53 DNS record creation
- ACM certificate request/validation
- Service annotation updates
- Certificate association with ALB

Handles:
- Domain validation records
- Certificate status monitoring
- Multi-region deployments

.PREREQUISITES
- AWS CLI with Route53/ACM access
- Existing hosted zone
- kubectl access
- PowerShell 7+

.USAGE
.\domain.ps1 [-Domain "argocd.example.com"]
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$Domain = ""
)

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

function Write-Step {
    param([string]$Message)
    Write-Host "`n>> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✅ $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠️ $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "❌ $Message" -ForegroundColor Red
}

function Check-Command {
    param([string]$Command)
    
    try {
        Get-Command $Command -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# Check prerequisites
Write-Step "Checking prerequisites"
$prerequisites = @("aws", "kubectl")
$missing = @()
foreach ($prereq in $prerequisites) {
    if (-not (Check-Command $prereq)) {
        $missing += $prereq
    }
}

if ($missing.Count -gt 0) {
    Write-Error "Missing required tools: $($missing -join ', ')"
    exit 1
}
Write-Success "All prerequisites found"

# Get AWS region
Write-Step "Checking AWS configuration"
$awsRegion = aws configure get region
if (-not $awsRegion) {
    $awsRegion = "us-east-1"  # Default if not configured
    Write-Warning "AWS Region not set in config, using default: $awsRegion"
}
else {
    Write-Success "Using AWS Region: $awsRegion"
}

# Check EKS cluster region consistency
$eksRegion = aws eks describe-cluster --name eks-cluster --query "cluster.arn" --output text 2>$null
if ($eksRegion) {
    $eksRegion = $eksRegion.Split(':')[3]  # Extract region from ARN
    if ($eksRegion -ne $awsRegion) {
        Write-Warning "EKS cluster is in $eksRegion but AWS CLI is configured for $awsRegion"
        $proceed = Read-Host "Continue with potentially mismatched regions? (y/n)"
        if ($proceed -ne "y") {
            Write-Error "Aborting due to region mismatch. Run 'aws configure' to set the correct region."
            exit 1
        }
    }
    else {
        Write-Success "EKS cluster and AWS CLI region match: $awsRegion"
    }
}

# Add region validation check earlier in the script
Write-Step "Verifying AWS Region consistency"
if ($awsRegion -ne "us-east-1") {
    Write-Warning "ELB is in us-east-1 but AWS CLI is configured for $awsRegion"
    Write-Host "Route53 is global, but Load Balancer and ACM certificate must be in the same region as ELB (us-east-1)" -ForegroundColor Yellow
    $awsRegion = "us-east-1"
    $regionParam = "--region $awsRegion"
    Write-Success "Overriding region to us-east-1 for certificate and ELB operations"
}

# Ask for domain if not provided
if (-not $Domain) {
    $Domain = Read-Host "Enter the desired domain for ArgoCD (e.g. argocd.blizzard.co.il)"
}

# Validate domain format
if (-not $Domain -or -not ($Domain -match "^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$")) {
    Write-Error "Invalid domain format: $Domain"
    exit 1
}

# Extract base domain correctly
$parts = $Domain.Split('.')
if ($parts.Count -lt 3) {
    # If only 2 parts (like example.com), use as is
    $baseDomain = $Domain
    Write-Warning "Using $Domain as both the base domain and subdomain"
}
else {
    # For domains like argocd.blizzard.co.il, extract blizzard.co.il
    $subdomainPart = $parts[0]
    $baseDomain = $Domain.Substring($subdomainPart.Length + 1)
    Write-Success "Using base domain: $baseDomain and subdomain: $Domain"
}

try {
    # Get ELB domain from ArgoCD service
    Write-Step "Getting ELB domain from ArgoCD service"
    $elbDomain = kubectl get svc argocd-server-lb -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
    if (-not $elbDomain) {
        Write-Error "Failed to get ELB domain from ArgoCD service"
        exit 1
    }
    Write-Success "Found ELB domain: $elbDomain"

    # Get Route 53 hosted zone ID
    Write-Step "Getting Route 53 hosted zone ID for $baseDomain"
    $hostedZones = aws route53 list-hosted-zones --query "HostedZones[?Name=='$baseDomain.'].Id" --output text
    
    if (-not $hostedZones) {
        Write-Error "No hosted zone found for $baseDomain"
        Write-Warning "Make sure you've created a hosted zone for $baseDomain in Route 53"
        exit 1
    }
    
    $hostedZoneId = $hostedZones.Replace("/hostedzone/", "").Trim()
    Write-Success "Found hosted zone ID: $hostedZoneId"

    # Check for existing certificate
    Write-Step "Checking for existing certificate for $Domain"
    $existingCertArn = aws --region us-east-1 acm list-certificates --query "CertificateSummaryList[?DomainName=='$Domain'].CertificateArn" --output text
    if ($existingCertArn) {
        Write-Success "Found existing certificate: $existingCertArn"
        $certStatus = aws --region us-east-1 acm describe-certificate --certificate-arn $existingCertArn --query "Certificate.Status" --output text
        Write-Host "Certificate status: $certStatus" -ForegroundColor Yellow
        
        if ($certStatus -eq "ISSUED") {
            Write-Success "Certificate is already issued and valid"
            $certArn = $existingCertArn
            $skipCertRequest = $true
        }
        else {
            $proceed = Read-Host "Found existing certificate that's not issued. Create new one? (y/n)"
            if ($proceed -ne "y") {
                Write-Host "Using existing certificate: $existingCertArn" -ForegroundColor Yellow
                $certArn = $existingCertArn
                $skipCertRequest = $true
            }
        }
    }
    else {
        Write-Host "No existing certificate found for $Domain" -ForegroundColor Yellow
        $skipCertRequest = $false
    }

    # Check for existing DNS records
    Write-Step "Checking for existing DNS records"
    $existingRecord = aws route53 list-resource-record-sets --hosted-zone-id $hostedZoneId --query "ResourceRecordSets[?Name=='$Domain.' && Type=='CNAME']" --output json | ConvertFrom-Json
    if ($existingRecord.Count -gt 0) {
        Write-Success "Found existing CNAME record for $Domain"
        $existingValue = $existingRecord[0].ResourceRecords[0].Value
        Write-Host "Current value: $existingValue" -ForegroundColor Yellow
        Write-Host "ELB domain: $elbDomain" -ForegroundColor Yellow
        
        if ($existingValue -ne $elbDomain) {
            $proceed = Read-Host "CNAME record points to different value. Update it? (y/n)"
            if ($proceed -ne "y") {
                Write-Host "Keeping existing CNAME record" -ForegroundColor Yellow
                $skipCnameUpdate = $true
            }
        }
        else {
            Write-Success "CNAME record already points to correct ELB"
            $skipCnameUpdate = $true
        }
    }
    else {
        Write-Host "No existing CNAME record found for $Domain" -ForegroundColor Yellow
        $skipCnameUpdate = $false
    }

    # Request ACM certificate
    if (-not $skipCertRequest) {
        Write-Step "Requesting ACM certificate for $Domain"
        $certArn = aws --region us-east-1 acm request-certificate --domain-name $Domain --validation-method DNS --query "CertificateArn" --output text
        
        if (-not $certArn) {
            Write-Error "Failed to request ACM certificate"
            exit 1
        }
        Write-Success "Requested ACM certificate: $certArn"
    }
    else {
        Write-Success "Using existing certificate: $certArn"
    }

    # Add validation CNAME records
    Write-Step "Adding DNS validation records"
    Start-Sleep -Seconds 5 # Wait for certificate details to propagate
    
    $validationOptions = aws --region us-east-1 acm describe-certificate --certificate-arn $certArn --query "Certificate.DomainValidationOptions" --output json | ConvertFrom-Json
    if (-not $validationOptions) {
        Write-Error "Failed to get certificate validation options"
        exit 1
    }
    
    $validationDomain = $validationOptions[0].ResourceRecord.Name
    $validationValue = $validationOptions[0].ResourceRecord.Value
    
    if (-not $validationDomain -or -not $validationValue) {
        Write-Error "Failed to get validation record details"
        exit 1
    }
    
    $validationJson = @"
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$validationDomain",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "$validationValue"
          }
        ]
      }
    }
  ]
}
"@
    
    $validationFile = "validation-record.json"
    Set-Content -Path $validationFile -Value $validationJson
    
    aws route53 change-resource-record-sets --hosted-zone-id $hostedZoneId --change-batch file://$validationFile | Out-Null
    Write-Success "Added validation record for certificate"
    
    # Create CNAME record for ArgoCD
    if (-not $skipCnameUpdate) {
        Write-Step "Creating CNAME record for $Domain pointing to $elbDomain"
        $recordJson = @"
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$Domain",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "$elbDomain"
          }
        ]
      }
    }
  ]
}
"@
        
        $recordFile = "record-set.json"
        Set-Content -Path $recordFile -Value $recordJson
        
        aws route53 change-resource-record-sets --hosted-zone-id $hostedZoneId --change-batch file://$recordFile | Out-Null
        Write-Success "Created CNAME record for $Domain"
    }
    else {
        Write-Success "Using existing CNAME record for $Domain"
    }
    
    # Wait for certificate validation
    Write-Step "Waiting for certificate validation (this may take 5-15 minutes)"
    Write-Host "Checking every 30 seconds..."
    $isValid = $false
    $attempts = 0
    $maxAttempts = 30 # 15 minutes
    
    while (-not $isValid -and $attempts -lt $maxAttempts) {
        $attempts++
        $status = aws --region us-east-1 acm describe-certificate --certificate-arn $certArn --query "Certificate.Status" --output text
        Write-Host "Attempt ${attempts}/${maxAttempts}: Certificate status: $status"
        
        if ($status -eq "ISSUED") {
            $isValid = $true
        }
        else {
            Start-Sleep -Seconds 30
        }
    }
    
    if (-not $isValid -and $attempts -eq 10) {
        # After 5 minutes, let the user decide whether to continue waiting or manually verify
        Write-Host "`n==================================================" -ForegroundColor Magenta
        Write-Host "Certificate validation is still in progress..." -ForegroundColor Yellow
        Write-Host "You can check the ACM console to monitor status:" -ForegroundColor Yellow
        Write-Host "https://console.aws.amazon.com/acm/home?region=$awsRegion#/certificates/list" -ForegroundColor Cyan
        Write-Host "`nOptions:" -ForegroundColor White
        Write-Host "1. Continue waiting automatically (script will check every 30 seconds)" -ForegroundColor White
        Write-Host "2. Pause until you manually confirm validation is complete" -ForegroundColor White
        $option = Read-Host "Enter option (1 or 2)"
        
        if ($option -eq "2") {
            Write-Host "`nScript paused. Check the AWS Console for certificate status." -ForegroundColor Yellow
            Write-Host "Certificate ARN: $certArn" -ForegroundColor Cyan
            Read-Host "Press ENTER once the certificate status shows as 'ISSUED' in AWS Console"
            $isValid = $true
        }
    }
    
    if (-not $isValid) {
        Write-Warning "Certificate validation is taking longer than expected"
        Write-Warning "You can continue checking status with: aws acm describe-certificate --certificate-arn $certArn --query Certificate.Status"
        Write-Warning "Once issued, you can update the service with: kubectl patch svc argocd-server-lb -n argocd --type=merge -p '{\"metadata\":{\"annotations\":{\"service.beta.kubernetes.io/aws-load-balancer-ssl-cert\":\"$certArn\"}}}'}"
    }
    else {
        Write-Success "Certificate has been validated and issued!"
        
        # Update ArgoCD service with certificate
        Write-Step "Updating ArgoCD service with certificate"
        $patchJson = @{
            metadata = @{
                annotations = @{
                    "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "http"
                    "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"        = "443"
                    "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"         = $certArn
                }
            }
        } | ConvertTo-Json -Compress

        kubectl patch svc argocd-server-lb -n argocd --type=merge -p $patchJson
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to update ArgoCD service with certificate"
            exit 1
        }
        Write-Success "Updated ArgoCD service with certificate"
        
        # Check and update credentials file
        Write-Step "Checking ArgoCD credentials"
        $credentialsPath = "./argocd-credentials.txt"
        if (Test-Path $credentialsPath) {
            Write-Success "Found existing credentials file"
            $currentPassword = kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" 
            | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }
            if ($currentPassword) {
                $credentialsContent = @"
ArgoCD Server URL: https://$Domain
Username: admin
Password: $currentPassword
"@
                Set-Content -Path $credentialsPath -Value $credentialsContent
                Write-Success "Updated credentials file with new URL and password"
            }
            else {
                Write-Warning "Could not retrieve current password from Terragrunt output"
            }
        }
        else {
            Write-Warning "Credentials file not found at: $credentialsPath"
        }
        
        # Final instructions
        Write-Host "`n-------------------------------------------------" -ForegroundColor Magenta
        Write-Host "✨ Setup Complete! ✨" -ForegroundColor Magenta
        Write-Host "-------------------------------------------------" -ForegroundColor Magenta
        Write-Host "You can now access ArgoCD at: https://$Domain" -ForegroundColor Cyan
        Write-Host "Certificate ARN: $certArn" -ForegroundColor Cyan
        Write-Host "Username: admin" -ForegroundColor Cyan
        Write-Host "Password: $currentPassword" -ForegroundColor Cyan
        Write-Host "`nCredentials have been saved to: $credentialsPath" -ForegroundColor Yellow
        Write-Host "`nTo login using the CLI:" -ForegroundColor Yellow
        Write-Host "argocd login https://$Domain --username admin --password '$currentPassword' --insecure" -ForegroundColor Yellow
        Write-Host "`nAfter logging in, change the default password using:" -ForegroundColor Yellow
        Write-Host "argocd account update-password" -ForegroundColor Yellow
        Write-Host "It may take a few minutes for DNS changes to propagate" -ForegroundColor Yellow
        Write-Host "-------------------------------------------------" -ForegroundColor Magenta
    }
}
catch {
    Write-Error "An error occurred: $_"
    Write-Error $_.ScriptStackTrace
    exit 1
}