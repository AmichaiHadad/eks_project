#!/bin/bash
# Checks EKS cluster node status and readiness for ArgoCD deployments
#
# Verifies:
# - Node availability and labels
# - Management node presence
# - Taints and tolerations
# - Pod scheduling issues
# - Resource capacity
#
# Prerequisites:
# - AWS CLI configured with proper credentials
# - kubectl configured for EKS cluster
# - Bash 4.2+
#
# Usage:
# ./check-eks-nodes.sh

# Color definitions
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${CYAN}Checking EKS node availability and labels...${NC}"

# Get all nodes
echo -e "\n${YELLOW}Listing all nodes:${NC}"
kubectl get nodes

# Check for nodes with the management role/tier
echo -e "\n${YELLOW}Checking for management nodes:${NC}"
kubectl get nodes -l role=management

# Check node details including taints
echo -e "\n${YELLOW}Checking node details and taints:${NC}"
kubectl get nodes -o json | jq -r '.items[] | "\n\033[0;32mNode: \(.metadata.name)\033[0m\nLabels:\n\(.metadata.labels | to_entries | map("  \(.key): \(.value)") | join("\n"))\n\nTaints:\n\(if .spec.taints then .spec.taints | map("  \(.key): \(.value):\(.effect)") | join("\n") else "  No taints" end)"'

# Check failing pods
echo -e "\n${YELLOW}Checking failing pods in argocd namespace:${NC}"
kubectl get pods -n argocd

# Check pod scheduling issues
echo -e "\n${YELLOW}Checking pod scheduling issues:${NC}"
kubectl get events -n argocd | grep -E 'fail|error|unable|cannot|taint'

# Check specific pod details for the ones failing
echo -e "\n${YELLOW}Checking details of failing applicationset-controller pod:${NC}"
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller

echo -e "\n${YELLOW}Checking details of failing dex-server pod:${NC}"
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-dex-server

echo -e "\n${YELLOW}Checking node capacity:${NC}"
kubectl describe nodes | grep -A 5 -E 'Capacity|Allocatable'