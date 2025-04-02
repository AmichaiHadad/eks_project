#!/bin/bash
# Configures custom domain and TLS certificates for ArgoCD
#
# Automates:
# - Route53 DNS record creation
# - ACM certificate request/validation
# - Service annotation updates
# - Certificate association with ALB
#
# Handles:
# - Domain validation records
# - Certificate status monitoring
# - Multi-region deployments
#
# Prerequisites:
# - AWS CLI with Route53/ACM access
# - Existing hosted zone
# - kubectl access
# - Bash 4.2+
#
# Usage:
# ./domain.sh [domain] (e.g. ./domain.sh argocd.example.com)

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Functions for pretty output
function print_step() {
  echo -e "\n${CYAN}>> $1${NC}"
}

function print_success() {
  echo -e "${GREEN}✅ $1${NC}"
}

function print_warning() {
  echo -e "${YELLOW}⚠️ $1${NC}"
}

function print_error() {
  echo -e "${RED}❌ $1${NC}"
}

function check_command() {
  if ! command -v $1 &> /dev/null; then
    return 1
  fi
  return 0
}

# Handle errors
function handle_error() {
  print_error "An error occurred on line $1"
  exit 1
}

trap 'handle_error $LINENO' ERR

# Check prerequisites
print_step "Checking prerequisites"
missing=()
for cmd in aws kubectl; do
  if ! check_command $cmd; then
    missing+=($cmd)
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  print_error "Missing required tools: ${missing[*]}"
  exit 1
fi
print_success "All prerequisites found"

# Ask for domain if not provided
if [ "$1" != "" ]; then
  DOMAIN="$1"
else
  read -p "Enter the desired domain for ArgoCD (e.g. argocd.blizzard.co.il): " DOMAIN
fi

# Validate domain format
if [[ ! $DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
  print_error "Invalid domain format: $DOMAIN"
  exit 1
fi

# Extract base domain (last two parts)
IFS='.' read -ra DOMAIN_PARTS <<< "$DOMAIN"
if [ ${#DOMAIN_PARTS[@]} -lt 2 ]; then
  print_error "Domain must have at least a subdomain and top-level domain"
  exit 1
fi
BASE_DOMAIN="${DOMAIN_PARTS[-2]}.${DOMAIN_PARTS[-1]}"
print_success "Using base domain: $BASE_DOMAIN and subdomain: $DOMAIN"

# Get ELB domain from ArgoCD service
print_step "Getting ELB domain from ArgoCD service"
ELB_DOMAIN=$(kubectl get svc argocd-server-lb -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
if [ -z "$ELB_DOMAIN" ]; then
  print_error "Failed to get ELB domain from ArgoCD service"
  exit 1
fi
print_success "Found ELB domain: $ELB_DOMAIN"

# Get Route 53 hosted zone ID
print_step "Getting Route 53 hosted zone ID for $BASE_DOMAIN"
HOSTED_ZONES=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='$BASE_DOMAIN.'].Id" --output text)

if [ -z "$HOSTED_ZONES" ]; then
  print_error "No hosted zone found for $BASE_DOMAIN"
  print_warning "Make sure you've created a hosted zone for $BASE_DOMAIN in Route 53"
  exit 1
fi

HOSTED_ZONE_ID=$(echo $HOSTED_ZONES | sed 's/\/hostedzone\///')
print_success "Found hosted zone ID: $HOSTED_ZONE_ID"

# Request ACM certificate
print_step "Requesting ACM certificate for $DOMAIN"
CERT_ARN=$(aws acm request-certificate --domain-name $DOMAIN --validation-method DNS --query "CertificateArn" --output text)

if [ -z "$CERT_ARN" ]; then
  print_error "Failed to request ACM certificate"
  exit 1
fi
print_success "Requested ACM certificate: $CERT_ARN"

# Add validation CNAME records
print_step "Adding DNS validation records"
echo "Waiting 5 seconds for certificate details to propagate..."
sleep 5

VALIDATION_DOMAIN=$(aws acm describe-certificate --certificate-arn $CERT_ARN --query "Certificate.DomainValidationOptions[0].ResourceRecord.Name" --output text)
VALIDATION_VALUE=$(aws acm describe-certificate --certificate-arn $CERT_ARN --query "Certificate.DomainValidationOptions[0].ResourceRecord.Value" --output text)

if [ -z "$VALIDATION_DOMAIN" ] || [ -z "$VALIDATION_VALUE" ]; then
  print_error "Failed to get validation record details"
  exit 1
fi

cat > validation-record.json << EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$VALIDATION_DOMAIN",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "$VALIDATION_VALUE"
          }
        ]
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch file://validation-record.json > /dev/null
print_success "Added validation record for certificate"

# Create CNAME record for ArgoCD
print_step "Creating CNAME record for $DOMAIN pointing to $ELB_DOMAIN"
cat > record-set.json << EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DOMAIN",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "$ELB_DOMAIN"
          }
        ]
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch file://record-set.json > /dev/null
print_success "Created CNAME record for $DOMAIN"

