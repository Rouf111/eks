# EKS Cluster with IPv4 and Public Load Balancer

This Terraform project creates an EKS cluster with:
- ✅ **IPv4 networking** (not IPv6)
- ✅ **Public Load Balancer** using Internet Gateway
- ✅ **AWS Load Balancer Controller** for managing load balancers
- ✅ **2 Node Groups** with m5.2xlarge instances
- ✅ **EKS Addons**: VPC CNI, CoreDNS, Kube-proxy

## Key Differences from eksctl YAML

| Feature | eksctl Config | Terraform Config |
|---------|---------------|------------------|
| IP Family | IPv6 | **IPv4** ✅ |
| Load Balancer | Manual | **AWS LB Controller** ✅ |
| Service Type | NodePort/ClusterIP | **LoadBalancer (public IP via IGW)** ✅ |
| Node IPs | Private | Private (LB uses public IPs) ✅ |

## Architecture

```
Internet
    |
    v
Internet Gateway (IGW)
    |
    v
Public Subnets (subnet-310c7c7d, subnet-2fdfdc47, subnet-2208b359)
    |
    v
AWS Load Balancer (Public IP)
    |
    v
EKS Worker Nodes (Private IPs)
    |
    v
Pods (Private IPs)
```

## Prerequisites

1. **AWS CLI** configured with credentials
2. **Terraform** >= 1.0
3. **kubectl** installed
4. **IAM Roles** already exist:
   - `EKS_Cluster` - for EKS control plane
   - `node-group-k8s` - for worker nodes

## File Structure

```
eks-terraform/
├── main.tf                           # Main Terraform configuration
├── variables.tf                      # Variable definitions
├── outputs.tf                        # Output definitions
├── terraform.tfvars                  # Variable values
├── deploy.sh                         # Deployment script
├── destroy.sh                        # Cleanup script
├── k8s-manifests/
│   ├── aws-load-balancer-controller.yaml  # LB Controller deployment
│   └── example-loadbalancer-service.yaml  # Example service with LB
└── README.md                         # This file
```

## Quick Start

### 1. Review Configuration

Edit `terraform.tfvars` to match your requirements:

```hcl
aws_region         = "ap-south-1"
cluster_name       = "eks-ipv4-cluster"
kubernetes_version = "1.34"
vpc_id             = "vpc-bd9c86d5"
subnet_ids         = ["subnet-310c7c7d", "subnet-2fdfdc47", "subnet-2208b359"]
instance_type      = "m5.2xlarge"
```

### 2. Deploy the Cluster

```bash
chmod +x deploy.sh
./deploy.sh
```

This script will:
1. Initialize Terraform
2. Validate configuration
3. Show plan and ask for confirmation
4. Create EKS cluster
5. Update kubeconfig
6. Deploy AWS Load Balancer Controller
7. Verify deployment

### 3. Deploy Example Application with Load Balancer

