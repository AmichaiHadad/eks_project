# ArgoCD on EKS Deployment Guide

This project provides an automated setup for deploying ArgoCD on an AWS EKS cluster with HTTPS support and custom domain integration. The deployment is fully automated using Terraform/Terragrunt and includes scripts for both Windows (PowerShell) and Linux/macOS (Bash) environments.

## What's Included

- **ArgoCD Deployment**: Fully automated deployment of ArgoCD on EKS with proper configurations
- **HTTPS Support**: TLS termination at AWS Load Balancer with ACM certificate integration
- **Custom Domain**: Automated setup of Route53 DNS records and ACM certificate validation
- **Terragrunt/Terraform**: Infrastructure as code for repeatable, reliable deployments
- **Health Checks**: Automatic validation of deployment health and component status
- **Credential Management**: Secure handling of ArgoCD admin credentials

## Prerequisites

- **EKS Cluster**: An existing EKS cluster (ensure its name matches `eks-cluster` in configuration)
- **AWS CLI**: Configured with appropriate credentials and permissions
- **Kubectl**: Installed and configured to connect to your EKS cluster
- **Terraform**: Version 1.0.0+
- **Terragrunt**: Version 0.35.0+
- **PowerShell 7+** (for Windows) or **Bash 4+** (for Linux/macOS)
- **Route53**: Hosted zone for your domain (if using custom domain)

## Installation Guide

### Step 1: Deploy ArgoCD

Choose the appropriate script based on your operating system:

#### For Windows:
```powershell
.\deploy-argocd.ps1
```

#### For Linux/macOS:
```bash
chmod +x deploy-argocd.sh
./deploy-argocd.sh
```

This will:
1. Verify cluster connectivity
2. Check for management nodes (ArgoCD is configured to run on nodes labeled `role=management`)
3. Clean up any existing ArgoCD installation
4. Deploy ArgoCD using Terragrunt
5. Wait for all pods to be running
6. Create a LoadBalancer for external access
7. Retrieve and save the admin credentials to `argocd-credentials.txt`

The deployment typically takes 5-10 minutes. When complete, you'll have ArgoCD running with a load balancer endpoint.

### Step 2: Configure Custom Domain and HTTPS (Optional)

If you want to use a custom domain with HTTPS:

#### For Windows:
```powershell
.\domain.ps1 -Domain "argocd.yourdomain.com"
```

#### For Linux/macOS:
```bash
chmod +x domain.sh
./domain.sh argocd.yourdomain.com
```

This will:
1. Request an AWS ACM certificate for your domain
2. Create required DNS validation records in Route53
3. Wait for certificate validation (5-15 minutes)
4. Create a CNAME record pointing your domain to the ArgoCD load balancer
5. Configure the ArgoCD service to use the new certificate
6. Update the credentials file with the new domain URL

> **Note**: You must own the domain and have a Route53 hosted zone configured for it.

### Step 3: Access ArgoCD

After deployment:

1. Open the ArgoCD server URL in your browser (from the output or `argocd-credentials.txt`)
   - With custom domain: `https://argocd.yourdomain.com`
   - Without custom domain: URL from the AWS load balancer

2. Login with:
   - Username: `admin`
   - Password: Found in `argocd-credentials.txt`

3. For CLI access:
   ```bash
   argocd login <SERVER_URL> --username admin --password <PASSWORD> --insecure
   ```

4. Change the default password immediately:
   ```bash
   argocd account update-password
   ```

## Configuration Details

### Node Placement

ArgoCD is configured to run on the management node group with:
- **Node affinity**: Targets nodes with label `role=management`
- **Tolerations**: Includes tolerations for the taint `dedicated=management:NoSchedule`

If you don't have nodes with this label, the deployment script will ask if you want to continue. You can either:
- Label some nodes: `kubectl label nodes <node-name> role=management`
- Proceed without labeled nodes (ArgoCD will run on any available nodes)

### Security

- TLS is terminated at the AWS Load Balancer
- A self-signed certificate is used by default if no custom domain is configured
- With custom domain, an ACM certificate is automatically requested and configured
- Admin password is randomly generated and stored in `argocd-credentials.txt`

### Resource Requirements

ArgoCD components have the following resource requests:

- **ArgoCD Server**: 100m CPU, 128Mi memory
- **Repo Server**: 100m CPU, 128Mi memory
- **Application Controller**: 250m CPU, 256Mi memory
- **Redis**: 100m CPU, 128Mi memory

Ensure your cluster has sufficient resources available.

## Troubleshooting

### Checking Deployment Status

```bash
kubectl get pods -n argocd
```

All pods should be in `Running` state.

### Debugging HTTPS/TLS Issues

If you experience issues with HTTPS:

#### For Windows:
```powershell
.\utility scripts\debug-argocd-tls.ps1
```

#### For Linux/macOS:
```bash
chmod +x utility\ scripts/debug-argocd-tls.sh
./utility\ scripts/debug-argocd-tls.sh
```

### Checking EKS Nodes

To verify node availability and configuration:

#### For Windows:
```powershell
.\utility scripts\check-eks-nodes.ps1
```

#### For Linux/macOS:
```bash
chmod +x utility\ scripts/check-eks-nodes.sh
./utility\ scripts/check-eks-nodes.sh
```

### Common Issues

1. **Pending Pods**: Check node capacity and taints
   ```bash
   kubectl describe nodes
   ```

2. **Certificate Validation Timeout**: If ACM validation takes longer than 15 minutes
   - Verify DNS records using AWS Console or `dig`
   - Check Route53 hosted zone configuration

3. **Load Balancer Unavailable**: If ELB doesn't initialize
   ```bash
   kubectl describe service argocd-server-lb -n argocd
   ```

4. **Terragrunt Issues**: Clean cache and retry
   ```bash
   rm -rf terragrunt/argocd/.terragrunt-cache
   cd terragrunt/argocd
   terragrunt init --reconfigure
   terragrunt apply
   ```

5. **Cannot Access Web UI**: Try port-forwarding as a fallback
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```
   Then access at https://localhost:8080

## Project Structure

```
.
├── terraform/                  # Terraform configuration
│   └── argocd/                 # ArgoCD Terraform module
│       ├── main.tf             # Main configuration
│       ├── variables.tf        # Variables
│       ├── values.yaml         # Helm chart values
│       └── versions.tf         # Provider versions
│
├── terragrunt/                 # Terragrunt configuration
│   ├── terragrunt.hcl          # Root configuration
│   └── argocd/                 # ArgoCD-specific config
│       └── terragrunt.hcl      
│
├── deploy-argocd.ps1           # Windows deployment script
├── deploy-argocd.sh            # Linux/macOS deployment script
├── domain.ps1                  # Windows domain setup script
├── domain.sh                   # Linux/macOS domain setup script
├── utility scripts/            # Helper scripts
└── argocd-credentials.txt      # Generated credentials
```

## Next Steps

After deploying ArgoCD:
1. Connect your Git repositories
2. Create applications for deployment
3. Set up proper RBAC for your team
4. Configure SSO (if needed)

## Security Notes

- The credentials file contains sensitive information - secure or delete after use
- Change the default admin password immediately after first login
- Consider implementing SSO for production use
- Review the ArgoCD security documentation for best practices 