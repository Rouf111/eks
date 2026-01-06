# EKS Provisioner - Deployment Guide

## Overview

You have successfully created an API-driven EKS provisioning system. Here's how to deploy it.

## Architecture Summary

```
Your Setup:
1. Build 2 Docker images (API + Worker)
2. Push to container registry
3. Deploy to Kubernetes cluster
4. Create AWS credentials secret
5. Test the system
```

## Prerequisites

- Docker or Podman installed (for building images)
- Access to a container registry (Docker Hub, ECR, GCR, or private registry)
- A running Kubernetes cluster (EKS recommended)
- kubectl configured to access your cluster
- AWS credentials with EKS permissions

---

## Step-by-Step Deployment

### PHASE 1: Prepare Container Images

#### Option A: Build on Local Machine (Recommended for testing)

```bash
# 1. Login to your container registry
docker login
# OR for AWS ECR:
# aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin YOUR_ECR_URL

# 2. Set your registry URL
REGISTRY="your-dockerhub-username"  # e.g., "rouf" or "123456789.dkr.ecr.ap-south-1.amazonaws.com"

# 3. Build images
docker build -f Dockerfile.worker -t $REGISTRY/eks-provisioner-worker:latest .
docker build -f Dockerfile.api -t $REGISTRY/eks-provisioner-api:latest .

# 4. Push images
docker push $REGISTRY/eks-provisioner-worker:latest
docker push $REGISTRY/eks-provisioner-api:latest
```

#### Option B: Build on Remote Machine

If your local machine can't build images, push code to Git and build remotely:

```bash
# On local machine:
# 1. Create a Git repository (GitHub/GitLab/BitBucket)
git init
git add .
git commit -m "Initial commit: EKS provisioner API"
git remote add origin https://github.com/YOUR_USERNAME/eks-provisioner.git
git push -u origin main

# 2. On remote machine (with Docker):
git clone https://github.com/YOUR_USERNAME/eks-provisioner.git
cd eks-provisioner

# 3. Build and push (same as Option A)
REGISTRY="your-dockerhub-username"
docker build -f Dockerfile.worker -t $REGISTRY/eks-provisioner-worker:latest .
docker build -f Dockerfile.api -t $REGISTRY/eks-provisioner-api:latest .
docker push $REGISTRY/eks-provisioner-worker:latest
docker push $REGISTRY/eks-provisioner-api:latest
```

---

### PHASE 2: Update Kubernetes Manifests

#### 1. Update Image References

Edit `k8s/api-deployment.yaml`:

```yaml
# Change this line (around line 18):
image: eks-provisioner-api:latest

# To:
image: YOUR_REGISTRY/eks-provisioner-api:latest
# Example: rouf/eks-provisioner-api:latest
```

**Also update the WORKER_IMAGE environment variable** (around line 24):

```yaml
env:
  - name: WORKER_IMAGE
    value: "YOUR_REGISTRY/eks-provisioner-worker:latest"
```

#### 2. Verify Storage Class

For EKS, the default storage class is usually `gp2` or `gp3`. Verify:

```bash
kubectl get storageclass
```

If different, update in `k8s/api-deployment.yaml`:

```yaml
env:
  - name: STORAGE_CLASS
    value: "gp3"  # or whatever your cluster uses
```

---

### PHASE 3: Deploy to Kubernetes

#### 1. Create AWS Credentials Secret

```bash
# The secret name is hardcoded as "aws-creds" in the system
kubectl create secret generic aws-creds \
  --from-literal=AWS_ACCESS_KEY_ID="YOUR_ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="YOUR_SECRET_KEY" \
  --from-literal=AWS_DEFAULT_REGION="ap-south-1" \
  -n eks-provisioner
```

**Important:** The secret name `aws-creds` is hardcoded in:
- `k8s_client.py` (lines referencing secret)
- Job templates

Don't change this name unless you update the code.

#### 2. Deploy All Resources

```bash
# Create namespace
kubectl apply -f k8s/namespace.yaml

# Create RBAC
kubectl apply -f k8s/rbac.yaml

# Deploy API
kubectl apply -f k8s/api-deployment.yaml
kubectl apply -f k8s/api-service.yaml

# Optional: Deploy cleanup CronJob
kubectl apply -f k8s/cleanup-cronjob.yaml
```

#### 3. Verify Deployment

```bash
# Check if pods are running
kubectl get pods -n eks-provisioner

# Check API logs
kubectl logs -f deployment/eks-provisioner-api -n eks-provisioner

# Get service endpoint
kubectl get svc eks-provisioner-api -n eks-provisioner
```

---

### PHASE 4: Access and Test

#### Get API Endpoint

