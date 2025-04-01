#!/bin/bash
# Script to properly deploy ArgoCD to the EKS cluster

set -e
echo -e "\e[36mStarting ArgoCD deployment process...\e[0m"

# Verify EKS cluster is running and accessible
echo -e "\e[33mVerifying EKS cluster access...\e[0m"
if ! kubectl cluster-info; then
    echo -e "\e[31mError: Cannot connect to the EKS cluster. Please check your kubeconfig.\e[0m"
    echo -e "\e[33mRun: aws eks update-kubeconfig --region us-east-1 --name eks-cluster\e[0m"
    exit 1
fi
echo -e "\e[32mSuccessfully connected to the cluster\e[0m"

# Check for management nodes
echo -e "\e[33mChecking for management nodes...\e[0m"
MANAGEMENT_NODES=$(kubectl get nodes -l role=management --no-headers 2>/dev/null)

if [ -z "$MANAGEMENT_NODES" ]; then
    echo -e "\e[31mWarning: No nodes with label 'role=management' found.\e[0m"
    echo -e "\e[31mArgoCD is configured to run on management nodes.\e[0m"
    
    read -p "Do you want to proceed anyway? (y/n) " PROCEED
    if [ "$PROCEED" != "y" ]; then
        exit 1
    fi
fi

# Clean up any existing ArgoCD installation
echo -e "\e[33mCleaning up any existing ArgoCD installation...\e[0m"
ARGOCD_NAMESPACE=$(kubectl get namespace argocd --ignore-not-found --no-headers)

if [ -n "$ARGOCD_NAMESPACE" ]; then
    echo -e "\e[33mExisting ArgoCD namespace found. Cleaning up...\e[0m"
    
    # Check for Helm releases in the argocd namespace
    HELM_RELEASES=$(helm list -n argocd --short)
    
    if [ -n "$HELM_RELEASES" ]; then
        echo -e "\e[33mUninstalling Helm releases in argocd namespace...\e[0m"
        for RELEASE in $HELM_RELEASES; do
            echo -e "\e[33mUninstalling Helm release: $RELEASE\e[0m"
            helm uninstall $RELEASE -n argocd
        done
    fi
    
    # Delete any custom resources that might block namespace deletion
    echo -e "\e[33mDeleting ArgoCD custom resources...\e[0m"
    kubectl delete applications --all -n argocd --ignore-not-found
    kubectl delete appprojects --all -n argocd --ignore-not-found
    
    # Delete the namespace
    echo -e "\e[33mDeleting argocd namespace...\e[0m"
    kubectl delete namespace argocd --ignore-not-found
    
    # Wait for namespace to be fully deleted
    echo -e "\e[33mWaiting for namespace to be fully deleted...\e[0m"
    TIMEOUT_SECONDS=120
    ELAPSED=0
    INTERVAL_SECONDS=5
    
    while [ $ELAPSED -lt $TIMEOUT_SECONDS ]; do
        NAMESPACE_EXISTS=$(kubectl get namespace argocd --ignore-not-found --no-headers)
        if [ -z "$NAMESPACE_EXISTS" ]; then
            echo -e "\e[32mNamespace successfully deleted!\e[0m"
            break
        fi
        
        echo -e "\e[33mWaiting for namespace deletion... ($ELAPSED seconds elapsed)\e[0m"
        sleep $INTERVAL_SECONDS
        ELAPSED=$((ELAPSED+INTERVAL_SECONDS))
        
        # If it takes too long, try to force delete
        if [ $ELAPSED -eq 60 ]; then
            echo -e "\e[33mAttempting to force delete namespace...\e[0m"
            kubectl get namespace argocd -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f -
        fi
    done
    
    if [ $ELAPSED -ge $TIMEOUT_SECONDS ]; then
        echo -e "\e[31mWarning: Namespace deletion timed out. Proceeding anyway.\e[0m"
    fi
fi

# Clean Terragrunt cache
echo -e "\e[33mCleaning Terragrunt cache...\e[0m"
if [ -d "terragrunt/argocd/.terragrunt-cache" ]; then
    rm -rf terragrunt/argocd/.terragrunt-cache
fi

# Deploy ArgoCD using Terragrunt
echo -e "\e[32mDeploying ArgoCD using Terragrunt...\e[0m"
cd terragrunt/argocd

echo -e "\e[33mRunning terragrunt init...\e[0m"
terragrunt init --reconfigure

if [ $? -ne 0 ]; then
    echo -e "\e[31mError: Terragrunt init failed\e[0m"
    exit 1
fi

echo -e "\e[33mRunning terragrunt apply...\e[0m"
terragrunt apply -auto-approve

if [ $? -ne 0 ]; then
    echo -e "\e[31mError: Terragrunt apply failed\e[0m"
    exit 1
fi

# Wait for ArgoCD pods to be ready
echo -e "\e[33mWaiting for ArgoCD pods to be ready...\e[0m"
TIMEOUT_SECONDS=300
ELAPSED=0
INTERVAL_SECONDS=10
ALL_READY=false

while [ $ELAPSED -lt $TIMEOUT_SECONDS ]; do
    PODS=$(kubectl get pods -n argocd -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
    POD_COUNT=$(echo $PODS | wc -w)
    RUNNING_COUNT=$(echo $PODS | tr ' ' '\n' | grep -c "Running")
    
    if [ $POD_COUNT -gt 0 ] && [ $POD_COUNT -eq $RUNNING_COUNT ]; then
        ALL_READY=true
        break
    fi
    
    echo -e "\e[33mWaiting for pods to be ready... ($ELAPSED seconds elapsed)\e[0m"
    sleep $INTERVAL_SECONDS
    ELAPSED=$((ELAPSED+INTERVAL_SECONDS))
done

if [ "$ALL_READY" = true ]; then
    echo -e "\e[32mAll ArgoCD pods are running!\e[0m"
else
    echo -e "\e[31mWarning: Not all ArgoCD pods are running. Check status with:\e[0m"
    echo -e "\e[33mkubectl get pods -n argocd\e[0m"
fi

# Get the ArgoCD admin password
echo -e "\e[33mRetrieving ArgoCD admin password...\e[0m"
PASSWORD=$(terragrunt output -raw argocd_admin_password)

# Get the ArgoCD server URL
echo -e "\e[33mRetrieving ArgoCD server URL...\e[0m"
SERVER_URL=$(terragrunt output -raw argocd_server_url)

# Save credentials to a file
CREDENTIALS_PATH="../../argocd-credentials.txt"
cat > $CREDENTIALS_PATH << EOF
ArgoCD Server URL: $SERVER_URL
Username: admin
Password: $PASSWORD
EOF

# Secure the credentials file
chmod 600 $CREDENTIALS_PATH

# Return to original directory
cd ../..

echo -e "\n\e[32mArgoCD has been deployed successfully!\e[0m"
echo -e "\e[36mServer URL: $SERVER_URL\e[0m"
echo -e "\e[36mUsername: admin\e[0m"
echo -e "\e[36mPassword: $PASSWORD\e[0m"
echo -e "\n\e[33mCredentials have been saved to: $CREDENTIALS_PATH\e[0m"
echo -e "\n\e[33mTo login using the CLI:\e[0m"
echo -e "\e[33margocd login $SERVER_URL --username admin --password '$PASSWORD' --insecure\e[0m"
echo -e "\n\e[33mAfter logging in, change the default password using:\e[0m"
echo -e "\e[33margocd account update-password\e[0m" 