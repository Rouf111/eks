# EKS Cluster Provisioner API

An API-driven system for provisioning and managing EKS clusters using Terraform and Kubernetes Jobs.

## Overview

This system provides a REST API that accepts EKS cluster configurations and triggers Kubernetes Jobs to provision clusters using Terraform. It supports:

- **Dry-run testing** with `terraform plan` only
- **Actual cluster provisioning** with `terraform apply`
- **Cluster destruction** with `terraform destroy`
- **State management** using Persistent Volume Claims (PVCs)
- **Log retrieval** for debugging and monitoring

## Architecture

```
┌──────────────┐
│   Client     │
└──────┬───────┘
       │ POST /clusters/test or /clusters/provision
       ▼
┌──────────────────────┐
│  FastAPI Server      │
│  (Kubernetes Pod)    │
└──────┬───────────────┘
       │ Creates K8s Job
       ▼
┌─────────────────────────────────┐
│  Terraform Worker Job           │
│  ┌───────────────────────────┐  │
│  │ - Generate tfvars         │  │
│  │ - Run terraform init      │  │
│  │ - Run terraform plan      │  │
│  │ - Run terraform apply     │  │
│  │   (if not dry-run)        │  │
│  └───────────────────────────┘  │
│                                 │
│  Volumes:                       │
│  - AWS Credentials (Secret)     │
│  - Terraform State (PVC)        │
│  - Terraform Logs (PVC)         │
└─────────────────────────────────┘
```

## Project Structure

```
eks-terraform/
├── api/
│   ├── main.py              # FastAPI application
│   ├── models.py            # Pydantic models
│   ├── k8s_client.py        # Kubernetes client
│   └── requirements.txt     # Python dependencies
├── scripts/
│   ├── provision.sh         # Terraform provisioning script
│   └── destroy.sh           # Terraform destroy script
├── k8s/
│   ├── namespace.yaml       # Namespace definition
│   ├── rbac.yaml            # ServiceAccount and RBAC
│   ├── api-deployment.yaml  # API deployment
│   ├── api-service.yaml     # API service (LoadBalancer)
│   ├── aws-secret.yaml      # AWS credentials secret
│   └── cleanup-cronjob.yaml # Cleanup CronJob
├── k8s-manifests/
│   └── ebs-storageclass.yaml
├── main.tf                  # Terraform EKS configuration
├── variables.tf             # Terraform variables
├── outputs.tf               # Terraform outputs
├── user-data.sh             # Node user data
├── Dockerfile.api           # FastAPI Docker image
├── Dockerfile.worker        # Terraform worker image
└── README.md               # This file
```

## Prerequisites

- Kubernetes cluster (EKS, GKE, or local like minikube)
- kubectl configured
- Docker for building images
- AWS credentials with EKS permissions
- Existing AWS resources:
  - VPC: `vpc-bd9c86d5`
  - Subnets: `subnet-310c7c7d`, `subnet-2fdfdc47`, `subnet-2208b359`
  - IAM Roles: `EKS_Cluster`, `node-group-k8s`

## Setup Instructions

### 1. Build Docker Images

```bash
# Build the Terraform worker image
docker build -f Dockerfile.worker -t eks-provisioner-worker:latest .

# Build the FastAPI server image
docker build -f Dockerfile.api -t eks-provisioner-api:latest .

# If using a registry, tag and push
docker tag eks-provisioner-worker:latest YOUR_REGISTRY/eks-provisioner-worker:latest
docker tag eks-provisioner-api:latest YOUR_REGISTRY/eks-provisioner-api:latest
docker push YOUR_REGISTRY/eks-provisioner-worker:latest
docker push YOUR_REGISTRY/eks-provisioner-api:latest
```

### 2. Configure AWS Credentials

Edit `k8s/aws-secret.yaml` and replace the placeholder values:

```yaml
stringData:
  AWS_ACCESS_KEY_ID: "YOUR_ACCESS_KEY_ID"
  AWS_SECRET_ACCESS_KEY: "YOUR_SECRET_ACCESS_KEY"
  AWS_DEFAULT_REGION: "ap-south-1"
```

Or create the secret directly:

```bash
kubectl create secret generic aws-creds \
  --from-literal=AWS_ACCESS_KEY_ID=YOUR_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=YOUR_SECRET_ACCESS_KEY \
  --from-literal=AWS_DEFAULT_REGION=ap-south-1 \
  -n eks-provisioner
```

### 3. Deploy to Kubernetes

```bash
# Create namespace
kubectl apply -f k8s/namespace.yaml

# Create AWS credentials secret (if using yaml)
kubectl apply -f k8s/aws-secret.yaml

# Create RBAC resources
kubectl apply -f k8s/rbac.yaml

# Deploy the API
kubectl apply -f k8s/api-deployment.yaml
kubectl apply -f k8s/api-service.yaml

# Optional: Deploy cleanup CronJob
kubectl apply -f k8s/cleanup-cronjob.yaml
```

### 4. Get API Endpoint

```bash
# Get the LoadBalancer endpoint
kubectl get svc eks-provisioner-api -n eks-provisioner

# Wait for EXTERNAL-IP to be assigned
# Access API at: http://<EXTERNAL-IP>/
```

## API Usage

### Base URL

```
http://<EXTERNAL-IP>/
```

### Endpoints

#### 1. Test Cluster Configuration (Dry-Run)

```bash
curl -X POST http://<EXTERNAL-IP>/clusters/test \
  -H "Content-Type: application/json" \
  -d '{
    "cluster_name": "test-cluster-001",
    "kubernetes_version": "1.33",
    "instance_type": "m5.xlarge",
    "ip_family": "ipv6"
  }'
```

Response:
```json
{
  "cluster_name": "test-cluster-001",
  "job_name": "test-test-cluster-001",
  "status": "pending",
  "message": "Dry-run job created. Check status endpoint for progress.",
  "created_at": "2026-01-06T10:30:00.000000"
}
```

#### 2. Provision Actual Cluster

```bash
curl -X POST http://<EXTERNAL-IP>/clusters/provision \
  -H "Content-Type: application/json" \
  -d '{
    "cluster_name": "prod-cluster-001",
    "kubernetes_version": "1.33",
    "instance_type": "m5.xlarge",
    "ip_family": "ipv6"
  }'
```

#### 3. Check Cluster Status

```bash
curl http://<EXTERNAL-IP>/clusters/test-cluster-001/status
```

Response:
```json
{
  "cluster_name": "test-cluster-001",
  "job_name": "test-test-cluster-001",
  "status": "completed",
  "phase": "Succeeded",
  "message": null,
  "cluster_id": "prod-cluster-001",
  "kubeconfig_command": "aws eks update-kubeconfig --region ap-south-1 --name prod-cluster-001"
}
```

#### 4. Get Cluster Logs

```bash
curl http://<EXTERNAL-IP>/clusters/test-cluster-001/logs
```

#### 5. Destroy Cluster

```bash
curl -X DELETE http://<EXTERNAL-IP>/clusters/prod-cluster-001
```

#### 6. Cleanup Resources

```bash
curl -X DELETE http://<EXTERNAL-IP>/clusters/test-cluster-001/cleanup
```

## Validation Rules

### cluster_name
- DNS-compliant: lowercase alphanumeric and hyphens
- Must start and end with alphanumeric
- Max 100 characters
- Pattern: `^[a-z0-9]([a-z0-9-]{0,98}[a-z0-9])?$`

### kubernetes_version
- Format: `1.XX`
- Supported: `1.31`, `1.32`, `1.33`

### instance_type
- EC2 instance type format
- Examples: `m5.xlarge`, `t3.medium`, `c5.2xlarge`
- Pattern: `^[a-z][0-9][a-z]?\.(nano|micro|small|medium|large|xlarge|[0-9]+xlarge)$`

### ip_family
- Allowed values: `ipv4` or `ipv6`

## Storage and State Management

### Persistent Volume Claims

Each cluster gets two PVCs:
- **tfstate-{cluster_name}**: 1Gi for Terraform state files
- **tflogs-{cluster_name}**: 500Mi for logs

### TTL and Cleanup

- **Test jobs**: Auto-deleted after 24 hours (successful only)
- **Provision jobs**: No TTL, manual cleanup required
- **Failed jobs**: Preserved indefinitely for debugging
- **CronJob**: Runs every 6 hours to clean up old test PVCs