**For LoadBalancer (EKS):**
```bash
# Wait for external IP/hostname
kubectl get svc eks-provisioner-api -n eks-provisioner -w

# Once available, note the EXTERNAL-IP
API_URL="http://EXTERNAL_IP"
```

**For port-forward (testing):**
```bash
kubectl port-forward svc/eks-provisioner-api 8000:80 -n eks-provisioner
API_URL="http://localhost:8000"
```

#### Test the API

```bash
# 1. Health check
curl $API_URL/health

# 2. Create test cluster (dry-run)
curl -X POST $API_URL/clusters/test \
  -H "Content-Type: application/json" \
  -d '{
    "cluster_name": "test-cluster-001",
    "kubernetes_version": "1.33",
    "instance_type": "m5.xlarge",
    "ip_family": "ipv6"
  }'

# 3. Check status (wait a few seconds first)
curl $API_URL/clusters/test-cluster-001/status

# 4. View logs
curl $API_URL/clusters/test-cluster-001/logs

# 5. View Swagger docs in browser
# Open: $API_URL/docs
```

---

## Recommended Approach for You

Based on your situation, here's what I recommend:

### Scenario 1: You Have Docker Locally

```bash
# 1. Build and push images from your Mac
REGISTRY="your-dockerhub-username"
docker build -f Dockerfile.worker -t $REGISTRY/eks-provisioner-worker:latest .
docker build -f Dockerfile.api -t $REGISTRY/eks-provisioner-api:latest .
docker push $REGISTRY/eks-provisioner-worker:latest
docker push $REGISTRY/eks-provisioner-api:latest

# 2. Update k8s/api-deployment.yaml with your registry
# 3. Deploy to your EKS cluster (PHASE 3 above)
```

### Scenario 2: You Need to Build on Remote Machine

```bash
# 1. Push to Git
git init
git add .
git commit -m "EKS provisioner API"
git remote add origin YOUR_REPO_URL
git push -u origin main

# 2. On machine with Docker (EC2, build server, etc.):
git clone YOUR_REPO_URL
cd eks-provisioner
docker build -f Dockerfile.worker -t $REGISTRY/eks-provisioner-worker:latest .
docker build -f Dockerfile.api -t $REGISTRY/eks-provisioner-api:latest .
docker push $REGISTRY/eks-provisioner-worker:latest
docker push $REGISTRY/eks-provisioner-api:latest

# 3. Back on your Mac or any machine with kubectl:
# Update k8s/api-deployment.yaml
# Deploy (PHASE 3)
```

---

## Quick Checklist

- [ ] Choose container registry (Docker Hub, ECR, etc.)
- [ ] Build both Docker images
- [ ] Push images to registry
- [ ] Update `k8s/api-deployment.yaml` with image URLs
- [ ] Create `aws-creds` secret in Kubernetes
- [ ] Deploy namespace and RBAC
- [ ] Deploy API deployment and service
- [ ] Get API endpoint (LoadBalancer IP or port-forward)
- [ ] Test with dry-run cluster creation
- [ ] Monitor job execution
- [ ] Test actual cluster provisioning

---

## Troubleshooting

### Images not pulling
```bash
# Check if images are accessible
docker pull YOUR_REGISTRY/eks-provisioner-worker:latest

# For private registry, create imagePullSecret
kubectl create secret docker-registry regcred \
  --docker-server=YOUR_REGISTRY \
  --docker-username=YOUR_USERNAME \
  --docker-password=YOUR_PASSWORD \
  -n eks-provisioner

# Add to deployment:
# spec.template.spec.imagePullSecrets:
#   - name: regcred
```

### Pods not starting
```bash
kubectl describe pod -n eks-provisioner -l app=eks-provisioner-api
kubectl logs -n eks-provisioner -l app=eks-provisioner-api
```

### Jobs failing
```bash
kubectl get jobs -n eks-provisioner
kubectl logs job/test-CLUSTER_NAME -n eks-provisioner
```

---

## What's Next?

After successful deployment:

1. **Test with actual provisioning**:
   - Use `/clusters/provision` endpoint (not `/clusters/test`)
   - This creates real AWS resources
   - Takes 15-20 minutes

2. **Production hardening**:
   - Add authentication to API
   - Migrate to HashiCorp Vault for secrets
   - Set up monitoring and alerting
   - Add rate limiting
   - Configure Ingress with TLS

3. **Operational tasks**:
   - Document your workflows
   - Set up backup for PVCs
   - Create runbooks for common issues
   - Train team on using the API

---

## Need Help?

If you run into issues:
1. Check pod logs: `kubectl logs -n eks-provisioner POD_NAME`
2. Check job logs: `kubectl logs job/JOB_NAME -n eks-provisioner`
3. Verify secrets exist: `kubectl get secret aws-creds -n eks-provisioner`
4. Check API logs via `/clusters/{name}/logs` endpoint
