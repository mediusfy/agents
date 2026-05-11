from dataclasses import dataclass
from typing import Dict
# pyrefly: ignore [missing-import]
from pydantic_ai import Agent, RunContext
from openclaw.models.core import Artifact
from openclaw.config import AgentSettings

sre_prompt = '''You are a Senior SRE Agent tasked with the automated deployment and lifecycle management of the OpenClaw ecosystem across multi-cloud Kubernetes clusters. You treat infrastructure as strictly **immutable code**, orchestrating modifications via robust GitOps workflows.

Infrastructure Stack & Security Controls:
- Tools & IaC: Utilize Terraform / OpenTofu combined with Crossplane for declarative, multi-region global state management.
- Security Automation: Autonomously manage credential/secret rotation and enforce strict NetworkPolicies within Kubernetes boundaries.
- Resilience & Scaling: Configure proactive multi-region failover mechanisms and define Horizontal Pod Autoscaler (HPA) targets driven by custom service metrics.


CRITICAL WORKFLOW:
1. **History Review:** Use `query_history` to recall previous architectural and contextual decisions before generating logic.
2. **Log Progress:** Call `log_activity` after significant actions.
3. **Proactive Docs:** Keep `docs/` updated via `update_documentation` when implementing major features.
'''


@dataclass
class SreDeps:
    pass_num: int = 1
    agent_name: str = "sre"

sre_agent = Agent(
    AgentSettings.SRE_MODEL,
    deps_type=SreDeps,
    system_prompt=sre_prompt,
    output_type=Artifact,
    defer_model_check=True
)

from openclaw.a2a import agent_bus
agent_bus.register("sre", sre_agent, ["infra_advice"], lambda: SreDeps())

@sre_agent.tool
def provision_k8s_cluster(ctx: RunContext[str], provider: str, region: str, cluster_name: str) -> Dict[str, str]:
    """Returns Terraform/OpenTofu HCL: VPC, EKS/GKE cluster, node groups, IAM roles, OIDC provider, IRSA."""
    return {
        "terraform/main.tf": f'# Terraform for {provider} in {region}\\nresource "kubernetes_cluster" "main" {{}}',
        "terraform/vpc.tf": "# VPC + subnets + NAT",
        "terraform/iam.tf": "# IAM roles + OIDC + IRSA",
        "terraform/outputs.tf": "# Cluster endpoint, kubeconfig",
        "terraform/variables.tf": "# Region, cluster_name, instance types"
    }

@sre_agent.tool
def apply_helm_chart(ctx: RunContext[str], service_name: str, image: str, port: int) -> Dict[str, str]:
    """Returns Helm chart: Chart.yaml, values.yaml, templates/ with Deployment, Service, Ingress, NetworkPolicy, HPA, ServiceMonitor, PDB."""
    return {
        f"helm/{service_name}/Chart.yaml": f"name: {service_name}\\nversion: 1.0.0",
        f"helm/{service_name}/values.yaml": f"image: {image}\\nport: {port}",
        f"helm/{service_name}/templates/deployment.yaml": "# Deployment",
        f"helm/{service_name}/templates/service.yaml": "# Service",
        f"helm/{service_name}/templates/ingress.yaml": "# Ingress",
        f"helm/{service_name}/templates/hpa.yaml": "# HPA",
        f"helm/{service_name}/templates/servicemonitor.yaml": "# ServiceMonitor",
        f"helm/{service_name}/templates/networkpolicy.yaml": "# NetworkPolicy",
        f"helm/{service_name}/templates/pdb.yaml": "# PDB"
    }


