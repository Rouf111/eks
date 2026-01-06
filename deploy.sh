#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== EKS Cluster Deployment Script ===${NC}"

# Check required tools
echo -e "${YELLOW}Checking required tools...${NC}"
for cmd in terraform aws kubectl; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}Error: $cmd is not installed${NC}"
        exit 1
    fi
done
echo -e "${GREEN}All required tools are installed${NC}"

# Initialize Terraform
echo -e "${YELLOW}Initializing Terraform...${NC}"
terraform init

# Validate Terraform configuration
echo -e "${YELLOW}Validating Terraform configuration...${NC}"
terraform validate

# Plan Terraform changes
echo -e "${YELLOW}Planning Terraform changes...${NC}"
terraform plan -out=tfplan

# Ask for confirmation
read -p "Do you want to apply these changes? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo -e "${RED}Deployment cancelled${NC}"
    exit 1
fi

# Apply Terraform
echo -e "${YELLOW}Applying Terraform configuration...${NC}"
terraform apply tfplan

# Get cluster name and region
CLUSTER_NAME=$(terraform output -raw cluster_id)
AWS_REGION=$(terraform output -raw aws_region || echo "ap-south-1")

# Update kubeconfig
echo -e "${YELLOW}Updating kubeconfig...${NC}"
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# Wait for cluster to be ready
echo -e "${YELLOW}Waiting for cluster to be ready...${NC}"
sleep 30

# Verify cluster access
echo -e "${YELLOW}Verifying cluster access...${NC}"
kubectl get nodes

# Deploy EBS StorageClasses
echo -e "${YELLOW}Deploying EBS StorageClasses...${NC}"
kubectl apply -f k8s-manifests/ebs-storageclass.yaml

# Verify EBS CSI Driver
echo -e "${YELLOW}Verifying EBS CSI Driver...${NC}"
kubectl get deployment -n kube-system ebs-csi-controller
kubectl get storageclass

echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo -e "${GREEN}Cluster Name: $CLUSTER_NAME${NC}"
echo -e "${GREEN}Region: $AWS_REGION${NC}"
echo ""
echo -e "${YELLOW}To deploy the example load balancer service, run:${NC}"
echo -e "kubectl apply -f k8s-manifests/example-loadbalancer-service.yaml"
echo ""
echo -e "${YELLOW}To get the load balancer URL, run:${NC}"
echo -e "kubectl get svc example-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo -e "${GREEN}Cluster Name: $CLUSTER_NAME${NC}"
echo -e "${GREEN}Region: $AWS_REGION${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "- Deploy AWS Load Balancer Controller separately if needed"
echo -e "- Create LoadBalancer type services to provision ALB/NLB"