```bash
# Deploy example app with LoadBalancer service
kubectl apply -f k8s-manifests/example-loadbalancer-service.yaml

# Wait for load balancer to be provisioned (takes 2-3 minutes)
kubectl get svc example-service -w

# Get the public URL
kubectl get svc example-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

### 4. Test the Load Balancer

```bash
# Get the load balancer DNS name
LB_URL=$(kubectl get svc example-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test the endpoint
curl http://$LB_URL
```

## Manual Deployment Steps

If you prefer manual deployment:

### Initialize and Plan

```bash
terraform init
terraform plan -out=tfplan
```

### Apply Configuration

```bash
terraform apply tfplan
```

### Configure kubectl

```bash
aws eks update-kubeconfig --region ap-south-1 --name eks-ipv4-cluster
```

### Deploy AWS Load Balancer Controller

```bash
# Get the IAM role ARN
export ROLE_ARN=$(terraform output -raw aws_load_balancer_controller_role_arn)
export CLUSTER_NAME=$(terraform output -raw cluster_id)

# Deploy the controller
envsubst < k8s-manifests/aws-load-balancer-controller.yaml | kubectl apply -f -

# Verify deployment
kubectl get deployment -n kube-system aws-load-balancer-controller
```

## Creating a LoadBalancer Service

Any Kubernetes Service with `type: LoadBalancer` will automatically create an AWS Network Load Balancer:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-ip-address-type: "ipv4"
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
```

### Load Balancer Annotations Explained

| Annotation | Value | Purpose |
|------------|-------|---------|
| `aws-load-balancer-type` | `external` | Use AWS Load Balancer Controller |
| `aws-load-balancer-nlb-target-type` | `ip` | Target pod IPs directly |
| `aws-load-balancer-scheme` | `internet-facing` | **Public LB via IGW** ✅ |
| `aws-load-balancer-ip-address-type` | `ipv4` | **Force IPv4** ✅ |

## Verify Cluster and Networking

```bash
# Check nodes
kubectl get nodes -o wide

# Check VPC CNI configuration
kubectl get daemonset -n kube-system aws-node

# Verify IPv4 addressing
kubectl get pods -o wide --all-namespaces

# Check Load Balancer Controller
kubectl get deployment -n kube-system aws-load-balancer-controller

# List all services
kubectl get svc --all-namespaces
```

## Troubleshooting

### Load Balancer not created

```bash
# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check service events
kubectl describe svc <service-name>
```

### Nodes not joining cluster

```bash
# Check node group status
aws eks describe-nodegroup --cluster-name eks-ipv4-cluster --nodegroup-name ubuntu-n1

# Check CloudWatch logs
aws logs tail /aws/eks/eks-ipv4-cluster/cluster --follow
```

### IPv4 vs IPv6 Verification

```bash
# Verify cluster is using IPv4
kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'

# Should show IPv4 addresses like: 10.x.x.x
```

## Cleanup

### Using Script

```bash
chmod +x destroy.sh
./destroy.sh
```

### Manual Cleanup

```bash
# Delete example service first (to remove load balancers)
kubectl delete -f k8s-manifests/example-loadbalancer-service.yaml

# Wait for load balancers to be deleted
sleep 30

# Delete Load Balancer Controller
kubectl delete -f k8s-manifests/aws-load-balancer-controller.yaml

# Destroy Terraform resources
terraform destroy -auto-approve
```

## Cost Estimation

Approximate monthly costs (us-east-1):
- EKS Control Plane: $73/month
- 2x m5.2xlarge nodes (on-demand): ~$550/month
- Network Load Balancer: ~$16.20/month + data transfer
- **Total: ~$640/month** (before data transfer and storage costs)

## Important Notes

1. **Public Load Balancer**: The load balancer gets a **public IP** via IGW, but nodes remain private ✅
2. **IPv4 Only**: Cluster uses IPv4 addressing (not IPv6 as in your original eksctl config) ✅
3. **IAM Roles**: Make sure `EKS_Cluster` and `node-group-k8s` IAM roles exist
4. **Subnets**: Ensure subnets are **public** (have route to IGW) for load balancer to work
5. **Security Groups**: EKS automatically manages security groups for load balancer traffic

## Next Steps

1. ✅ Deploy your applications
2. ✅ Configure autoscaling
3. ✅ Set up monitoring (CloudWatch, Prometheus)
4. ✅ Configure logging (FluentBit, CloudWatch Logs)
5. ✅ Add storage classes (EBS, EFS)
6. ✅ Set up ingress controllers (ALB Ingress Controller)

## Support

For issues or questions:
- Check AWS EKS documentation: https://docs.aws.amazon.com/eks/
- AWS Load Balancer Controller: https://kubernetes-sigs.github.io/aws-load-balancer-controller/
- Terraform AWS Provider: https://registry.terraform.io/providers/hashicorp/aws/latest/docs
