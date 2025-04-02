#!/bin/bash
# Script to properly deploy ArgoCD to the EKS cluster with HTTPS support

# Deployment script for ArgoCD to EKS cluster with proper cleanup and validation
#
# Performs:
# - Complete cleanup of previous installations
# - Terraform-based deployment using Terragrunt
# - Health checks for ArgoCD components
# - Load balancer configuration
# - Credential generation and security
#
# Prerequisites:
# - Terraform & Terragrunt installed
# - AWS CLI authenticated
# - kubectl configured for EKS
# - Bash 4+
#
# Usage:
# ./deploy-argocd.sh

set -e
echo -e "\033[0;36mStarting ArgoCD deployment process with HTTPS support...\033[0m"

# Verify EKS cluster is running and accessible
echo -e "\033[1;33mVerifying EKS cluster access...\033[0m"
if ! kubectl cluster-info &> /dev/null; then
  echo -e "\033[0;31mError: Cannot connect to the EKS cluster. Please check your kubeconfig.\033[0m"
  echo -e "\033[1;33mRun: aws eks update-kubeconfig --region us-east-1 --name eks-cluster\033[0m"
  exit 1
fi
echo -e "\033[0;32mSuccessfully connected to the cluster\033[0m"

# Check for management nodes
echo -e "\033[1;33mChecking for management nodes...\033[0m"
if ! kubectl get nodes -l role=management --no-headers 2>/dev/null | grep -q .; then
  echo -e "\033[0;31mWarning: No nodes with label 'role=management' found.\033[0m"
  echo -e "\033[0;31mArgoCD is configured to run on management nodes.\033[0m"
  
  read -p "Do you want to proceed anyway? (y/n): " proceed
  if [ "$proceed" != "y" ]; then
    exit 1
  fi
fi

# Clean up any existing ArgoCD installation
echo -e "\033[1;33mCleaning up any existing ArgoCD installation...\033[0m"
if kubectl get namespace argocd --ignore-not-found --no-headers 2>/dev/null | grep -q .; then
  echo -e "\033[1;33mExisting ArgoCD namespace found. Cleaning up...\033[0m"
  
  # Clean up previous deployments and replicasets
  echo -e "\033[1;33mCleaning up previous deployments and replicasets...\033[0m"
  kubectl delete deployment argocd-server -n argocd --ignore-not-found
  kubectl delete replicaset -n argocd -l app.kubernetes.io/name=argocd-server --ignore-not-found
  kubectl delete pods -n argocd -l app.kubernetes.io/name=argocd-server --force --grace-period=0

  # Ensure all argocd-server resources are removed
  echo -e "\033[1;33mEnsuring all argocd-server resources are removed...\033[0m"
  kubectl delete replicaset -n argocd -l app.kubernetes.io/name=argocd-server --ignore-not-found
  kubectl delete pods -n argocd -l app.kubernetes.io/name=argocd-server --force --grace-period=0
  sleep 5  # Give Kubernetes time to process deletions
  
  # Check for Helm releases in the argocd namespace
  helm_releases=$(helm list -n argocd --short 2>/dev/null)
  
  if [ -n "$helm_releases" ]; then
    echo -e "\033[1;33mUninstalling Helm releases in argocd namespace...\033[0m"
    for release in $helm_releases; do
      echo -e "\033[1;33mUninstalling Helm release: $release\033[0m"
      helm uninstall "$release" -n argocd --no-hooks
    done

    # Force delete CRDs that were preserved by Helm's resource policy
    echo -e "\033[1;33mCleaning up ArgoCD CRDs...\033[0m"
    kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io --ignore-not-found --force --grace-period=0 --cascade=background
  fi
  
  # Delete any custom resources that might block namespace deletion
  echo -e "\033[1;33mDeleting ArgoCD custom resources...\033[0m"
  kubectl delete applications --all -n argocd --ignore-not-found
  kubectl delete appprojects --all -n argocd --ignore-not-found
  
  # Delete the namespace
  echo -e "\033[1;33mDeleting argocd namespace...\033[0m"
  kubectl delete namespace argocd --ignore-not-found
  
  # Wait for namespace to be fully deleted
  echo -e "\033[1;33mWaiting for namespace to be fully deleted...\033[0m"
  timeout_seconds=120
  elapsed=0
  interval_seconds=5
  
  while [ $elapsed -lt $timeout_seconds ]; do
    if ! kubectl get namespace argocd --ignore-not-found --no-headers 2>/dev/null | grep -q .; then
      echo -e "\033[0;32mNamespace successfully deleted!\033[0m"
      break
    fi
    
    echo -e "\033[1;33mWaiting for namespace deletion... ($elapsed seconds elapsed)\033[0m"
    sleep $interval_seconds
    elapsed=$((elapsed + interval_seconds))
    
    # If it takes too long, try to force delete
    if [ $elapsed -eq 60 ]; then
      echo -e "\033[1;33mAttempting to force delete namespace...\033[0m"
      kubectl get namespace argocd -o json | \
        jq '.spec.finalizers = []' | \
        kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f -
    fi
  done
  
  if [ $elapsed -ge $timeout_seconds ]; then
    echo -e "\033[0;31mWarning: Namespace deletion timed out. Proceeding anyway.\033[0m"
  fi
fi

# Clean Terragrunt cache
echo -e "\033[1;33mCleaning Terragrunt cache...\033[0m"
if [ -d "terragrunt/argocd/.terragrunt-cache" ]; then
  rm -rf "terragrunt/argocd/.terragrunt-cache"
fi

