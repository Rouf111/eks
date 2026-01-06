# IPv6 Support for EKS Cluster

This EKS Terraform configuration now supports both IPv4 and IPv6 clusters.

## Usage

### To create an IPv4 cluster (default):

In `terraform.tfvars`, set:
```hcl
ip_family = "ipv4"
```

### To create an IPv6 cluster:

In `terraform.tfvars`, set:
```hcl
ip_family = "ipv6"
```

### Additional Configuration Options:

**IMDS Configuration** (Instance Metadata Service):
```hcl
# Allow both IMDSv1 and IMDSv2 (default, matches eksctl behavior)
disable_imds_v1 = false

# Enforce IMDSv2 only (more secure)
disable_imds_v1 = true
```

**Additional Security Groups** (optional):
```hcl
security_group_ids = ["sg-d51a00b0", "sg-04f1f2ee67c5e6140"]
```

## Prerequisites for IPv6 Clusters

Before creating an IPv6 cluster, ensure:

1. **VPC has IPv6 CIDR block assigned**: Your VPC must have an IPv6 CIDR block associated with it.
   ```bash
   aws ec2 associate-vpc-cidr-block --vpc-id vpc-bd9c86d5 --ipv6-cidr-block <amazon-provided-cidr>
   ```

2. **Subnets have IPv6 CIDR blocks**: All subnets used by the cluster must have IPv6 CIDR blocks.
   ```bash
   aws ec2 associate-subnet-cidr-block --subnet-id <subnet-id> --ipv6-cidr-block <ipv6-cidr>
   ```

3. **Route tables updated**: Ensure route tables have routes for IPv6 traffic (`::/0` for egress).

4. **Security groups**: Update security groups to allow IPv6 traffic if needed.

## What Changes for IPv6

When `ip_family = "ipv6"`:

1. **Cluster Network**: The EKS cluster is configured with `ip_family = "ipv6"` in its `kubernetes_network_config`.

2. **VPC CNI**: The VPC CNI addon is automatically configured with `ENABLE_IPv6 = "true"`.

3. **VPC Resource Controller**: The AmazonEKSVPCResourceController policy is attached to the cluster role (required for IPv6 and AWS Load Balancer Controller).

4. **Pod IPs**: Pods will receive IPv6 addresses from the subnet's IPv6 CIDR block.

5. **Services**: Kubernetes services will use IPv6 addresses.

6. **Node Networking**: Nodes are configured with public networking enabled (privateNetworking: false) to support LoadBalancer services.

## Deployment Steps

1. Update `terraform.tfvars` with desired `ip_family`:
   ```bash
   ip_family = "ipv6"
   ```

2. Run Terraform:
   ```bash
   terraform plan
   terraform apply
   ```

3. Verify the cluster:
   ```bash
   aws eks update-kubeconfig --region ap-south-1 --name eks-ipv4-cluster
   kubectl get nodes -o wide
   ```

## Important Notes

- **Cannot change IP family after creation**: You cannot change the IP family of an existing cluster. You must destroy and recreate the cluster.

- **IPv6 only**: When you choose IPv6, the cluster operates in IPv6-only mode. It does not support dual-stack (IPv4 + IPv6) simultaneously.

- **AWS Service Compatibility**: Ensure all AWS services you use (Load Balancers, etc.) support IPv6.

- **Application Compatibility**: Your applications must support IPv6 connectivity.

## Troubleshooting

### Cluster creation fails with IPv6
- Verify VPC has IPv6 CIDR block: `aws ec2 describe-vpcs --vpc-ids vpc-bd9c86d5`
- Verify subnets have IPv6 CIDR blocks: `aws ec2 describe-subnets --subnet-ids <subnet-id>`
- Check route tables have IPv6 routes

### Pods not getting IPv6 addresses
- Check VPC CNI addon logs: `kubectl logs -n kube-system -l app=aws-node`
- Verify VPC CNI configuration: `kubectl get configmap -n kube-system aws-node -o yaml`
