# ArgoCD User Guide

This guide provides instructions for using the deployed ArgoCD instance, including setting up Git repositories, configuring role-based access control (RBAC), and deploying applications.

## Initial Login and Password Change

1. Retrieve the ArgoCD credentials:
   ```bash
   # For Linux/Unix
   cat argocd-credentials.txt
   
   # For Windows
   type argocd-credentials.txt
   ```

2. Access the ArgoCD UI:
   - Open the Server URL in your browser
   - Login with the provided admin username and password
   - Ignore the SSL certificate warning if using the default self-signed certificate

3. Change the admin password:
   ```bash
   argocd login <SERVER_URL> --username admin --password <INITIAL_PASSWORD> --insecure
   argocd account update-password
   ```

## Setting Up Git Repositories

### Adding a Git Repository

1. **Via the UI**:
   - Navigate to Settings > Repositories > Connect Repo
   - Select your repository type (Git, Helm, etc.)
   - Enter the repository URL
   - For private repositories, add credentials (username/password or SSH key)
   - Click "Connect"

2. **Via the CLI**:
   ```bash
   # For HTTPS repositories with username/password
   argocd repo add https://github.com/your-org/your-repo --username <USERNAME> --password <PASSWORD>
   
   # For SSH repositories
   argocd repo add git@github.com:your-org/your-repo.git --ssh-private-key-path ~/.ssh/id_rsa
   ```

### Configuring Repository Access

For more secure setup, create Kubernetes secrets for repository access:

```bash
# Create a secret for Git credentials
kubectl -n argocd create secret generic repo-secret \
  --from-literal=username=git-username \
  --from-literal=password=git-password

# Then reference in ArgoCD
argocd repo add https://github.com/your-org/your-repo \
  --username-secret-name repo-secret \
  --username-secret-key username \
  --password-secret-name repo-secret \
  --password-secret-key password
```

## Configuring Role-Based Access

ArgoCD supports RBAC for fine-grained access control. The following roles are pre-configured:

- `role:admin` - Full access to all resources
- `role:readonly` - Read-only access to all resources
- `role:deployer` - Custom role for deployment operations

### Adding Users and Roles

1. **Create a ConfigMap with RBAC policy** (for advanced customization):

   ```bash
   kubectl -n argocd edit configmap argocd-rbac-cm
   ```

   Add or modify the policy section:
   ```yaml
   data:
     policy.csv: |
       # Grant admin rights to a specific user
       g, user@example.com, role:admin
       
       # Grant read-only access to a group
       g, my-github-org:developers, role:readonly
       
       # Create a custom policy for a specific project
       p, role:project-admin, applications, *, project-name/*, allow
       g, project-admin@example.com, role:project-admin
   ```

2. **Via the ArgoCD CLI**:
   ```bash
   # Add a user to the admin role
   argocd account update-role user@example.com --role admin
   
   # Create a custom role
   argocd admin settings rbac create-role developer \
     --description "Developer role"
   
   # Add permissions to the role
   argocd admin settings rbac add-policy \
     -p "p, role:developer, applications, get, */*, allow"
   ```

### SSO Integration (Optional)

ArgoCD can integrate with various SSO providers (OIDC, SAML, etc.):

1. Edit the ArgoCD ConfigMap:
   ```bash
   kubectl -n argocd edit configmap argocd-cm
   ```

2. Add your SSO configuration (example for GitHub):
   ```yaml
   data:
     dex.config: |
       connectors:
         - type: github
           id: github
           name: GitHub
           config:
             clientID: <your-github-client-id>
             clientSecret: <your-github-client-secret>
             orgs:
             - name: your-github-org
   ```

## Creating Applications

### Via the UI

1. Click the "New App" button
2. Fill in:
   - Application Name
   - Project Name (default is "default")
   - Sync Policy (Manual or Automated)
   - Repository URL
   - Path in the repository
   - Destination cluster URL and namespace
3. Click "Create"

### Via the CLI

```bash
argocd app create my-app \
  --repo https://github.com/your-org/your-repo.git \
  --path path/to/manifests \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default
```

### Using App of Apps Pattern

For managing multiple applications, use the App of Apps pattern:

1. Create a Git repository with an umbrella application:
   ```yaml
   # apps/applications.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: app-of-apps
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/your-org/your-repo.git
       targetRevision: HEAD
       path: apps
     destination:
       server: https://kubernetes.default.svc
       namespace: argocd
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   ```

2. Create individual application definitions in the same repository:
   ```yaml
   # apps/app1.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: app1
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/your-org/app1.git
       targetRevision: HEAD
       path: manifests
     destination:
       server: https://kubernetes.default.svc
       namespace: app1
   ```

## Best Practices

1. **Project Structure**:
   - Create separate ArgoCD projects for different teams or application domains
   - Use namespaces to isolate applications

2. **Security**:
   - Regularly rotate credentials
   - Use RBAC to restrict access based on roles
   - Consider using private Git repositories

3. **Sync Strategies**:
   - For critical applications, use manual sync initially
   - For automated deployments, use `selfHeal: true` and `prune: true`
   - Configure health checks for your applications

4. **Resource Constraints**:
   - Add resource requests/limits to all applications
   - Monitor ArgoCD's own resource usage

5. **Backup**:
   - Regularly backup ArgoCD configuration:
     ```bash
     kubectl -n argocd get configmap,secret -o yaml > argocd-backup.yaml
     ```

## Troubleshooting

### Sync Issues

If applications aren't syncing properly:

1. Check the application status:
   ```bash
   argocd app get <APP_NAME>
   ```

2. View sync logs:
   ```bash
   argocd app logs <APP_NAME>
   ```

3. Verify Git repository access:
   ```bash
   argocd repo list
   ```

### Pod Failures

If ArgoCD pods are failing:

1. Check pod status:
   ```bash
   kubectl -n argocd get pods
   ```

2. View pod logs:
   ```bash
   kubectl -n argocd logs <POD_NAME>
   ```

### UI Access Issues

If you can't access the ArgoCD UI:

1. Check the LoadBalancer service:
   ```bash
   kubectl -n argocd get svc argocd-server-lb
   ```

2. Use port-forwarding as a fallback:
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```

## Additional Resources

- [ArgoCD Official Documentation](https://argo-cd.readthedocs.io/)
- [ArgoCD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)
- [ArgoCD CLI Reference](https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd/) 