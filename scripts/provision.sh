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

error_exit() {
    error "$1"
    exit 1
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
 with proper error handling
log "Running Terraform plan..."
set +e  # Temporarily disable exit on error to capture exit code
terraform plan -out=tfplan -detailed-exitcode 2>&1 | tee /terraform-logs/plan.txt
PLAN_EXIT_CODE=${PIPESTATUS[0]}
set -e  # Re-enable exit on error

# Handle plan exit codes:
# 0 = No changes needed
# 1 = Error
# 2 = Changes present
if [ $PLAN_EXIT_CODE -eq 0 ]; then
    log "Plan succeeded: No changes needed"
elif [ $PLAN_EXIT_CODE -eq 2 ]; then
    log "Plan succeeded: Changes detected and ready to apply"
elif [ $PLAN_EXIT_CODE -eq 1 ]; then
    
    # Apply with error handling
    if ! terraform apply -auto-approve tfplan 2>&1 | tee /terraform-logs/apply.txt; then
        error_exit "Terraform apply failed. Check /terraform-logs/apply.txt for details"
    fi
    
    # Extract outputs
    log "Extracting Terraform outputs..."
    if ! terraform output -json > /terraform-logs/outputs.json 2>&1; then
        error_exit "Failed to extract Terraform outputs"
    fi
    
    # Verify outputs exist
    if [ ! -s /terraform-logs/outputs.json ]; then
        error_exit "No outputs generated. Cluster may not have been created successfully"
    fi
    
    # Extract key values
    CLUSTER_ID=$(terraform output -raw cluster_id 2>/dev/null || echo "")
    REGION=$(terraform output -raw aws_region 2>/dev/null || echo "$AWS_REGION")
    
    if [ -z "$CLUSTER_ID" ]; then
        error_exit "Failed to extract cluster ID from outputs"
    fi
    
    log "Cluster created successfully: $CLUSTER_ID"
    
    # Save cluster info for API to retrieve
    cat > /terraform-logs/cluster-info.json <<EOFINFO
{
  "cluster_name": "$CLUSTER_NAME",
  "cluster_id": "$CLUSTER_ID",
  "region": "$REGION",
  "kubeconfig_command": "aws eks update-kubeconfig --region $REGION --name $CLUSTER_ID",
  "status": "provisioned"
}
EOFINFO
    log "Cluster information saved to cluster-info.json"
    
    # Copy state files to persistent storage
    log "Copying state files to persistent storage..."
    mkdir -p "/terraform-state/$CLUSTER_NAME"
    if ! cp -r .terraform terraform.tfstate* tfplan "/terraform-state/$CLUSTER_NAME/" 2>&1 | tee -a /terraform-logs/copy-state.log; then
        warn "Could not copy all state files"
    fi
    
    log "EKS cluster provisioning completed successfully!"
    log ""
    log "=== Cluster Access Information ==="
    log "Cluster ID: $CLUSTER_ID"
    log "Region: $REGION"
    log "Configure kubectl: aws eks update-kubeconfig --region $REGION --name $CLUSTER_ID"
    log ""
    log "NOTE: EBS StorageClass must be applied manually after configuring kubectl"
    log "      kubectl apply -f k8s-manifests/ebs-storageclass.yaml"
    
else
    log "Dry run mode enabled. Skipping terraform apply."
    log "Plan has been saved. Review /terraform-logs/plan.txt for details."
    
    # Save dry run info
    cat > /terraform-logs/cluster-info.json <<EOFINFO
{
  "cluster_name": "$CLUSTER_NAME",
  "dry_run": true,
  "status": "plan_completed",
  "plan_file": "/terraform-logs/plan.txt
    
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
