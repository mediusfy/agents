from typing import Dict
from dataclasses import dataclass
# pyrefly: ignore [missing-import]
from pydantic_ai import Agent, RunContext
from src.models.core import Artifact
from src.config import AgentSettings
from src.a2a import agent_bus

@dataclass
class ProjectState:
    base_path: str
    environment: str
    team_owner: str

backend_agent = Agent(
    AgentSettings.BACKEND_MODEL,
    deps_type=ProjectState,
    system_prompt='''You are a Lead Go Backend Engineer specializing in high-concurrency, event-driven systems. Your primary objective is to build "Self-Healing" services that strictly adhere to **Hexagonal (Ports and Adapters) Architecture**. Every service must be cloud-native, gRPC-enabled, and compliant with the **CloudEvents** specification.

Technical Requirements:
- Language & Concurrency: Golang 1.26+ using context-based cancellation and worker pool patterns for robust goroutine management.
- Messaging: NATS / Kafka integration with idempotent consumer logic to ensure safe and reliable event retries.
- Observability: Mandatory Prometheus metrics and OpenTelemetry spans for distributed tracing across every service endpoint.
- Versioning: Enforce strict semantic versioning for all gRPC Protobuf definitions to ensure backward compatibility.
''',
    output_type=Artifact,
    defer_model_check=True
)

@backend_agent.tool
def scaffold_go_service(ctx: RunContext[ProjectState], service_name: str, bounded_context: str) -> Dict[str, str]:
    """Returns a complete Go project skeleton. The LLM fills in domain-specific logic in its main response."""
    return {
        f"cmd/{service_name}/main.go": f"// Scaffolding for {service_name}\npackage main\n\nfunc main() {{}}",
        "internal/domain/entity.go": "package domain\n",
        "internal/domain/events.go": "package domain\n",
        "internal/application/usecase.go": "package application\n", 
        "internal/ports/repository.go": "package ports\n",
        "internal/ports/events.go": "package ports\n",
        "internal/adapters/repository/postgres.go": "package repository\n",
        "internal/adapters/eventbus/nats.go": "package eventbus\n",
        "internal/adapters/handlers/grpc.go": "package handlers\n",
        "internal/application/usecase_test.go": "package application_test\n",
        f"api/protobuf/{service_name}/v1/{service_name}.proto": 'syntax="proto3";\n',
        "go.mod": f"module {service_name}\n\ngo 1.26",
        "Makefile": f"build:\n\tgo build -o bin/server cmd/{service_name}/main.go"
    }

@backend_agent.tool
def generate_dockerfile(ctx: RunContext[ProjectState], service_name: str, port: int) -> str:
    """Returns multi-stage Dockerfile: golang:1.26-alpine build stage, alpine:3.21 runtime, non-root user, health probes."""
    return f"""FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY . .
RUN go build -o /bin/server cmd/{service_name}/main.go

FROM alpine:3.21
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser
COPY --from=builder /bin/server /server
EXPOSE {port}
HEALTHCHECK --interval=30s --timeout=3s CMD wget --no-verbose --tries=1 --spider http://localhost:{port}/health || exit 1
ENTRYPOINT ["/server"]
"""

@backend_agent.tool
async def consult_sre(ctx: RunContext[ProjectState], infra_requirement: str) -> str:
    """Consult the SRE agent about infrastructure constraints, K8s resources, or scaling strategy."""
    return await agent_bus.query("infra_advice", infra_requirement)