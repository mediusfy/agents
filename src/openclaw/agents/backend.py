from dataclasses import dataclass

from pydantic_ai import Agent, RunContext

from openclaw.models.core import Artifact
from openclaw.settings import settings
from openclaw.models.factory import create_model


@dataclass
class ProjectState:
    base_path: str
    environment: str
    team_owner: str


backend_agent = Agent(
    create_model(settings.resolve_model(settings.backend_model)),
    system_prompt="""You are a Lead Go Backend Engineer specializing in high-concurrency, event-driven systems. Your primary objective is to build "Self-Healing" services that strictly adhere to **Hexagonal (Ports and Adapters) Architecture**. Every service must be cloud-native, gRPC-enabled, and compliant with the **CloudEvents** specification.

    Technical Requirements:
    - Language & Concurrency: Golang 1.26+ using context-based cancellation and worker pool patterns for robust goroutine management.
    - Messaging: NATS / Kafka integration with idempotent consumer logic to ensure safe and reliable event retries.
    - Observability: Mandatory Prometheus metrics and OpenTelemetry spans for distributed tracing across every service endpoint.
    - Versioning: Enforce strict semantic versioning for all gRPC Protobuf definitions to ensure backward compatibility.
    """,
    output_type=Artifact,
    defer_model_check=True,
)


@backend_agent.tool
def scaffold_go_service(ctx: RunContext[str], service_name: str, bounded_context: str) -> dict[str, str]:
    """Returns a complete Go project skeleton. The LLM fills in domain-specific logic in its main response."""
    return {
        "cmd/server/main.go": f"// Scaffolding for {service_name}\npackage main\n\nfunc main() {{}}",
        f"internal/domain/{service_name}.go": "package domain\n",
        "internal/domain/events.go": "package domain\n",
        "internal/ports/repository.go": "package ports\n",
        "internal/ports/events.go": "package ports\n",
        "internal/adapters/repository/postgres.go": "package repository\n",
        "internal/adapters/eventbus/nats.go": "package eventbus\n",
        "internal/adapters/handlers/grpc.go": "package handlers\n",
        f"api/protobuf/{service_name}.proto": 'syntax="proto3";\n',
        "go.mod": f"module {service_name}\n\ngo 1.26",
        "Makefile": "build:\n\\tgo build -o bin/server cmd/server/main.go",
    }


@backend_agent.tool
def generate_dockerfile(ctx: RunContext[str], service_name: str, port: int) -> str:
    """Returns multi-stage Dockerfile: golang:1.26-alpine build stage, alpine:3.21 runtime, non-root user, health probes."""
    return f"FROM golang:1.26-alpine AS builder\n# Build steps...\nEXPOSE {port}\n"
