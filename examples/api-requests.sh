# Example API requests for testing

# Base URL - replace with your LoadBalancer IP
BASE_URL="http://YOUR_LOAD_BALANCER_IP"

# 1. Health Check
curl $BASE_URL/health

# 2. Test cluster configuration (dry-run)
curl -X POST $BASE_URL/clusters/test \
  -H "Content-Type: application/json" \
  -d '{
    "cluster_name": "test-cluster-001",
    "kubernetes_version": "1.33",
    "instance_type": "m5.xlarge",
    "ip_family": "ipv6"
  }'

# 3. Check status
curl $BASE_URL/clusters/test-cluster-001/status

# 4. Get logs
curl $BASE_URL/clusters/test-cluster-001/logs

# 5. Provision actual cluster (creates real AWS resources!)
curl -X POST $BASE_URL/clusters/provision \
  -H "Content-Type: application/json" \
  -d '{
    "cluster_name": "prod-cluster-001",
    "kubernetes_version": "1.33",
    "instance_type": "m5.xlarge",
    "ip_family": "ipv6"
  }'

# 6. Check provision status
curl $BASE_URL/clusters/prod-cluster-001/status

# 7. Destroy cluster
curl -X DELETE $BASE_URL/clusters/prod-cluster-001

# 8. Cleanup resources after destroy completes
curl -X DELETE $BASE_URL/clusters/prod-cluster-001/cleanup
