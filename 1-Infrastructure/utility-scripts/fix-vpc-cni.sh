#!/bin/bash
# Script to fix AWS VPC CNI issues

set -e
echo -e "\e[36mFixing VPC CNI issues...\e[0m"

# Set variables
CLUSTER_NAME="eks-cluster"
REGION="us-east-1"
VPC_CNI_ROLE_NAME="${CLUSTER_NAME}-vpc-cni-role"

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account ID: $ACCOUNT_ID"

# Get OIDC provider URL from the cluster
echo "Getting OIDC provider URL from EKS cluster..."
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
echo "OIDC Provider: $OIDC_PROVIDER"

# Associate the OIDC provider with your cluster if not already done
echo "Ensuring OIDC provider is properly configured..."
aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.identity.oidc.issuer" --output text

echo "Creating IAM OIDC provider for EKS..."
if ! aws iam list-open-id-connect-providers | grep -q $(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///"); then
    eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $REGION --approve
fi

# Create trust policy for the VPC CNI role
echo "Creating trust policy for VPC CNI role..."
cat > vpc-cni-trust-policy.json << EOF
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
EOF

# Create or update the IAM role for VPC CNI
if aws iam get-role --role-name $VPC_CNI_ROLE_NAME 2>/dev/null; then
    echo "IAM role $VPC_CNI_ROLE_NAME already exists, updating..."
    aws iam update-assume-role-policy --role-name $VPC_CNI_ROLE_NAME --policy-document file://vpc-cni-trust-policy.json
else
    echo "Creating IAM role for VPC CNI..."
    aws iam create-role --role-name $VPC_CNI_ROLE_NAME --assume-role-policy-document file://vpc-cni-trust-policy.json
fi

# Attach the required policy
echo "Attaching AmazonEKS_CNI_Policy to role..."
aws iam attach-role-policy --role-name $VPC_CNI_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

# Create the configuration values for better tolerations
echo "Creating CNI configuration with improved tolerations..."
cat > vpc-cni-config.json << EOF
{
  "env": {
    "WARM_ENI_TARGET": "1",
    "WARM_IP_TARGET": "5",
    "AWS_VPC_K8S_CNI_LOGLEVEL": "DEBUG"
  },
  "resources": {
    "limits": {
      "cpu": "100m",
      "memory": "128Mi"
    },
    "requests": {
      "cpu": "100m",
      "memory": "128Mi"
    }
  },
  "tolerations": [
    {
      "key": "dedicated",
      "value": "monitoring",
      "effect": "NoSchedule"
    },
    {
      "key": "dedicated",
      "value": "management",
      "effect": "NoSchedule"
    },
    {
      "key": "dedicated",
      "value": "services",
      "effect": "NoSchedule"
    },
    {
      "key": "dedicated",
      "value": "data",
      "effect": "NoSchedule"
    },
    {
      "operator": "Exists"
    }
  ]
}
EOF

# Update VPC CNI addon with the IAM role
echo "Updating VPC CNI addon with the IAM role..."
aws eks update-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name vpc-cni \
  --service-account-role-arn arn:aws:iam::${ACCOUNT_ID}:role/${VPC_CNI_ROLE_NAME} \
  --configuration-values "$(cat vpc-cni-config.json)" \
  --resolve-conflicts OVERWRITE \
  --region $REGION

# Wait for addon update to complete
echo "Waiting for VPC CNI addon update to complete..."
sleep 30

# Restart AWS node pods to pick up the new service account token
echo "Restarting aws-node pods..."
kubectl delete pods -n kube-system -l k8s-app=aws-node

# Wait for pods to restart
echo "Waiting for aws-node pods to restart..."
sleep 30

# Verify the status
echo "Checking VPC CNI addon status..."
aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name vpc-cni --region $REGION

# Check aws-node pods
echo "Checking aws-node pod status..."
kubectl get pods -n kube-system -l k8s-app=aws-node

echo -e "\e[32mVPC CNI fix completed!\e[0m"
echo "Your AWS VPC CNI should now have the proper permissions to function correctly."
echo "The ArgoCD deployment should now work properly as well." 