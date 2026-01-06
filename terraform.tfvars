# AWS region
aws_region = "ap-south-1"

# EKS Cluster configuration
cluster_name       = "eks-ipv6-cluster"
kubernetes_version = "1.33"
environment        = "production"

# VPC configuration
vpc_id = "vpc-bd9c86d5"
subnet_ids = [
  "subnet-310c7c7d",  # ap-south-1b
  "subnet-2fdfdc47",  # ap-south-1a
  "subnet-2208b359"   # ap-south-1c
]

# IAM roles (must exist in your AWS account)
cluster_role_name    = "EKS_Cluster"
node_group_role_name = "node-group-k8s"

# Node configuration
instance_type = "m5.xlarge"

# EKS Addons versions (update as needed)
vpc_cni_version    = "v1.19.1-eksbuild.2"
coredns_version    = "v1.11.4-eksbuild.2"
kube_proxy_version = "v1.33.0-eksbuild.3"
ebs_csi_version    = "v1.37.0-eksbuild.1"

# IP Family (ipv4 or ipv6) - default is ipv6, change to ipv4 if needed
ip_family = "ipv6"

# IMDS Configuration (false = allow both IMDSv1 and IMDSv2, true = enforce IMDSv2 only)
disable_imds_v1 = false

# Additional security groups for node groups (optional)
# security_group_ids = ["sg-d51a00b0", "sg-04f1f2ee67c5e6140"]
