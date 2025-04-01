# Argo CD Setup for EKS Cluster

This directory contains the Terraform and Terragrunt configurations to deploy Argo CD on the EKS cluster created in the infrastructure phase. The Argo CD deployment is configured to run on the management node group and is exposed via a LoadBalancer service.

## Prerequisites

- EKS cluster deployed using the Terraform/Terragrunt configuration in the `1-Infrastructure` directory
- AWS CLI configured with appropriate credentials
- kubectl installed and configured to connect to your EKS cluster
- Terraform (v1.0.0+)
- Terragrunt (v0.35.0+)

## Directory Structure

```
.
├── terraform/                  # Terraform configuration
│   └── argocd/                 # Argo CD Terraform module
│       ├── main.tf             # Main Terraform configuration
│       ├── variables.tf        # Variable definitions
│       ├── outputs.tf          # Output definitions
│       ├── versions.tf         # Required providers
│       └── values.yaml         # Helm chart values
│
├── terragrunt/                 # Terragrunt configuration
│   ├── terragrunt.hcl          # Root Terragrunt configuration
│   └── argocd/                 # Argo CD Terragrunt module
│       └── terragrunt.hcl      # Argo CD-specific configuration
│
├── deploy-argocd.ps1           # PowerShell script for deployment (Windows)
├── deploy-argocd.sh            # Bash script for deployment (Linux/macOS)
├── user-guide.md               # Guide for using ArgoCD after deployment
└── argocd-credentials.txt      # Generated after deployment with login details
```

## Quick Deployment

For the fastest and most reliable deployment, use the provided deployment scripts:

### Windows:
```powershell
.\deploy-argocd.ps1
```

### Linux/macOS:
```bash
chmod +x deploy-argocd.sh
./deploy-argocd.sh
```

These scripts will:
1. Verify cluster connectivity
2. Check for management nodes
3. Clean up any existing ArgoCD installation
4. Deploy ArgoCD using Terragrunt
5. Wait for all pods to be running
6. Retrieve and save the admin credentials

## Manual Deployment 

If you prefer to deploy manually:

1. Ensure that your EKS cluster and node groups are running
   ```bash
   aws eks describe-cluster --name eks-cluster --region us-east-1
   ```

2. Check for management nodes
   ```bash
   kubectl get nodes -l role=management
   ```

3. Clean up any existing deployment (if needed)
   ```bash
   kubectl delete namespace argocd --ignore-not-found
   ```

4. Deploy Argo CD using Terragrunt
   ```bash
   cd terragrunt/argocd
   terragrunt init --reconfigure
   terragrunt apply
   ```

5. Wait for the pods to start running
   ```bash
   kubectl get pods -n argocd
   ```

6. Retrieve the Argo CD admin password
   ```bash
   cd terragrunt/argocd
   terragrunt output -raw argocd_admin_password
   ```

7. Get the Argo CD server URL
   ```bash
   terragrunt output -raw argocd_server_url
   ```

## Accessing Argo CD

After deployment:

1. Open the ArgoCD server URL in your browser (from the output or `argocd-credentials.txt`)
2. Login with username `admin` and the password from the credentials file
3. For CLI access:
   ```bash
   argocd login <SERVER_URL> --username admin --password <ADMIN_PASSWORD> --insecure
   ```

## Configuration Details

### Node Placement

Argo CD is configured to run on the management node group with:
- **Node affinity**: Targets nodes with label `role=management`
- **Tolerations**: Includes tolerations for the taint `dedicated=management:NoSchedule`

### Role-Based Access Control

The default configuration includes:
- **admin**: Full access to all resources
- **readonly**: Read-only access for viewing applications
- **deployer**: Custom role for deployment operations

For detailed instructions on configuring RBAC and repositories, see the [User Guide](user-guide.md).

## Troubleshooting

If you encounter issues during deployment:

1. Check management node availability:
   ```bash
   kubectl get nodes -l role=management
   ```

2. Check pod status and logs:
   ```bash
   kubectl get pods -n argocd
   kubectl logs -n argocd <POD_NAME>
   ```

3. Check the LoadBalancer service:
   ```bash
   kubectl get svc -n argocd argocd-server-lb
   ```

4. If pods are in a Pending state, check node taints and capacity:
   ```bash
   kubectl describe nodes --selector=role=management
   ```

5. Use port-forwarding as a fallback for UI access:
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```

6. For Terragrunt issues, clean the cache and retry:
   ```bash
   rm -rf terragrunt/argocd/.terragrunt-cache
   cd terragrunt/argocd
   terragrunt init --reconfigure
   terragrunt apply
   ```

## Next Steps

After deploying Argo CD:
1. Change the default admin password
2. Set up Git repositories for your applications
3. Configure role-based access for your team
4. Deploy your first application

Refer to the [User Guide](user-guide.md) for detailed instructions on these tasks. 