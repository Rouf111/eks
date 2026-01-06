#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== EKS Cluster Destruction Script ===${NC}"

# Ask for confirmation
read -p "Are you sure you want to destroy the EKS cluster? This cannot be undone. (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo -e "${RED}Destruction cancelled${NC}"
    exit 1
fi

# Get cluster details
CLUSTER_NAME=$(terraform output -raw cluster_id 2>/dev/null || echo "")
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "ap-south-1")

if [ ! -z "$CLUSTER_NAME" ]; then
    echo -e "${YELLOW}Cleaning up Kubernetes resources...${NC}"
    # Delete any LoadBalancer type services if they exist
    kubectl get svc --all-namespaces -o json | \
        jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' | \
        while read namespace name; do
            echo "Deleting LoadBalancer service: $name in namespace: $namespace"
            kubectl delete svc $name -n $namespace --ignore-not-found=true || true
        done
    
    # Wait for load balancers to be deleted
    echo -e "${YELLOW}Waiting for AWS resources to be cleaned up...${NC}"
    sleep 30
fi

# Destroy Terraform resources
echo -e "${YELLOW}Destroying Terraform resources...${NC}"
terraform destroy -auto-approve

echo -e "${GREEN}=== Cluster Destroyed ===${NC}"
