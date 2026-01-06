#!/bin/bash

# Quick deployment script for EKS Provisioner API

set -e

echo "=== EKS Provisioner API Deployment ==="
echo ""

# Check prerequisites
echo "Checking prerequisites..."
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker is required but not installed. Aborting." >&2; exit 1; }

echo "✓ Prerequisites met"
echo ""

# Build Docker images
echo "Building Docker images..."
read -p "Do you want to build Docker images? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Building Terraform worker image..."
    docker build -f Dockerfile.worker -t eks-provisioner-worker:latest .
    
    echo "Building FastAPI server image..."
    docker build -f Dockerfile.api -t eks-provisioner-api:latest .
    
    echo "✓ Docker images built successfully"
else
    echo "Skipping Docker build"
fi
echo ""

# Configure AWS credentials
echo "Configuring AWS credentials..."
read -p "Enter AWS Access Key ID: " AWS_ACCESS_KEY_ID
read -p "Enter AWS Secret Access Key: " -s AWS_SECRET_ACCESS_KEY
echo
read -p "Enter AWS Region [ap-south-1]: " AWS_REGION
AWS_REGION=${AWS_REGION:-ap-south-1}

# Deploy to Kubernetes
echo ""
echo "Deploying to Kubernetes..."

# Create namespace
echo "Creating namespace..."
kubectl apply -f k8s/namespace.yaml

# Create AWS credentials secret
echo "Creating AWS credentials secret..."
kubectl create secret generic aws-creds \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_DEFAULT_REGION="$AWS_REGION" \
  -n eks-provisioner \
  --dry-run=client -o yaml | kubectl apply -f -

# Create RBAC
echo "Creating RBAC resources..."
kubectl apply -f k8s/rbac.yaml

# Deploy API
echo "Deploying API server..."
kubectl apply -f k8s/api-deployment.yaml
kubectl apply -f k8s/api-service.yaml

# Optional: Deploy CronJob
read -p "Deploy cleanup CronJob? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    kubectl apply -f k8s/cleanup-cronjob.yaml
    echo "✓ CronJob deployed"
fi

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Waiting for API service to get external IP..."
echo "This may take a few minutes..."
echo ""

# Wait for LoadBalancer IP
for i in {1..30}; do
    EXTERNAL_IP=$(kubectl get svc eks-provisioner-api -n eks-provisioner -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ -z "$EXTERNAL_IP" ]; then
        EXTERNAL_IP=$(kubectl get svc eks-provisioner-api -n eks-provisioner -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    fi
    
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    
    echo "Waiting... ($i/30)"
    sleep 10
done

if [ -n "$EXTERNAL_IP" ]; then
    echo ""
    echo "✓ API is ready!"
    echo ""
    echo "API Endpoint: http://$EXTERNAL_IP"
    echo ""
    echo "Test the API:"
    echo "  curl http://$EXTERNAL_IP/health"
    echo ""
    echo "View API docs:"
    echo "  Open http://$EXTERNAL_IP/docs in your browser"
    echo ""
else
    echo ""
    echo "⚠ Could not get external IP automatically"
    echo ""
    echo "Check service status:"
    echo "  kubectl get svc eks-provisioner-api -n eks-provisioner"
    echo ""
fi

echo "View API logs:"
echo "  kubectl logs -f deployment/eks-provisioner-api -n eks-provisioner"
echo ""
echo "View all resources:"
echo "  kubectl get all -n eks-provisioner"
echo ""
