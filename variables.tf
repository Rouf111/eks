variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "eks-ipv6-cluster"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
  default     = "vpc-bd9c86d5"
}

variable "subnet_ids" {
  description = "List of subnet IDs (public subnets for load balancer)"
  type        = list(string)
  default     = [
    "subnet-310c7c7d",
    "subnet-2fdfdc47",
    "subnet-2208b359"
  ]
}

variable "security_group_ids" {
  description = "Additional security group IDs to attach to node groups"
  type        = list(string)
  default     = []
}

variable "cluster_role_name" {
  description = "IAM role name for EKS cluster"
  type        = string
  default     = "EKS_Cluster"
}

variable "node_group_role_name" {
  description = "IAM role name for EKS node group"
  type        = string
  default     = "node-group-k8s"
}

variable "instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "m5.xlarge"
}

variable "vpc_cni_version" {
  description = "VPC CNI addon version"
  type        = string
  default     = "v1.19.1-eksbuild.2"
}

variable "coredns_version" {
  description = "CoreDNS addon version"
  type        = string
  default     = "v1.11.4-eksbuild.2"
}

variable "kube_proxy_version" {
  description = "Kube-proxy addon version"
  type        = string
  default     = "v1.33.0-eksbuild.3"
}

variable "ebs_csi_version" {
  description = "EBS CSI driver addon version"
  type        = string
  default     = "v1.37.0-eksbuild.1"
}

variable "ip_family" {
  description = "IP family for the cluster (ipv4 or ipv6)"
  type        = string
  default     = "ipv6"
  validation {
    condition     = contains(["ipv4", "ipv6"], var.ip_family)
    error_message = "IP family must be either 'ipv4' or 'ipv6'."
  }
}

variable "disable_imds_v1" {
  description = "Disable IMDSv1 and enforce IMDSv2 only (set to false to allow both v1 and v2)"
  type        = bool
  default     = false
}
