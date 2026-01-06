from pydantic import BaseModel, Field, field_validator
import re
from typing import Literal, Optional, List


class ClusterRequest(BaseModel):
    """Request model for cluster creation/testing"""
    cluster_name: str = Field(
        ...,
        min_length=1,
        max_length=100,
        description="DNS-compliant cluster name (alphanumeric and hyphens only)"
    )
    kubernetes_version: str = Field(
        ...,
        description="Kubernetes version (e.g., 1.33, 1.32, 1.31)"
    )
    instance_type: str = Field(
        ...,
        description="EC2 instance type (e.g., m5.xlarge, t3.medium)"
    )
    ip_family: Literal["ipv4", "ipv6"] = Field(
        ...,
        description="IP family for the cluster (ipv4 or ipv6)"
    )

    @field_validator("cluster_name")
    @classmethod
    def validate_cluster_name(cls, v: str) -> str:
        """Validate cluster name is DNS-compliant"""
        # Must start with alphanumeric, end with alphanumeric, can contain hyphens
        pattern = r"^[a-z0-9]([a-z0-9-]{0,98}[a-z0-9])?$"
        if not re.match(pattern, v):
            raise ValueError(
                "Cluster name must be DNS-compliant: "
                "start and end with alphanumeric characters, "
                "can contain hyphens, lowercase only, max 100 characters"
            )
        return v

    @field_validator("kubernetes_version")
    @classmethod
    def validate_kubernetes_version(cls, v: str) -> str:
        """Validate Kubernetes version format and supported versions"""
        # Pattern: 1.XX
        pattern = r"^1\.\d{1,2}$"
        if not re.match(pattern, v):
            raise ValueError("Kubernetes version must be in format 1.XX (e.g., 1.33)")
        
        # Check supported versions (as of Jan 2026: 1.31, 1.32, 1.33)
        supported_versions = ["1.31", "1.32", "1.33"]
        if v not in supported_versions:
            raise ValueError(
                f"Kubernetes version {v} is not in supported versions: {', '.join(supported_versions)}"
            )
        return v

    @field_validator("instance_type")
    @classmethod
    def validate_instance_type(cls, v: str) -> str:
        """Validate EC2 instance type format"""
        # Pattern: family.size (e.g., m5.xlarge, t3.medium)
        pattern = r"^[a-z][0-9][a-z]?\.(nano|micro|small|medium|large|xlarge|[0-9]+xlarge)$"
        if not re.match(pattern, v):
            raise ValueError(
                "Instance type must be valid EC2 format (e.g., m5.xlarge, t3.medium)"
            )
        return v


class ClusterResponse(BaseModel):
    """Response model for cluster operations"""
    cluster_name: str
    cluster_id: str = None
    cluster_guid: str = None
    job_name: str
    status: str
    message: str = None
    kubeconfig_command: str = None
    created_at: str = None


class ClusterStatus(BaseModel):
    """Response model for cluster status"""
    cluster_name: str
    job_name: str
    status: str
    phase: str
    message: str = ""
    cluster_id: Optional[str] = None
    cluster_guid: Optional[str] = None
    cluster_arn: Optional[str] = None
    kubeconfig_command: Optional[str] = None


class ClusterLogs(BaseModel):
    """Response model for cluster logs"""
    cluster_name: str
    logs: str
    log_type: str = "terraform"


class ClusterInfo(BaseModel):
    """Response model for cluster list item"""
    cluster_name: str
    cluster_id: Optional[str] = None
    cluster_guid: Optional[str] = None
    provider: str = "AWS EKS"
    kubernetes_version: Optional[str] = None
    instance_type: Optional[str] = None
    region: Optional[str] = None
    status: str
    phase: str
    created_at: Optional[str] = None
    last_operation: str  # provision or destroy


class ClusterListResponse(BaseModel):
    """Response model for cluster list"""
    total: int
    clusters: List[ClusterInfo]
