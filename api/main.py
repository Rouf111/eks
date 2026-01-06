from fastapi import FastAPI, HTTPException, status
from fastapi.responses import JSONResponse
from datetime import datetime
import logging
import json

from models import ClusterRequest, ClusterResponse, ClusterStatus, ClusterLogs
from k8s_client import KubernetesClient

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Initialize FastAPI app
app = FastAPI(
    title="EKS Cluster Provisioner API",
    description="API for provisioning and managing EKS clusters via Terraform",
    version="1.0.0"
)

# Initialize Kubernetes client
k8s_client = KubernetesClient(namespace="eks-provisioner")


@app.get("/")
async def root():
    """Root endpoint"""
    return {
        "service": "EKS Cluster Provisioner API",
        "version": "1.0.0",
        "endpoints": {
            "test": "POST /clusters/test",
            "provision": "POST /clusters/provision",
            "status": "GET /clusters/{cluster_name}/status",
            "logs": "GET /clusters/{cluster_name}/logs",
            "destroy": "DELETE /clusters/{cluster_id}",
            "cleanup": "DELETE /clusters/{cluster_name}/cleanup"
        }
    }


@app.get("/health")
async def health():
    """Health check endpoint"""
    return {"status": "healthy", "timestamp": datetime.utcnow().isoformat()}


@app.post("/clusters/test", response_model=ClusterResponse, status_code=status.HTTP_202_ACCEPTED)
async def test_cluster(request: ClusterRequest):
    """
    Test cluster configuration with dry-run (terraform plan only).
    Does not create actual AWS resources.
    """
    logger.info(f"Received test request for cluster: {request.cluster_name}")
    
    try:
        # Create provision job with dry_run=True
        job_name = k8s_client.create_provision_job(
            cluster_name=request.cluster_name,
            kubernetes_version=request.kubernetes_version,
            instance_type=request.instance_type,
            ip_family=request.ip_family,
            dry_run=True
        )
        
        return ClusterResponse(
            cluster_name=request.cluster_name,
            job_name=job_name,
            status="pending",
            message="Dry-run job created. Check status endpoint for progress.",
            created_at=datetime.utcnow().isoformat()
        )
    
    except ValueError as e:
        logger.error(f"Validation error: {str(e)}")
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
    except Exception as e:
        logger.error(f"Error creating test job: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to create test job: {str(e)}"
        )


@app.post("/clusters/provision", response_model=ClusterResponse, status_code=status.HTTP_202_ACCEPTED)
async def provision_cluster(request: ClusterRequest):
    """
    Provision actual EKS cluster (terraform apply).
    Creates real AWS resources.
    """
    logger.info(f"Received provision request for cluster: {request.cluster_name}")
    
    try:
        # Create provision job with dry_run=False
        job_name = k8s_client.create_provision_job(
            cluster_name=request.cluster_name,
            kubernetes_version=request.kubernetes_version,
            instance_type=request.instance_type,
            ip_family=request.ip_family,
            dry_run=False
        )
        
        return ClusterResponse(
            cluster_name=request.cluster_name,
            job_name=job_name,
            status="pending",
            message="Provisioning job created. This will take 15-20 minutes. Check status endpoint for progress.",
            created_at=datetime.utcnow().isoformat()
        )
    
    except ValueError as e:
        logger.error(f"Validation error: {str(e)}")
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
    except Exception as e:
        logger.error(f"Error creating provision job: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to create provision job: {str(e)}"
        )


@app.get("/clusters/{cluster_name}/status", response_model=ClusterStatus)
async def get_cluster_status(cluster_name: str):
    """
    Get status of a cluster provisioning/destroy job.
    Returns job phase, status, and cluster details if available.
    """
    logger.info(f"Status request for cluster: {cluster_name}")
    
    try:
        # Try to find any job for this cluster
        jobs = ["test-" + cluster_name, "provision-" + cluster_name, "destroy-" + cluster_name]
        
        job_status = None
        found_job = None
        
        for job_name in jobs:
            status_info = k8s_client.get_job_status(job_name)
            if status_info["status"] != "not_found":
                job_status = status_info
                found_job = job_name
                break
        
        if not job_status:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"No job found for cluster: {cluster_name}"
            )
        
        response = ClusterStatus(
            cluster_name=cluster_name,
            job_name=found_job,
            status=job_status["status"],
            phase=job_status["phase"],
            message=job_status.get("message")
        )
        
        # If job completed successfully and it was a provision job, try to get cluster info
        if job_status["status"] == "completed" and "provision-" in found_job:
            try:
                # Try to read cluster info from logs
                cluster_info = k8s_client.get_logs(cluster_name, "cluster-info.json")
                if cluster_info and cluster_info != "No pods found for this cluster":
                    # Parse if it's JSON
                    try:
                        info = json.loads(cluster_info) if "{" in cluster_info else {}
                        response.cluster_id = info.get("cluster_id")
                        response.kubeconfig_command = info.get("kubeconfig_command")
                    except:
                        pass
            except:
                pass
        
        return response
    
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting status: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get cluster status: {str(e)}"
        )


@app.get("/clusters/{cluster_name}/logs", response_model=ClusterLogs)
async def get_cluster_logs(cluster_name: str):
    """
    Get logs from cluster provisioning/destroy job.
    Returns recent logs from the job pod.
    """
    logger.info(f"Logs request for cluster: {cluster_name}")
    
    try:
        logs = k8s_client.get_logs(cluster_name)
        
        return ClusterLogs(
            cluster_name=cluster_name,
            logs=logs,
            log_type="terraform"
        )
    
    except Exception as e:
        logger.error(f"Error getting logs: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get logs: {str(e)}"
        )


@app.delete("/clusters/{cluster_id}", response_model=ClusterResponse)
async def destroy_cluster(cluster_id: str):
    """
    Destroy an EKS cluster by running terraform destroy.
    Requires cluster_id (which is typically the cluster_name).
    """
    logger.info(f"Received destroy request for cluster: {cluster_id}")
    
    try:
        # Create destroy job
        job_name = k8s_client.create_destroy_job(cluster_name=cluster_id)
        
        return ClusterResponse(
            cluster_name=cluster_id,
            cluster_id=cluster_id,
            job_name=job_name,
            status="pending",
            message="Destroy job created. This will take several minutes. Check status endpoint for progress."
        )
    
    except ValueError as e:
        logger.error(f"Validation error: {str(e)}")
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))
    except Exception as e:
        logger.error(f"Error creating destroy job: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to create destroy job: {str(e)}"
        )


@app.delete("/clusters/{cluster_name}/cleanup")
async def cleanup_cluster(cluster_name: str):
    """
    Cleanup all Kubernetes resources (Jobs and PVCs) for a cluster.
    Use this after destroying the cluster or to clean up failed jobs.
    """
    logger.info(f"Received cleanup request for cluster: {cluster_name}")
    
    try:
        deleted = k8s_client.delete_cluster_resources(cluster_name)
        
        return {
            "cluster_name": cluster_name,
            "status": "cleaned_up",
            "deleted": deleted,
            "message": f"Deleted {len(deleted['jobs'])} jobs and {len(deleted['pvcs'])} PVCs"
        }
    
    except Exception as e:
        logger.error(f"Error cleaning up resources: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to cleanup resources: {str(e)}"
        )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
