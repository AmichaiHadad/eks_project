#!/bin/bash
# Securely retrieves and displays ArgoCD admin credentials
#
# - Gets credentials from Terraform outputs
# - Creates protected credential file
# - Sets file permissions
# - Shows login instructions
#
# Prerequisites:
# - Terragrunt initialized
# - Bash 4.2+
# - Linux/Unix filesystem
#
# Usage:
# ./retrieve-argocd-password.sh

set -e

# Change to the Terragrunt directory
cd "$(dirname "$0")/terragrunt/argocd"

# Get the admin password from Terraform outputs
echo "Retrieving Argo CD admin password..."
ARGOCD_PASSWORD=$(terragrunt output -raw argocd_admin_password)

# Get the Argo CD server URL
echo "Retrieving Argo CD server URL..."
ARGOCD_SERVER_URL=$(terragrunt output -raw argocd_server_url)

# Create a secure file with the credentials
echo "Creating credentials file..."
CREDS_FILE="../../argocd-credentials.txt"
cat > "$CREDS_FILE" << EOF
Argo CD Server URL: ${ARGOCD_SERVER_URL}
Username: admin
Password: ${ARGOCD_PASSWORD}
EOF

# Set secure permissions
chmod 600 "$CREDS_FILE"

echo "Credentials saved to: $(cd "$(dirname "$0")" && pwd)/argocd-credentials.txt"
echo "Keep this file secure and delete it after you've configured your environment."
echo ""
echo "To login using the CLI:"
echo "argocd login ${ARGOCD_SERVER_URL} --username admin --password '${ARGOCD_PASSWORD}' --insecure"
echo ""
echo "After logging in, you should change the default password using:"
echo "argocd account update-password" 