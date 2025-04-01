# PowerShell script to fix AWS VPC CNI issues

Write-Host "Fixing VPC CNI issues..." -ForegroundColor Cyan

# Set variables
$CLUSTER_NAME = "eks-cluster"
$REGION = "us-east-1"
$VPC_CNI_ROLE_NAME = "${CLUSTER_NAME}-vpc-cni-role"

# Get AWS account ID
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
Write-Host "AWS Account ID: $ACCOUNT_ID"

# Get OIDC provider URL from the cluster
Write-Host "Getting OIDC provider URL from EKS cluster..."
$OIDC_PROVIDER = (aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.identity.oidc.issuer" --output text).Replace("https://", "")
Write-Host "OIDC Provider: $OIDC_PROVIDER"

# Create trust policy - Fixed with proper condition structure
Write-Host "Creating trust policy for VPC CNI role..." -ForegroundColor Green
$trustPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:aws-node",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
"@
Set-Content -Path trust-policy.json -Value $trustPolicy

# Create or update the IAM role
try {
  $roleInfo = aws iam get-role --role-name $VPC_CNI_ROLE_NAME 2>$null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "Role exists, updating trust policy..." -ForegroundColor Green
    aws iam update-assume-role-policy --role-name $VPC_CNI_ROLE_NAME --policy-document file://trust-policy.json
  } 
  else {
    Write-Host "Creating new role..." -ForegroundColor Yellow
    aws iam create-role --role-name $VPC_CNI_ROLE_NAME --assume-role-policy-document file://trust-policy.json
    aws iam attach-role-policy --role-name $VPC_CNI_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
  }
} 
catch {
  Write-Host "Creating new role after error..." -ForegroundColor Yellow
  aws iam create-role --role-name $VPC_CNI_ROLE_NAME --assume-role-policy-document file://trust-policy.json
  aws iam attach-role-policy --role-name $VPC_CNI_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
}

# Set the role ARN
$ROLE_ARN = "arn:aws:iam::${ACCOUNT_ID}:role/${VPC_CNI_ROLE_NAME}"

# Annotate the service account
Write-Host "Annotating service account with IAM role..." -ForegroundColor Green
kubectl annotate serviceaccount -n kube-system aws-node eks.amazonaws.com/role-arn=$ROLE_ARN --overwrite

# Restart the aws-node pods
Write-Host "Restarting aws-node pods to pick up new role..." -ForegroundColor Yellow
kubectl delete pods -n kube-system -l k8s-app=aws-node

# Wait for the addon to finish updating before trying to update it again
Write-Host "Waiting for VPC CNI addon to stabilize..." -ForegroundColor Yellow
$stableStates = @("ACTIVE", "DEGRADED")
$maxAttempts = 12
$attempt = 0
$isStable = $false

while (-not $isStable -and $attempt -lt $maxAttempts) {
  $attempt++
  Start-Sleep -Seconds 15
    
  $addonStatus = (aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name vpc-cni --region $REGION --query "addon.status" --output text)
  Write-Host "Current VPC CNI addon status: $addonStatus (Attempt $attempt of $maxAttempts)" -ForegroundColor Yellow
    
  if ($stableStates -contains $addonStatus) {
    $isStable = $true
  }
}

if ($isStable) {
  # Update VPC CNI addon with the IAM role
  Write-Host "Updating VPC CNI addon with the IAM role..." -ForegroundColor Green
  aws eks update-addon --cluster-name $CLUSTER_NAME --addon-name vpc-cni --service-account-role-arn $ROLE_ARN --resolve-conflicts OVERWRITE --region $REGION
}
else {
  Write-Host "VPC CNI addon did not stabilize in time. Current IRSA annotation should be sufficient." -ForegroundColor Yellow
}

# Clean up
Remove-Item -Path trust-policy.json -Force

Write-Host "VPC CNI fix completed!" -ForegroundColor Green
Write-Host "Check status with: kubectl get pods -n kube-system -l k8s-app=aws-node" -ForegroundColor Cyan 