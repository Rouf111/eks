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
if [ -z "$CLUSTER_NAME" ]; then
    error "CLUSTER_NAME environment variable is not set"
    exit 1
fi

AWS_REGION=${AWS_REGION:-ap-south-1}

log "Starting EKS cluster destruction..."
log "Cluster Name: $CLUSTER_NAME"

# Restore state from persistent storage
log "Restoring Terraform state from persistent storage..."
if [ -d "/terraform-state/$CLUSTER_NAME" ]; then
    cp -r "/terraform-state/$CLUSTER_NAME"/.terraform . 2>&1 | tee /terraform-logs/restore.log || warn "Could not restore .terraform directory"
    cp "/terraform-state/$CLUSTER_NAME"/terraform.tfstate* . 2>&1 | tee -a /terraform-logs/restore.log || warn "Could not restore state files"
    log "State restored successfully"
else
    error "State directory not found for cluster: $CLUSTER_NAME"
    exit 1
fi

# Re-initialize Terraform to ensure backend is configured
log "Re-initializing Terraform..."
terraform init 2>&1 | tee /terraform-logs/destroy-init.log

# Get cluster ID from state
CLUSTER_ID=$(terraform output -raw cluster_id 2>/dev/null || echo "")

if [ -z "$CLUSTER_ID" ]; then
    warn "Could not extract cluster ID from state. Using cluster name: $CLUSTER_NAME"
    CLUSTER_ID=$CLUSTER_NAME
fi

log "Cluster ID: $CLUSTER_ID"

# Update kubeconfig to access the cluster
log "Updating kubeconfig..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_ID" 2>&1 | tee /terraform-logs/destroy-kubeconfig.log || warn "Could not update kubeconfig"

# Delete LoadBalancer services to prevent orphaned AWS resources
log "Checking for LoadBalancer services..."
LB_SERVICES=$(kubectl get svc --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' || echo "")

if [ -n "$LB_SERVICES" ]; then
    log "Found LoadBalancer services. Deleting them to prevent orphaned resources..."
    echo "$LB_SERVICES" | while read -r svc; do
        NAMESPACE=$(echo "$svc" | cut -d'/' -f1)
        SERVICE=$(echo "$svc" | cut -d'/' -f2)
        log "Deleting service $SERVICE in namespace $NAMESPACE..."
        kubectl delete svc "$SERVICE" -n "$NAMESPACE" --timeout=120s 2>&1 | tee -a /terraform-logs/delete-services.log || warn "Could not delete service $SERVICE"
    done
    log "Waiting 30 seconds for LoadBalancers to be fully deleted..."
    sleep 30
else
    log "No LoadBalancer services found"
fi

# Run Terraform Destroy
log "Running Terraform destroy..."
terraform destroy -auto-approve 2>&1 | tee /terraform-logs/destroy.log

# Save destruction info
cat > /terraform-logs/destroy-info.json <<EOF
{
  "cluster_name": "$CLUSTER_NAME",
  "cluster_id": "$CLUSTER_ID",
  "destroyed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "destroyed"
}
EOF

log "EKS cluster destruction completed successfully!"
exit 0