## Monitoring and Debugging

### Check API Health

```bash
curl http://<EXTERNAL-IP>/health
```

### View API Logs

```bash
kubectl logs -f deployment/eks-provisioner-api -n eks-provisioner
```

### View Job Logs

```bash
# List jobs
kubectl get jobs -n eks-provisioner

# View job logs
kubectl logs job/test-test-cluster-001 -n eks-provisioner
```

### View PVCs

```bash
kubectl get pvc -n eks-provisioner
```

### Debug Failed Jobs

```bash
# Get job details
kubectl describe job/provision-prod-cluster-001 -n eks-provisioner

# Get pod details
kubectl get pods -n eks-provisioner -l cluster=prod-cluster-001

# View pod logs
kubectl logs <pod-name> -n eks-provisioner

# Access logs via API
curl http://<EXTERNAL-IP>/clusters/prod-cluster-001/logs
```

## Terraform Configuration

The system uses these Terraform files:
- **main.tf**: EKS cluster, node groups, addons, IAM
- **variables.tf**: Variable declarations
- **outputs.tf**: Cluster ID, region, kubeconfig command
- **user-data.sh**: Node initialization script

### Default Configuration

Hardcoded values (not configurable via API):
- **Region**: `ap-south-1`
- **VPC**: `vpc-bd9c86d5`
- **Subnets**: 3 specific subnets
- **IAM Roles**: `EKS_Cluster`, `node-group-k8s`
- **Environment**: `production`
- **Addon versions**: vpc-cni, coredns, kube-proxy, ebs-csi-driver
- **IMDS**: v1 and v2 enabled

### Configurable via API

- **cluster_name**: Cluster identifier
- **kubernetes_version**: K8s version
- **instance_type**: Node instance type (for node group 2)
- **ip_family**: IPv4 or IPv6

## Security Considerations

### Current Setup (MVP)
- AWS credentials stored in Kubernetes Secret
- No API authentication
- LoadBalancer exposes API publicly

### Recommendations for Production
1. **Migrate to HashiCorp Vault** for secrets
2. **Add API authentication** (JWT, OAuth2)
3. **Use IRSA** (IAM Roles for Service Accounts)
4. **Add Ingress** with TLS termination
5. **Implement rate limiting**
6. **Add audit logging**
7. **Network policies** for pod security

## Troubleshooting

### Job Stuck in Pending
```bash
kubectl describe job/<job-name> -n eks-provisioner
# Check PVC status
kubectl get pvc -n eks-provisioner
```

### Terraform Errors
```bash
# View logs
curl http://<EXTERNAL-IP>/clusters/<cluster-name>/logs
# Or directly from pod
kubectl logs job/<job-name> -n eks-provisioner
```

### AWS Credentials Issues
```bash
# Verify secret exists
kubectl get secret aws-creds -n eks-provisioner
# Check secret content
kubectl get secret aws-creds -n eks-provisioner -o yaml
```

### Image Pull Errors
```bash
# If using private registry, create imagePullSecret
kubectl create secret docker-registry regcred \
  --docker-server=<your-registry> \
  --docker-username=<username> \
  --docker-password=<password> \
  -n eks-provisioner

# Update deployments to use imagePullSecrets
```

## Limitations (MVP)

1. **No concurrent cluster limit** - Can create unlimited jobs
2. **Shared VPC/IAM roles** - All clusters use same infrastructure
3. **No remote state backend** - State in PVCs only
4. **No authentication** - API is open
5. **Manual cleanup** - Failed provisions require manual intervention
6. **No cluster updates** - Only create and destroy

## Future Enhancements

- [ ] Remote state backend (S3 + DynamoDB)
- [ ] HashiCorp Vault integration
- [ ] API authentication and authorization
- [ ] Concurrent cluster limits
- [ ] Cluster update operations
- [ ] Multi-region support
- [ ] Dynamic VPC creation
- [ ] Webhook notifications
- [ ] Prometheus metrics
- [ ] Grafana dashboards

## License

Internal use only.

## Support

For issues or questions, contact the infrastructure team.