# Wait for certificate validation
print_step "Waiting for certificate validation (this may take 5-15 minutes)"
echo "Checking every 30 seconds..."
IS_VALID=false
ATTEMPTS=0
MAX_ATTEMPTS=30 # 15 minutes

while [ "$IS_VALID" = false ] && [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
  ATTEMPTS=$((ATTEMPTS+1))
  STATUS=$(aws acm describe-certificate --certificate-arn $CERT_ARN --query "Certificate.Status" --output text)
  echo "Attempt $ATTEMPTS/$MAX_ATTEMPTS: Certificate status: $STATUS"
  
  if [ "$STATUS" = "ISSUED" ]; then
    IS_VALID=true
  else
    sleep 30
  fi
done

if [ "$IS_VALID" = false ]; then
  print_warning "Certificate validation is taking longer than expected"
  print_warning "You can continue checking status with: aws acm describe-certificate --certificate-arn $CERT_ARN --query Certificate.Status"
  print_warning "Once issued, you can update the service with: kubectl patch svc argocd-server-lb -n argocd --type=merge -p '{\"metadata\":{\"annotations\":{\"service.beta.kubernetes.io/aws-load-balancer-ssl-cert\":\"$CERT_ARN\"}}}'"
else
  print_success "Certificate has been validated and issued!"
  
  # Update ArgoCD service with certificate
  print_step "Updating ArgoCD service with certificate"
  kubectl patch svc argocd-server-lb -n argocd --type=merge -p '{"metadata":{"annotations":{"service.beta.kubernetes.io/aws-load-balancer-backend-protocol":"http","service.beta.kubernetes.io/aws-load-balancer-ssl-ports":"443","service.beta.kubernetes.io/aws-load-balancer-ssl-cert":"'$CERT_ARN'"}}}'
  
  if [ $? -ne 0 ]; then
    print_error "Failed to update ArgoCD service with certificate"
    exit 1
  fi
  print_success "Updated ArgoCD service with certificate"
  
  # Check and update credentials file
  print_step "Checking ArgoCD credentials"
  CREDENTIALS_PATH="../../argocd-credentials.txt"
  if [ -f "$CREDENTIALS_PATH" ]; then
    print_success "Found existing credentials file"
    CURRENT_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d)
    if [ -n "$CURRENT_PASSWORD" ]; then
      cat > "$CREDENTIALS_PATH" << EOF
ArgoCD Server URL: https://$DOMAIN
Username: admin
Password: $CURRENT_PASSWORD
EOF
      print_success "Updated credentials file with new URL and password"
    else
      print_warning "Could not retrieve current password from Kubernetes secret"
    fi
  else
    print_warning "Credentials file not found at: $CREDENTIALS_PATH"
  fi
  
  # Final instructions
  echo -e "\n${CYAN}-------------------------------------------------${NC}"
  echo -e "${CYAN}✨ Setup Complete! ✨${NC}"
  echo -e "${CYAN}-------------------------------------------------${NC}"
  echo -e "${CYAN}You can now access ArgoCD at: https://$DOMAIN${NC}"
  echo -e "${CYAN}Certificate ARN: $CERT_ARN${NC}"
  echo -e "${CYAN}Username: admin${NC}"
  echo -e "${CYAN}Password: $CURRENT_PASSWORD${NC}"
  echo -e "${YELLOW}Credentials have been saved to: $CREDENTIALS_PATH${NC}"
  echo -e "${YELLOW}To login using the CLI:${NC}"
  echo -e "${CYAN}argocd login https://$DOMAIN --username admin --password '$CURRENT_PASSWORD' --insecure${NC}"
  echo -e "${YELLOW}After logging in, change the default password using:${NC}"
  echo -e "${CYAN}argocd account update-password${NC}"
  echo -e "${YELLOW}It may take a few minutes for DNS changes to propagate${NC}"
  echo -e "${CYAN}-------------------------------------------------${NC}"
fi

# Clean up temporary files
rm -f validation-record.json record-set.json