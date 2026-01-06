terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data sources
data "aws_vpc" "existing" {
  id = var.vpc_id
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  
  filter {
    name   = "subnet-id"
    values = var.subnet_ids
  }
}

data "aws_subnet" "public" {
  for_each = toset(var.subnet_ids)
  id       = each.value
}

# Tag subnets for EKS and Load Balancer discovery
resource "aws_ec2_tag" "subnet_cluster_tag" {
  for_each    = toset(var.subnet_ids)
  resource_id = each.value
  key         = "kubernetes.io/cluster/${var.cluster_name}"
  value       = "shared"
}

resource "aws_ec2_tag" "subnet_elb_tag" {
  for_each    = toset(var.subnet_ids)
  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

# EKS Cluster IAM Role
data "aws_iam_role" "cluster" {
  name = var.cluster_role_name
}

# Attach VPC Resource Controller policy (required for IPv6 and private link)
resource "aws_iam_role_policy_attachment" "cluster_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = data.aws_iam_role.cluster.name
}

# EKS Node Group IAM Role
data "aws_iam_role" "node_group" {
  name = var.node_group_role_name
}

# Additional EBS permissions for Node Group (for CSI driver)
resource "aws_iam_role_policy" "node_group_ebs" {
  name = "${var.cluster_name}-node-group-ebs-policy"
  role = data.aws_iam_role.node_group.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateVolume",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:DeleteVolume",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumeStatus",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstances",
          "ec2:CreateTags",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      }
    ]
  })
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = data.aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = ["0.0.0.0/0"]
  }

  kubernetes_network_config {
    ip_family = var.ip_family
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    data.aws_iam_role.cluster
  ]

  tags = {
    Name        = var.cluster_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# OIDC Provider for EKS
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name = "${var.cluster_name}-eks-irsa"
  }
}

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Get Ubuntu 24.04 EKS Optimized AMI from SSM Parameter Store
data "aws_ssm_parameter" "ubuntu_eks_ami" {
  name = "/aws/service/canonical/ubuntu/eks/24.04/${var.kubernetes_version}/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# Launch Template for Node Group with HugePages
resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${var.cluster_name}-node-"
  image_id    = data.aws_ssm_parameter.ubuntu_eks_ami.value

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    cluster_name        = var.cluster_name
    cluster_endpoint    = aws_eks_cluster.main.endpoint
    cluster_ca          = aws_eks_cluster.main.certificate_authority[0].data
  }))

  # Network interface with security groups (if provided)
  dynamic "network_interfaces" {
    for_each = length(var.security_group_ids) > 0 ? [1] : []
    content {
      associate_public_ip_address = true
      delete_on_termination       = true
      security_groups             = var.security_group_ids
    }
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 80
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.disable_imds_v1 ? "required" : "optional"  # optional = IMDSv1 + IMDSv2, required = IMDSv2 only
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name        = "${var.cluster_name}-node"
      Environment = var.environment
    }
  }
}

# EKS Node Group 1
resource "aws_eks_node_group" "ubuntu_n1" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "ubuntu-n1"
  node_role_arn   = data.aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids

  ami_type       = "CUSTOM"
  instance_types = ["m5.2xlarge"]

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = "$Latest"
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    "alpha.eksctl.io/cluster-name"    = var.cluster_name
    "alpha.eksctl.io/nodegroup-name"  = "ubuntu-n1"
    "node-type"                       = "worker"
  }

  tags = {
    Name        = "${var.cluster_name}-ubuntu-n1"
    Environment = var.environment
  }

  depends_on = [
    aws_eks_cluster.main
  ]
}

# EKS Node Group 2
resource "aws_eks_node_group" "ubuntu_n2" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "ubuntu-n2"
  node_role_arn   = data.aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids

  ami_type       = "CUSTOM"
  instance_types = [var.instance_type]

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = "$Latest"
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    "alpha.eksctl.io/cluster-name"    = var.cluster_name
    "alpha.eksctl.io/nodegroup-name"  = "ubuntu-n2"
    "node-type"                       = "worker"
  }

  tags = {
    Name        = "${var.cluster_name}-ubuntu-n2"
    Environment = var.environment
  }

  depends_on = [
    aws_eks_cluster.main
  ]
}

# EKS Addons
resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"

  # IPv6 is automatically configured when cluster ip_family is set to ipv6
  # No additional configuration needed

  depends_on = [
    aws_eks_node_group.ubuntu_n1,
    aws_eks_node_group.ubuntu_n2
  ]
}

resource "aws_eks_addon" "coredns" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.ubuntu_n1,
    aws_eks_node_group.ubuntu_n2
  ]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.ubuntu_n1,
    aws_eks_node_group.ubuntu_n2
  ]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn

  depends_on = [
    aws_eks_node_group.ubuntu_n1,
    aws_eks_node_group.ubuntu_n2,
    aws_iam_role.ebs_csi_driver
  ]
}

# EBS CSI Driver IAM Policy
resource "aws_iam_policy" "ebs_csi_driver" {
  name        = "${var.cluster_name}-ebs-csi-driver"
  description = "IAM policy for EBS CSI Driver"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateSnapshot",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:ModifyVolume",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstances",
          "ec2:DescribeSnapshots",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumesModifications"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = [
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:snapshot/*"
        ]
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = [
              "CreateVolume",
              "CreateSnapshot"
            ]
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteTags"
        ]
        Resource = [
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:snapshot/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateVolume"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/ebs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateVolume"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/CSIVolumeName" = "*"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteVolume"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/ebs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteVolume"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/CSIVolumeName" = "*"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteVolume"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/kubernetes.io/created-for/pvc/name" = "*"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteSnapshot"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/CSIVolumeSnapshotName" = "*"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DeleteSnapshot"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/ebs.csi.aws.com/cluster" = "true"
          }
        }
      }
    ]
  })
}

# IAM Role for EBS CSI Driver
resource "aws_iam_role" "ebs_csi_driver" {
  name = "${var.cluster_name}-ebs-csi-driver"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.cluster_name}-ebs-csi-driver"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  policy_arn = aws_iam_policy.ebs_csi_driver.arn
  role       = aws_iam_role.ebs_csi_driver.name
}
