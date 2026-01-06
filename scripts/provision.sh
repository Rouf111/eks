#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to log messages
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

# Validate required environment variables
REQUIRED_VARS=("CLUSTER_NAME" "KUBERNETES_VERSION" "INSTANCE_TYPE" "IP_FAMILY")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        error "Required environment variable $var is not set"
        exit 1
    fi
done

# Set defaults
DRY_RUN=${DRY_RUN:-true}
AWS_REGION=${AWS_REGION:-ap-south-1}
ENVIRONMENT=${ENVIRONMENT:-production}

log "Starting EKS cluster provisioning..."
log "Cluster Name: $CLUSTER_NAME"
log "Kubernetes Version: $KUBERNETES_VERSION"
log "Instance Type: $INSTANCE_TYPE"
log "IP Family: $IP_FAMILY"
log "Dry Run Mode: $DRY_RUN"

# Create terraform.tfvars from environment variables
log "Generating terraform.tfvars..."
cat > terraform.tfvars <<EOF
# AWS region
aws_region = "$AWS_REGION"

# EKS Cluster configuration
cluster_name       = "$CLUSTER_NAME"
kubernetes_version = "$KUBERNETES_VERSION"
environment        = "$ENVIRONMENT"

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
instance_type = "$INSTANCE_TYPE"

# EKS Addons versions
vpc_cni_version    = "v1.19.1-eksbuild.2"
coredns_version    = "v1.11.4-eksbuild.2"
kube_proxy_version = "v1.33.0-eksbuild.3"
ebs_csi_version    = "v1.37.0-eksbuild.1"

# IP Family
ip_family = "$IP_FAMILY"

# IMDS Configuration
disable_imds_v1 = false
EOF

log "terraform.tfvars generated successfully"

# Initialize Terraform
log "Initializing Terraform..."
terraform init 2>&1 | tee /terraform-logs/init.log

# Validate Terraform configuration
log "Validating Terraform configuration..."
terraform validate 2>&1 | tee /terraform-logs/validate.log

# Run Terraform Plan
log "Running Terraform plan..."
terraform plan -out=tfplan 2>&1 | tee /terraform-logs/plan.txt

# Save plan in JSON format for easier parsing
log "Saving plan in JSON format..."
terraform show -json tfplan > /terraform-logs/plan.json 2>&1 || warn "Could not save plan as JSON"

# Conditional Apply
if [ "$DRY_RUN" = "false" ]; then
    log "Dry run is disabled. Applying Terraform changes..."
    terraform apply -auto-approve tfplan 2>&1 | tee /terraform-logs/apply.txt
    
    # Extract outputs
    log "Extracting Terraform outputs..."
    terraform output -json > /terraform-logs/outputs.json 2>&1 || warn "Could not extract outputs"
    
    # Extract key values
    CLUSTER_ID=$(terraform output -raw cluster_id 2>/dev/null || echo "")
    REGION=$(terraform output -raw region 2>/dev/null || echo "$AWS_REGION")
    
    if [ -n "$CLUSTER_ID" ]; then
        log "Cluster created successfully: $CLUSTER_ID"
        
        # Update kubeconfig
        log "Updating kubeconfig..."
        aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_ID" 2>&1 | tee /terraform-logs/kubeconfig.log
        
        # Apply EBS StorageClass
        log "Applying EBS StorageClass..."
        kubectl apply -f k8s-manifests/ebs-storageclass.yaml 2>&1 | tee /terraform-logs/storageclass.log || warn "Could not apply StorageClass"
        
        # Save cluster info
        cat > /terraform-logs/cluster-info.json <<EOFINFO
{
  "cluster_name": "$CLUSTER_NAME",
  "cluster_id": "$CLUSTER_ID",
  "region": "$REGION",
  "kubeconfig_command": "aws eks update-kubeconfig --region $REGION --name $CLUSTER_ID"
}
EOFINFO
        log "Cluster information saved to cluster-info.json"
    else
        error "Failed to extract cluster ID from outputs"
    fi
    
    # Copy state files to persistent storage
    log "Copying state files to persistent storage..."
    mkdir -p "/terraform-state/$CLUSTER_NAME"
    cp -r .terraform terraform.tfstate* tfplan "/terraform-state/$CLUSTER_NAME/" 2>&1 | tee -a /terraform-logs/apply.txt || warn "Could not copy all state files"
    
    log "EKS cluster provisioning completed successfully!"
else
    log "Dry run mode enabled. Skipping terraform apply."
    log "Plan has been saved. Review /terraform-logs/plan.txt for details."
    
    # Save dry run info
    cat > /terraform-logs/cluster-info.json <<EOFINFO
{
  "cluster_name": "$CLUSTER_NAME",
  "dry_run": true,
  "status": "plan_completed"
}
EOFINFO
fi

log "Script completed successfully"
exit 0