# Deploy ArgoCD using Terragrunt
echo -e "\033[0;32mDeploying ArgoCD using Terragrunt...\033[0m"
cd "terragrunt/argocd"

echo -e "\033[1;33mRunning terragrunt init...\033[0m"
if ! terragrunt init --reconfigure -lock=false; then
  echo -e "\033[0;31mError: Terragrunt init failed\033[0m"
  exit 1
fi

echo -e "\033[1;33mRunning terragrunt apply...\033[0m"
if ! terragrunt apply -auto-approve -lock=false; then
  echo -e "\033[0;31mError: Terragrunt apply failed\033[0m"
  exit 1
fi

# Wait for LB to stabilize
echo -e "\033[1;33mWaiting for LoadBalancer to initialize (2-3 minutes)...\033[0m"
sleep 120

# Wait for ArgoCD pods to be ready
echo -e "\033[1;33mWaiting for ArgoCD pods to be ready...\033[0m"
timeout_seconds=300
elapsed=0
interval_seconds=10
all_ready=false

while [ $elapsed -lt $timeout_seconds ]; do
  pods=$(kubectl get pods -n argocd -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
  pod_count=$(echo "$pods" | wc -w)
  running_count=$(echo "$pods" | tr ' ' '\n' | grep -c "Running")
  
  if [ $pod_count -gt 0 ] && [ $pod_count -eq $running_count ]; then
    all_ready=true
    break
  fi
  
  echo -e "\033[1;33mWaiting for pods to be ready... ($elapsed seconds elapsed)\033[0m"
  sleep $interval_seconds
  elapsed=$((elapsed + interval_seconds))
done

if [ "$all_ready" = true ]; then
  echo -e "\033[0;32mAll ArgoCD pods are running!\033[0m"
else
  echo -e "\033[0;31mWarning: Not all ArgoCD pods are running. Check status with:\033[0m"
  echo -e "\033[1;33mkubectl get pods -n argocd\033[0m"
fi

# Get the new ELB domain after recreation with increased timeout
echo -e "\033[1;33m  Waiting for LoadBalancer domain (this may take a few minutes)...\033[0m"
retry_count=0
max_retries=24  # 2 minutes (24 * 5 seconds)
ELB_DOMAIN=""

while [ $retry_count -lt $max_retries ] && [ -z "$ELB_DOMAIN" ]; do
  retry_count=$((retry_count + 1))
  sleep 5
  ELB_DOMAIN=$(kubectl get svc argocd-server-lb -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$ELB_DOMAIN" ]; then
    echo -e "\033[0;32m  ✓ New LoadBalancer domain: $ELB_DOMAIN\033[0m"
    break
  fi
  echo -e "\033[1;33m  Waiting for LoadBalancer domain... ($(($retry_count * 5)) seconds elapsed)\033[0m"
done

if [ -z "$ELB_DOMAIN" ]; then
  echo -e "\033[0;31m  Warning: Could not get new LoadBalancer domain\033[0m"
fi

# Wait for the ArgoCD server pod to restart
echo -e "\033[1;33mWaiting for ArgoCD server pod to restart...\033[0m"
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=120s

# Wait a bit for AWS LoadBalancer to stabilize
echo -e "\033[1;33mWaiting for AWS LoadBalancer to stabilize (this may take a few minutes)...\033[0m"
echo -e "\033[1;33m  The AWS ELB typically takes 3-5 minutes to fully update its configuration.\033[0m"
sleep 30

# Get the ArgoCD admin password
echo -e "\033[1;33mRetrieving ArgoCD admin password...\033[0m"
password=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 --decode)

# Make sure we have a valid ELB domain
if [ -z "$ELB_DOMAIN" ]; then
  # Try one more time to get the ELB domain
  echo -e "\033[1;33mAttempting to get the LoadBalancer domain one more time...\033[0m"
  ELB_DOMAIN=$(kubectl get svc argocd-server-lb -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  
  if [ -z "$ELB_DOMAIN" ]; then
    echo -e "\033[0;31mWarning: Could not get LoadBalancer domain. Using placeholder for now.\033[0m"
    ELB_DOMAIN="<LoadBalancer-Domain-Not-Available>"
    echo -e "\033[1;33mYou can get the ELB domain later with: kubectl get svc argocd-server-lb -n argocd\033[0m"
  else
    echo -e "\033[0;32mSuccessfully retrieved LoadBalancer domain: $ELB_DOMAIN\033[0m"
  fi
fi

# Save credentials to a file
credentials_path="../../argocd-credentials.txt"
cat > "$credentials_path" << EOF
ArgoCD Server URL: https://$ELB_DOMAIN
Username: admin
Password: $password
EOF

# Return to original directory
cd "../.."

echo -e "\n\033[0;32mArgoCD has been deployed successfully with HTTPS!\033[0m"
echo -e "\033[0;36mServer URL: https://$ELB_DOMAIN\033[0m"
echo -e "\033[0;36mUsername: admin\033[0m"
echo -e "\033[0;36mPassword: $password\033[0m"
echo -e "\n\033[1;33mCredentials have been saved to: $credentials_path\033[0m"
echo -e "\n\033[1;33mTo login using the CLI:\033[0m"
echo -e "\033[1;33margocd login https://$ELB_DOMAIN --username admin --password '$password' --insecure\033[0m"
echo -e "\n\033[1;33mAfter logging in, change the default password using:\033[0m"
echo -e "\033[1;33margocd account update-password\033[0m"
echo -e "\n\033[1;33mNote: Your browser will show a security warning due to the self-signed certificate.\033[0m"
echo -e "\033[1;33mYou can safely proceed through this warning for testing purposes.\033[0m"