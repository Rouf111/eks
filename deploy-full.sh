#!/bin/bash

# Automated deployment script for EKS Provisioner

set -e

echo "=== EKS Provisioner Deployment Assistant ==="
echo ""

# 1. Get registry information
read -p "Enter your container registry (e.g., dockerhub-username or ECR URL): " REGISTRY

if [ -z "$REGISTRY" ]; then
    echo "Registry is required!"
    exit 1
fi

echo ""
echo "Will use registry: $REGISTRY"
echo ""

# 2. Build images
read -p "Build Docker images? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Building images..."
    docker build -f Dockerfile.worker -t $REGISTRY/eks-provisioner-worker:latest .
    docker build -f Dockerfile.api -t $REGISTRY/eks-provisioner-api:latest .
    echo "✓ Images built"
    echo ""
    
    # 3. Push images
    read -p "Push images to registry? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Pushing images..."
        docker push $REGISTRY/eks-provisioner-worker:latest
        docker push $REGISTRY/eks-provisioner-api:latest
        echo "✓ Images pushed"
        echo ""
    fi
fi

# 4. Update deployment manifest
echo "Updating k8s/api-deployment.yaml with registry..."
sed -i.bak "s|image: eks-provisioner-api:latest|image: $REGISTRY/eks-provisioner-api:latest|g" k8s/api-deployment.yaml
sed -i.bak "s|value: \"eks-provisioner-worker:latest\"|value: \"$REGISTRY/eks-provisioner-worker:latest\"|g" k8s/api-deployment.yaml
rm k8s/api-deployment.yaml.bak 2>/dev/null || true
echo "✓ Deployment manifest updated"
echo ""

# 5. Get AWS credentials
read -p "Create AWS credentials secret? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "AWS Access Key ID: " AWS_ACCESS_KEY_ID
    read -p "AWS Secret Access Key: " -s AWS_SECRET_ACCESS_KEY
    echo
    read -p "AWS Region [ap-south-1]: " AWS_REGION
    AWS_REGION=${AWS_REGION:-ap-south-1}
    
    # Create secret command
    echo ""
    echo "Creating secret..."
    kubectl create secret generic aws-creds \
      --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
      --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
      --from-literal=AWS_DEFAULT_REGION="$AWS_REGION" \
      -n eks-provisioner \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "✓ Secret created"
    echo ""
fi

# 6. Deploy to Kubernetes
read -p "Deploy to Kubernetes? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deploying to Kubernetes..."
    
    kubectl apply -f k8s/namespace.yaml
    kubectl apply -f k8s/rbac.yaml
    kubectl apply -f k8s/api-deployment.yaml
    kubectl apply -f k8s/api-service.yaml
    
    echo "✓ Deployed"
    echo ""
    
    # Wait for deployment
    echo "Waiting for deployment to be ready..."
    kubectl wait --for=condition=available --timeout=120s deployment/eks-provisioner-api -n eks-provisioner || true
    echo ""
fi

# 7. Show access information
echo "=== Deployment Complete ==="
echo ""
echo "Check status:"
echo "  kubectl get all -n eks-provisioner"
echo ""
echo "Get API endpoint:"
echo "  kubectl get svc eks-provisioner-api -n eks-provisioner"
echo ""
echo "Or use port-forward for testing:"
echo "  kubectl port-forward svc/eks-provisioner-api 8000:80 -n eks-provisioner"
echo ""
echo "View logs:"
echo "  kubectl logs -f deployment/eks-provisioner-api -n eks-provisioner"
echo ""
echo "Test API:"
echo '  curl http://EXTERNAL_IP/health'
echo '  # or http://localhost:8000/health if using port-forward'
echo ""
