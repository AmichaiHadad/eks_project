# PowerShell script to retrieve the Argo CD admin password and server URL

# Change to the Terragrunt directory
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -Path "$scriptPath\terragrunt\argocd"

# Get the admin password from Terraform outputs
Write-Host "Retrieving Argo CD admin password..."
$ARGOCD_PASSWORD = (terragrunt output -raw argocd_admin_password)

# Get the Argo CD server URL
Write-Host "Retrieving Argo CD server URL..."
$ARGOCD_SERVER_URL = (terragrunt output -raw argocd_server_url)

# Create a secure file with the credentials
Write-Host "Creating credentials file..."
$CREDS_FILE = "..\..\argocd-credentials.txt"
$credentials = @"
Argo CD Server URL: $ARGOCD_SERVER_URL
Username: admin
Password: $ARGOCD_PASSWORD
"@

Set-Content -Path $CREDS_FILE -Value $credentials

# Secure the file permissions (Windows method)
$acl = Get-Acl $CREDS_FILE
$acl.SetAccessRuleProtection($true, $false)
$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME, "FullControl", "Allow")
$acl.SetAccessRule($accessRule)
Set-Acl $CREDS_FILE $acl

$fullPath = Resolve-Path -Path "..\..\argocd-credentials.txt"
Write-Host "Credentials saved to: $fullPath"
Write-Host "Keep this file secure and delete it after you've configured your environment."
Write-Host ""
Write-Host "To login using the CLI:"
Write-Host "argocd login $ARGOCD_SERVER_URL --username admin --password '$ARGOCD_PASSWORD' --insecure"
Write-Host ""
Write-Host "After logging in, you should change the default password using:"
Write-Host "argocd account update-password" 