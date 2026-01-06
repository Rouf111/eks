from kubernetes import client, config
from kubernetes.client.rest import ApiException
from typing import Dict, Tuple
import logging
import os

logger = logging.getLogger(__name__)


class KubernetesClient:
    """Client for managing Kubernetes Jobs and PVCs for EKS provisioning"""
    
    def __init__(self, namespace: str = "eks-provisioner"):
        """Initialize Kubernetes client"""
        try:
            # Try to load in-cluster config first
            config.load_incluster_config()
            logger.info("Loaded in-cluster Kubernetes configuration")
        except config.ConfigException:
            # Fall back to kubeconfig for local development
            config.load_kube_config()
            logger.info("Loaded kubeconfig from file")
        
        self.namespace = namespace
        self.batch_v1 = client.BatchV1Api()
        self.core_v1 = client.CoreV1Api()
        
        # Configuration
        self.worker_image = os.getenv("WORKER_IMAGE", "eks-provisioner-worker:latest")
        self.storage_class = os.getenv("STORAGE_CLASS", "nfs-client")
    
    def create_pvcs(self, cluster_name: str) -> Tuple[str, str]:
        """Create PVCs for Terraform state and logs"""
        state_pvc_name = f"tfstate-{cluster_name}"
        logs_pvc_name = f"tflogs-{cluster_name}"
        
        # Create state PVC
        state_pvc = client.V1PersistentVolumeClaim(
            metadata=client.V1ObjectMeta(
                name=state_pvc_name,
                labels={
                    "app": "eks-provisioner",
                    "cluster": cluster_name
                }
            ),
            spec=client.V1PersistentVolumeClaimSpec(
                access_modes=["ReadWriteMany"],
                resources=client.V1ResourceRequirements(
                    requests={"storage": "1Gi"}
                ),
                storage_class_name=self.storage_class
            )
        )
        
        # Create logs PVC
        logs_pvc = client.V1PersistentVolumeClaim(
            metadata=client.V1ObjectMeta(
                name=logs_pvc_name,
                labels={
                    "app": "eks-provisioner",
                    "cluster": cluster_name
                }
            ),
            spec=client.V1PersistentVolumeClaimSpec(
                access_modes=["ReadWriteMany"],
                resources=client.V1ResourceRequirements(
                    requests={"storage": "500Mi"}
                ),
                storage_class_name=self.storage_class
            )
        )
        
        try:
            self.core_v1.create_namespaced_persistent_volume_claim(
                namespace=self.namespace,
                body=state_pvc
            )
            logger.info(f"Created state PVC: {state_pvc_name}")
        except ApiException as e:
            if e.status == 409:
                logger.warning(f"State PVC already exists: {state_pvc_name}")
            else:
                raise
        
        try:
            self.core_v1.create_namespaced_persistent_volume_claim(
                namespace=self.namespace,
                body=logs_pvc
            )
            logger.info(f"Created logs PVC: {logs_pvc_name}")
        except ApiException as e:
            if e.status == 409:
                logger.warning(f"Logs PVC already exists: {logs_pvc_name}")
            else:
                raise
        
        return state_pvc_name, logs_pvc_name
    
    def create_provision_job(
        self,
        cluster_name: str,
        kubernetes_version: str,
        instance_type: str,
        ip_family: str,
        dry_run: bool = True
    ) -> str:
        """Create a Kubernetes Job for cluster provisioning"""
        
        # Create PVCs first
        state_pvc_name, logs_pvc_name = self.create_pvcs(cluster_name)
        
        # Job name
        operation = "test" if dry_run else "provision"
        job_name = f"{operation}-{cluster_name}"
        
        # Create Job
        job = client.V1Job(
            metadata=client.V1ObjectMeta(
                name=job_name,
                labels={
                    "app": "eks-provisioner",
                    "cluster": cluster_name,
                    "operation": operation
                }
            ),
            spec=client.V1JobSpec(
                backoff_limit=0,  # No retries for MVP
                ttl_seconds_after_finished=86400 if dry_run else None,  # 24h for test jobs
                template=client.V1PodTemplateSpec(
                    metadata=client.V1ObjectMeta(
                        labels={
                            "app": "eks-provisioner",
                            "cluster": cluster_name,
                            "operation": operation
                        }
                    ),
                    spec=client.V1PodSpec(
                        restart_policy="Never",
                        service_account_name="eks-provisioner",
                        containers=[
                            client.V1Container(
                                name="terraform",
                                image=self.worker_image,
                                image_pull_policy="Always",
                                command=["/bin/bash", "-c"],
                                args=["./provision.sh"],
                                env=[
                                    client.V1EnvVar(name="CLUSTER_NAME", value=cluster_name),
                                    client.V1EnvVar(name="KUBERNETES_VERSION", value=kubernetes_version),
                                    client.V1EnvVar(name="INSTANCE_TYPE", value=instance_type),
                                    client.V1EnvVar(name="IP_FAMILY", value=ip_family),
                                    client.V1EnvVar(name="DRY_RUN", value=str(dry_run).lower()),
                                    # AWS credentials from secret
                                    client.V1EnvVar(
                                        name="AWS_ACCESS_KEY_ID",
                                        value_from=client.V1EnvVarSource(
                                            secret_key_ref=client.V1SecretKeySelector(
                                                name="aws-creds",
                                                key="AWS_ACCESS_KEY_ID"
                                            )
                                        )
                                    ),
                                    client.V1EnvVar(
                                        name="AWS_SECRET_ACCESS_KEY",
                                        value_from=client.V1EnvVarSource(
                                            secret_key_ref=client.V1SecretKeySelector(
                                                name="aws-creds",
                                                key="AWS_SECRET_ACCESS_KEY"
                                            )
                                        )
                                    ),
                                    client.V1EnvVar(
                                        name="AWS_DEFAULT_REGION",
                                        value_from=client.V1EnvVarSource(
                                            secret_key_ref=client.V1SecretKeySelector(
                                                name="aws-creds",
                                                key="AWS_DEFAULT_REGION"
                                            )
                                        )
                                    ),
                                ],
                                volume_mounts=[
                                    client.V1VolumeMount(
                                        name="tfstate",
                                        mount_path="/terraform-state"
                                    ),
                                    client.V1VolumeMount(
                                        name="tflogs",
                                        mount_path="/terraform-logs"
                                    )
                                ]
                            )
                        ],
                        volumes=[
                            client.V1Volume(
                                name="tfstate",
                                persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(
                                    claim_name=state_pvc_name
                                )
                            ),
                            client.V1Volume(
                                name="tflogs",
                                persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(
                                    claim_name=logs_pvc_name
                                )
                            )
                        ]
                    )
                )
            )
        )
        
        try:
            self.batch_v1.create_namespaced_job(
                namespace=self.namespace,
                body=job
            )
            logger.info(f"Created job: {job_name}")
            return job_name
        except ApiException as e:
            if e.status == 409:
                logger.error(f"Job already exists: {job_name}")
                raise ValueError(f"Job {job_name} already exists")
            else:
                raise
    
    def create_destroy_job(self, cluster_name: str) -> str:
        """Create a Kubernetes Job for cluster destruction"""
        
        job_name = f"destroy-{cluster_name}"
        state_pvc_name = f"tfstate-{cluster_name}"
        logs_pvc_name = f"tflogs-{cluster_name}"
        
        # Verify PVCs exist
        try:
            self.core_v1.read_namespaced_persistent_volume_claim(
                name=state_pvc_name,
                namespace=self.namespace
            )
        except ApiException:
            raise ValueError(f"State PVC not found for cluster: {cluster_name}")
        
        # Create destroy job
        job = client.V1Job(
            metadata=client.V1ObjectMeta(
                name=job_name,
                labels={
                    "app": "eks-provisioner",
                    "cluster": cluster_name,
                    "operation": "destroy"
                }
            ),
            spec=client.V1JobSpec(
                backoff_limit=0,
                template=client.V1PodTemplateSpec(
                    metadata=client.V1ObjectMeta(
                        labels={
                            "app": "eks-provisioner",
                            "cluster": cluster_name,
                            "operation": "destroy"
                        }
                    ),
                    spec=client.V1PodSpec(
                        restart_policy="Never",
                        service_account_name="eks-provisioner",
                        containers=[
                            client.V1Container(
                                name="terraform",
                                image=self.worker_image,
                                image_pull_policy="Always",
                                command=["/bin/bash", "-c"],
                                args=["./destroy.sh"],
                                env=[
                                    client.V1EnvVar(name="CLUSTER_NAME", value=cluster_name),
                                    # AWS credentials from secret
                                    client.V1EnvVar(
                                        name="AWS_ACCESS_KEY_ID",
                                        value_from=client.V1EnvVarSource(
                                            secret_key_ref=client.V1SecretKeySelector(
                                                name="aws-creds",
                                                key="AWS_ACCESS_KEY_ID"
                                            )
                                        )
                                    ),
                                    client.V1EnvVar(
                                        name="AWS_SECRET_ACCESS_KEY",
                                        value_from=client.V1EnvVarSource(
                                            secret_key_ref=client.V1SecretKeySelector(
                                                name="aws-creds",
                                                key="AWS_SECRET_ACCESS_KEY"
                                            )
                                        )
                                    ),
                                    client.V1EnvVar(
                                        name="AWS_DEFAULT_REGION",
                                        value_from=client.V1EnvVarSource(
                                            secret_key_ref=client.V1SecretKeySelector(
                                                name="aws-creds",
                                                key="AWS_DEFAULT_REGION"
                                            )
                                        )
                                    ),
                                ],
                                volume_mounts=[
                                    client.V1VolumeMount(
                                        name="tfstate",
                                        mount_path="/terraform-state"
                                    ),
                                    client.V1VolumeMount(
                                        name="tflogs",
                                        mount_path="/terraform-logs"
                                    )
                                ]
                            )
                        ],
                        volumes=[
                            client.V1Volume(
                                name="tfstate",
                                persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(
                                    claim_name=state_pvc_name
                                )
                            ),
                            client.V1Volume(
                                name="tflogs",
                                persistent_volume_claim=client.V1PersistentVolumeClaimVolumeSource(
                                    claim_name=logs_pvc_name
                                )
                            )
                        ]
                    )
                )
            )
        )
        
        try:
            self.batch_v1.create_namespaced_job(
                namespace=self.namespace,
                body=job
            )
            logger.info(f"Created destroy job: {job_name}")
            return job_name
        except ApiException as e:
            if e.status == 409:
                logger.error(f"Destroy job already exists: {job_name}")
                raise ValueError(f"Job {job_name} already exists")
            else:
                raise
    
    def get_job_status(self, job_name: str) -> Dict:
        """Get status of a Kubernetes Job"""
        try:
            job = self.batch_v1.read_namespaced_job_status(
                name=job_name,
                namespace=self.namespace
            )
            
            status = "running"
            phase = "Unknown"
            message = None
            
            if job.status.succeeded:
                status = "completed"
                phase = "Succeeded"
            elif job.status.failed:
                status = "failed"
                phase = "Failed"
                message = f"Job failed with {job.status.failed} failures"
            elif job.status.active:
                status = "running"
                phase = "Running"
            
            return {
                "status": status,
                "phase": phase,
                "message": message,
                "succeeded": job.status.succeeded or 0,
                "failed": job.status.failed or 0,
                "active": job.status.active or 0
            }
        except ApiException as e:
            if e.status == 404:
                return {"status": "not_found", "phase": "NotFound", "message": "Job not found"}
            raise
    
    def get_logs(self, cluster_name: str, log_file: str = "plan.txt") -> str:
        """Get logs from the logs PVC by reading from a completed pod"""
        logs_pvc_name = f"tflogs-{cluster_name}"
        
        try:
            # Try to read from a completed job pod
            pods = self.core_v1.list_namespaced_pod(
                namespace=self.namespace,
                label_selector=f"cluster={cluster_name}"
            )
            
            if not pods.items:
                return "No pods found for this cluster"
            
            # Get logs from the first pod
            pod_name = pods.items[0].metadata.name
            
            try:
                logs = self.core_v1.read_namespaced_pod_log(
                    name=pod_name,
                    namespace=self.namespace,
                    tail_lines=500
                )
                return logs
            except ApiException:
                return f"Could not retrieve logs from pod {pod_name}"
                
        except ApiException as e:
            return f"Error retrieving logs: {str(e)}"
    
    def delete_cluster_resources(self, cluster_name: str) -> Dict:
        """Delete all resources (Jobs and PVCs) for a cluster"""
        deleted = {"jobs": [], "pvcs": []}
        
        # Delete jobs
        try:
            jobs = self.batch_v1.list_namespaced_job(
                namespace=self.namespace,
                label_selector=f"cluster={cluster_name}"
            )
            for job in jobs.items:
                self.batch_v1.delete_namespaced_job(
                    name=job.metadata.name,
                    namespace=self.namespace,
                    propagation_policy="Foreground"
                )
                deleted["jobs"].append(job.metadata.name)
                logger.info(f"Deleted job: {job.metadata.name}")
        except ApiException as e:
            logger.error(f"Error deleting jobs: {e}")
        
        # Delete PVCs
        for pvc_name in [f"tfstate-{cluster_name}", f"tflogs-{cluster_name}"]:
            try:
                self.core_v1.delete_namespaced_persistent_volume_claim(
                    name=pvc_name,
                    namespace=self.namespace
                )
                deleted["pvcs"].append(pvc_name)
                logger.info(f"Deleted PVC: {pvc_name}")
            except ApiException as e:
                if e.status != 404:
                    logger.error(f"Error deleting PVC {pvc_name}: {e}")
        
        return deleted
