# OpenClaw Agent Ecosystem — Implementation Plan

> **Note:** This document reflects the original implementation plan and historical architecture intent. Some details (file paths, model assignments, agent count) are out of date. For current architecture refer to `README.md`, `agents/*.md`, and `src/openclaw/`. Retained as reference for ADR context.

## Overview

Build 6 domain-specific AI agents that generate production-grade application code. The agents are orchestrated by OpenClaw in a pipeline: **BA → Backend + Frontend → Test → SRE → Review**. Artifacts stay in-memory until the Review agent approves, then are written to disk.

---

## 0. OpenClaw — Orchestrator Role

OpenClaw is the interactive orchestrator that sits above the agent pipeline. It coordinates the flow, provides context to each agent, and gates the final output.

### 0.1 How OpenClaw Orchestrates

```
┌────────────────────────────────────────────────────────────┐
│  OpenClaw (Orchestrator)                                   │
│  • Reads agent specs + implementation plan for context     │
│  • Determines pipeline order and parameters                │
│  • Passes artifacts between agents                         │
│  • Evaluates review results and decides next action        │
│  • Writes approved artifacts to disk                       │
└────────────────────────────────────────────────────────────┘
                          │
        ┌─────────────────┼────────────────────┐
        │                 │                    │
        ▼                 ▼                    ▼
   ┌──────────┐    ┌──────────┐         ┌──────────┐
   │ Agent 1  │    │ Agent 2  │   ...   │ Agent N  │
   │ (BA)     │───▶│ (Backend)│         │ (Review) │
   └──────────┘    └──────────┘         └──────────┘
```

### 0.2 Context Loading

At startup, OpenClaw reads these files to build context:

| File | Purpose |
|------|---------|
| `docs/Implementation Plan.md` | Full pipeline design, model assignments, tool specs |
| `docs/Agent Spec_ Business Analyst.md` | BA role, DDD focus, Gherkin requirements |
| `docs/Agent Spec_ Backend Go Engineer.md` | Go/Hexagonal/event-driven specs |
| `docs/Agent Spec_ Frontend Engineer.md` | Vue 3/TSX/WCAG specs |
| `docs/Agent Spec_ Test Engineer.md` | BDD/Playwright testing strategy |
| `docs/Agent Spec_ SRE (Infrastructure).md` | Terraform/Helm/K8s infra specs |
| `docs/Agent Spec_ Board of Review.md` | Governance/review criteria |
| `src/models/core.py` | Data models (Artifact, UserStory, ReviewResult) |
| `src/agents/*.py` | Current agent implementations and tools |
| `main.py` | Current pipeline orchestration entry point |

### 0.3 Execution Pattern

For each step in the pipeline, OpenClaw:

1. **Reads context** — reviews the relevant agent spec for system prompt, tools, and output expectations
2. **Invokes the agent** — runs `python main.py` with the appropriate agent and input, or calls the `pydantic_ai` agent directly
3. **Collects output** — captures the structured result (UserStories, Artifacts, ReviewResult)
4. **Passes to next step** — feeds output as input to the downstream agent
5. **Gates on review** — if Review rejects, either stops with feedback or triggers regeneration

### 0.4 OpenClaw Decision Points

OpenClaw makes these decisions during orchestration:

| Decision Point | What OpenClaw Evaluates |
|----------------|------------------------|
| **Pipeline start** | Is the user request clear enough? Should BA be skipped if specs already exist? |
| **Story fan-out** | How many stories to process? Can they run in parallel? |
| **Review gate** | Is the risk level acceptable? Should rejected artifacts be regenerated with feedback? |
| **Output** | Where to write generated files? What format (flat vs namespaced by agent)? |
| **Retry** | How many retry attempts? Should specific agents be re-run with review feedback injected? |

### 0.5 Example OpenClaw Session Flow

```
> openclaw: "Build a payment processing service..."
  OpenClaw reads agent specs + plan → builds context
  OpenClaw runs BA agent → receives 3 user stories
  OpenClaw fans out: Backend + Frontend for each story in parallel
  OpenClaw runs Test agent for each story
  OpenClaw runs SRE agent (one shot)
  OpenClaw runs Review agent → evaluates all artifacts
  OpenClaw gates: Review rejected (security_score: 45, risk: HIGH)
  OpenClaw logs feedback and stops — or triggers regeneration
```

---

## 1. Architecture: How Agents Generate Code

### The pydantic_ai Code Generation Flow

```
1. Agent receives: system_prompt (role) + user prompt (task)
2. pydantic_ai instructs the LLM: "Your response MUST match result_type schema"
3. LLM generates code/content matching the prompt
4. pydantic_ai parses output into the result_type (Artifact, List[UserStory], ReviewResult)
5. Agent returns structured result to the pipeline
```

**Key insight**: Tools are optional. The LLM generates code directly in its response. Tools provide:
- Template skeletons the LLM can reference
- Validation of generated content
- Scaffolding for boilerplate

### Artifact Data Model

```python
class Artifact(BaseModel):
    agent_name: str                         # "backend", "frontend", "sre", "test"
    files: Dict[str, str] = Field(          # relative path → file contents
        description="Map of file paths to their contents"
    )
    metadata: Dict[str, Any] = Field(
        default_factory=lambda: {
            "user_story_id": "",
            "service_name": "",
            "language": "",
            "framework": "",
        }
    )
```

Example `files` from Backend agent:

```json
{
  "cmd/server/main.go": "package main\n\nfunc main() { ... }",
  "internal/domain/payment.go": "package domain\n...",
  "internal/ports/repository.go": "package ports\n...",
  "internal/adapters/postgres.go": "package adapters\n...",
  "api/protobuf/service.proto": "syntax=\"proto3\";...",
  "go.mod": "module payment-service\n\ngo 1.24",
  "Dockerfile": "FROM golang:1.24-alpine AS builder\n..."
}
```

### Output Directory Structure (after review approval)

```
generated-app/
├── backend/
│   ├── cmd/server/main.go
│   ├── internal/domain/
│   ├── internal/ports/
│   ├── internal/adapters/
│   ├── api/protobuf/
│   ├── go.mod
│   └── Dockerfile
├── frontend/
│   ├── components/
│   ├── pages/
│   └── package.json
├── tests/
│   └── playwright/
│       └── specs/
└── infrastructure/
    ├── terraform/
    └── helm/
```

---

## 2. Agent Model Assignments

| Agent | Recommended Model | Rationale |
|-------|------------------|-----------|
| **BA** | `gpt-4o-mini` | Structured Gherkin extraction. Cheap, fast. No code gen needed. |
| **Backend (Go)** | `claude-sonnet-4-20250514` | Best Go code generation. Hexagonal Architecture, gRPC, OTel. |
| **Frontend** | `gpt-4o` | Strong Vue 3/TSX generation. |
| **Test Engineer** | `gpt-4o-mini` | Playwright tests are relatively structured. Cost-efficient. |
| **SRE** | `gemini-2.0-flash` | Terraform/Helm/Docker output is structured/templated. Fast + cheap. |
| **Review** | `claude-sonnet-4-20250514` | Strongest reasoning for governance, security scoring, risk assessment. |

All models are configurable via environment variables.

---

## 3. Agent Implementation Details

### 3.1 Business Analyst Agent

**System Prompt**: Domain-Driven Design specialist. Translates goals into bounded contexts, event triggers, Gherkin acceptance criteria, multi-cloud constraints.

**Tools**:

| Tool | Type | Behavior |
|------|------|----------|
| `define_user_stories(raw_requirements: str) -> List[UserStory]` | **LLM-backed** | Calls a model to extract structured stories with Gherkin, events, and constraints from raw text. Returns validated `List[UserStory]`. |
| `map_event_triggers(story_id: str) -> List[EventTrigger]` | **LLM-backed** | Analyzes a specific story's Gherkin to identify all domain events (e.g., PaymentSubmitted, PaymentApproved). |

**Output**: `List[UserStory]` — each with id, title, gherkin, event_triggers.

### 3.2 Backend Go Engineer Agent

**System Prompt**: Lead Go Backend Engineer. Hexagonal Architecture, gRPC, CloudEvents, NATS/Kafka, OTel, Prometheus, Go 1.24+.

**Tools**:

| Tool | Type | Behavior |
|------|------|----------|
| `scaffold_go_service(service_name: str, bounded_context: str) -> Dict[str, str]` | **Template-based** | Returns a complete Go project skeleton: `cmd/server/main.go`, `internal/domain/`, `internal/ports/`, `internal/adapters/`, `api/protobuf/service.proto`, `go.mod`, `Dockerfile`, `Makefile`. The LLM fills in domain-specific logic in its main response. |
| `generate_dockerfile(service_name: str, port: int) -> str` | **Template-based** | Returns multi-stage Dockerfile: `golang:1.24-alpine` build stage, `alpine:3.21` runtime, non-root user, health probes. |

**Scaffold directory structure**:

```
{service_name}/
├── cmd/server/
│   └── main.go              # HTTP/gRPC server entry, health probes, OTel init
├── internal/
│   ├── domain/
│   │   ├── {service}.go     # Core domain entities + errors
│   │   └── events.go        # Domain event definitions
│   ├── ports/
│   │   ├── repository.go    # Repository interface
│   │   └── events.go        # Event publisher interface
│   └── adapters/
│       ├── repository/      # Concrete repository (Postgres/in-memory)
│       ├── eventbus/         # NATS/Kafka adapter with idempotent consumer
│       └── handlers/         # gRPC handlers with OTel spans
├── api/protobuf/
│   └── {service}.proto      # gRPC service definition, semver annotated
├── go.mod                    # Module, Go 1.24, deps (client-go, otel, gRPC)
├── Dockerfile                # Multi-stage build
└── Makefile                  # build, test, lint, proto-gen targets
```

**Output**: `Artifact` with `files` mapping scaffold + LLM-generated domain logic.

### 3.3 Frontend Engineer Agent

**System Prompt**: Lead Frontend Engineer. Vue 3 Composition API, TSX, WCAG 2.1, Atomic Design, WebSocket/SSE, `data-testid` on every element.

**Tools**:

| Tool | Type | Behavior |
|------|------|----------|
| `create_component(component_name: str, requirements: str, test_id: str) -> str` | **LLM-backed** | Calls model to generate a production-ready Vue 3 TSX component with: WCAG 2.1 ARIA labels, `data-testid` attribute, TypeScript props interface, Tailwind/CSS module styling, proper event handler typing. |

**Output**: `Artifact` with `files` mapping component paths to TSX code.

### 3.4 Test Engineer Agent

**System Prompt**: QA Automation Agent. BDD, Playwright, Gherkin validation, async event assertions, 100% coverage mapped to BA triggers.

**Tools**:

| Tool | Type | Behavior |
|------|------|----------|
| `generate_test_suite(user_story_gherkin: str, components: List[str]) -> str` | **LLM-backed** | Converts Gherkin to Playwright TypeScript tests: `data-testid` selectors, async/await, page object pattern, backend event validation. |

**Output**: `Artifact` with `files` mapping test spec paths to Playwright code.

### 3.5 SRE (Infrastructure) Agent

**System Prompt**: Senior SRE. Immutable infrastructure, GitOps, Terraform/OpenTofu, Crossplane, multi-cloud K8s, NetworkPolicies, HPA, secret rotation.

**Tools**:

| Tool | Type | Behavior |
|------|------|----------|
| `provision_k8s_cluster(provider: str, region: str, cluster_name: str) -> Dict[str, str]` | **Template-based** | Returns Terraform/OpenTofu HCL: VPC, EKS/GKE cluster, node groups, IAM roles, OIDC provider, IRSA. |
| `apply_helm_chart(service_name: str, image: str, port: int) -> Dict[str, str]` | **Template-based** | Returns Helm chart: `Chart.yaml`, `values.yaml`, `templates/` with Deployment, Service, Ingress, NetworkPolicy, HPA, ServiceMonitor, PDB. |

**Terraform output structure**:

```
terraform/
├── main.tf           # Provider + EKS/GKE cluster module
├── vpc.tf            # VPC + subnets + NAT
├── iam.tf            # IAM roles + OIDC + IRSA
├── outputs.tf        # Cluster endpoint, kubeconfig
└── variables.tf      # Region, cluster_name, instance types
```

**Helm chart structure**:

```
helm/{service_name}/
├── Chart.yaml
├── values.yaml            # Image tag, replicas, resources, env vars
└── templates/
    ├── deployment.yaml    # Probes, resource limits, anti-affinity
    ├── service.yaml       # ClusterIP, ports
    ├── ingress.yaml       # TLS, host
    ├── hpa.yaml           # CPU/memory targets
    ├── servicemonitor.yaml # Prometheus operator
    ├── networkpolicy.yaml # Zero-trust, explicit egress/ingress
    └── pdb.yaml           # Pod disruption budget
```

**Output**: `Artifact` with `files` mapping terraform/helm paths to HCL/YAML.

### 3.6 Board of Review Agent

**System Prompt**: Final governance layer. QSA-style assessment. Zero-Trust, mTLS, no hardcoded secrets, architecture matches event-driven blueprint, no 'Destroy' in Terraform.

**Output**: `ReviewResult` with:

```python
class ReviewResult(BaseModel):
    approved: bool
    feedback: List[str]
    security_score: int = Field(ge=0, le=100)
    risk_level: RiskLevel  # LOW | MEDIUM | HIGH | CRITICAL
```

No tools needed — the LLM analyzes all artifacts passed in the prompt and returns a structured assessment.

---

## 4. Pipeline Orchestration

### Flow Diagram

```
                          ┌──────────────────┐
                          │  User Request     │
                          │  (raw text)       │
                          └────────┬─────────┘
                                   │
                          ┌────────▼─────────┐
                          │  OpenClaw         │
                          │  (Orchestrator)   │
                          │  • Reads context  │
                          │  • Routes agents  │
                          │  • Gates output   │
                          └────────┬─────────┘
                                   │
                          ┌────────▼─────────┐
                          │  BA Agent         │
                          │  (user stories)   │
                          └────────┬─────────┘
                                   │ List[UserStory]
                                   │
                    ┌──────────────┼──────────────┐
                    │              │              │
              ┌─────▼─────┐  ┌─────▼─────┐  ┌─────▼─────┐
              │ Story 1   │  │ Story 2   │  │ Story N   │
              └─────┬─────┘  └─────┬─────┘  └─────┬─────┘
                    │              │              │
         ┌──────────┼──┐    ┌─────┼──────┐  ┌─────┼──────┐
    ┌────▼────┐┌────▼───┐│    │     │      │  │     │      │
    │ Backend ││Frontend││    │     │      │  │     │      │
    └────┬────┘└────┬───┘│    │     │      │  │     │      │
         │          │    │    │     │      │  │     │      │
    ┌────▼──────────▼────┘    │     │      │  │     │      │
    │    Test Agent            │     │      │  │     │      │
    └────┬─────────────────────┘     │      │  │     │      │
         │                           │      │  │     │      │
         └───────────────────────────┼──────┼──┼─────┼──────┘
                                     │      │  │     │
                            ┌────────▼──────▼──▼─────▼──────┐
                            │  SRE Agent (one shot)         │
                            └────────┬──────────────────────┘
                                     │
                            ┌────────▼──────────────────────┐
                            │  Review Agent                 │
                            │  (evaluates ALL artifacts)    │
                            └────────┬──────────────────────┘
                                     │
                        ┌────────────┴────────────┐
                        │                         │
                   Approved                   Rejected
                        │                         │
                 ┌──────▼──────┐           ┌──────▼──────┐
                 │ Artifact    │           │ Log feedback │
                 │ Writer      │           │ Retry?       │
                 │ (disk I/O)  │           └─────────────┘
                 └─────────────┘
```

### OpenClaw Orchestration Pattern

OpenClaw does not run `main.py` as a black box. Instead, it orchestrates each step:

```
OpenClaw reads context:
  1. Loads Implementation Plan.md → understands pipeline design
  2. Loads Agent Specs → understands each agent's role, prompt, tools
  3. Loads src/models/core.py → understands data structures
  4. Loads src/agents/*.py → understands current implementation

OpenClaw executes pipeline (step by step):

  Step 1 — BA Agent
    OpenClaw invokes: ba_agent.run(f"Process requirements: {raw_text}")
    OpenClaw collects: List[UserStory]
    OpenClaw logs: N stories extracted with Gherkin + event triggers

  Step 2 — Backend + Frontend (fan-out per story)
    OpenClaw gathers tasks for all stories:
      for each story in stories:
        backend_task = backend_agent.run(f"Implement {story.id}")
        frontend_task = frontend_agent.run(f"Implement {story.id}")
    OpenClaw awaits all tasks in parallel via asyncio.gather
    OpenClaw collects: List[Artifact]

  Step 3 — Test (per story, after backend+frontend complete)
    OpenClaw gathers test tasks:
      for each story in stories:
        test_task = test_agent.run(f"Write tests for: {story.gherkin}")
    OpenClaw awaits all test tasks in parallel
    OpenClaw collects: List[Artifact]

  Step 4 — SRE (one shot)
    OpenClaw invokes: sre_agent.run("Provision infrastructure")
    OpenClaw collects: Artifact with terraform/helm files

  Step 5 — Review
    OpenClaw collects ALL artifacts from steps 2-4
    OpenClaw invokes: review_agent.run(f"Review: {summarize(artifacts)}")
    OpenClaw evaluates: ReviewResult

  Step 6 — Gate
    if approved:
      OpenClaw writes each artifact's files to disk via ArtifactWriter
    else:
      OpenClaw reports rejection with feedback and risk level
      optionally: OpenClaw triggers regeneration with review feedback injected
```

### Retry on Rejection (Orchestrated by OpenClaw)

```python
MAX_RETRIES = 2
for attempt in range(MAX_RETRIES):
    review = await review_agent.run(...)
    if review.data.approved:
        OpenClaw.write_artifacts(artifacts)
        break
    if attempt < MAX_RETRIES - 1:
        print(f"Attempt {attempt+1} rejected. Re-generating with feedback...")
        artifacts = await OpenClaw.re_generate(artifacts, review.data.feedback)
```

---

## 5. ArtifactWriter Module

```python
class ArtifactWriter:
    def __init__(self, base_dir: str):
        self.base_dir = Path(base_dir)

    def write(self, artifact: Artifact) -> None:
        for filepath, content in artifact.files.items():
            full_path = self.base_dir / artifact.agent_name / filepath
            full_path.parent.mkdir(parents=True, exist_ok=True)
            full_path.write_text(content)
```

- Creates directories as needed
- Preserves file tree structure from `Artifact.files` keys
- Namespace by `agent_name` ("backend/", "frontend/", "tests/", "infrastructure/")
- Skips writing if review is not approved

---

## 6. Configuration

```python
# src/config.py
import os

class AgentSettings:
    BA_MODEL = os.getenv("BA_MODEL", "gpt-4o-mini")
    BACKEND_MODEL = os.getenv("BACKEND_MODEL", "claude-sonnet-4-20250514")
    FRONTEND_MODEL = os.getenv("FRONTEND_MODEL", "gpt-4o")
    TEST_MODEL = os.getenv("TEST_MODEL", "gpt-4o-mini")
    SRE_MODEL = os.getenv("SRE_MODEL", "gemini-2.0-flash")
    REVIEW_MODEL = os.getenv("REVIEW_MODEL", "claude-sonnet-4-20250514")

    OUTPUT_DIR = os.getenv("OUTPUT_DIR", "./generated-app")
    MAX_RETRIES = int(os.getenv("MAX_RETRIES", "2"))
```

---

## 7. Implementation Sequence

| Step | File(s) | What | Why This Order |
|------|---------|------|----------------|
| 0 | Docs and specs | Write all agent spec `.md` files + this plan | OpenClaw reads these for context at startup |
| 1 | `src/config.py` (new) | Agent model config with env var overrides | Foundation — every agent needs it |
| 2 | `src/agents/*.py` | Wire model strings from config instead of hardcoded | Consistent model loading |
| 3 | `src/models/core.py` | Update `Artifact.files` to `Dict[str, str]` | Changes contract for all agents |
| 4 | `src/agents/ba.py` | Implement real BA tools (LLM extraction) | First agent in pipeline, unlocks downstream |
| 5 | `src/agents/backend.py` | Implement scaffold + Dockerfile tools (templates) | Core output — Go code generation |
| 6 | `src/agents/frontend.py` | Implement component generation (LLM) | Can be built in parallel with step 5 |
| 7 | `src/agents/test_eng.py` | Implement Gherkin→Playwright (LLM) | Depends on BA + Frontend |
| 8 | `src/agents/sre.py` | Implement Terraform + Helm tools (templates) | Can be built in parallel with step 6 |
| 9 | `src/writer.py` (new) | ArtifactWriter class | Small standalone module |
| 10 | `main.py` | Rewrite pipeline with parallelism + review gate | Ties everything together last |

Steps 5 and 6 can be done in parallel. Steps 7 and 8 can be done in parallel.

### Context Files OpenClaw Reads at Startup

When OpenClaw begins orchestrating, it loads:

1. **Agent spec documents** — `docs/Agent Spec_*.md` (6 files) — for role definitions, system prompts, tools, and output expectations
2. **Implementation Plan** — `docs/Implementation Plan.md` — for pipeline design, model assignments, and orchestration pattern
3. **Source code** — `src/config.py`, `src/models/core.py`, `src/agents/*.py`, `main.py` — for current implementation state
4. **Data models** — `src/models/core.py` — for understanding `Artifact`, `UserStory`, `ReviewResult` structures

This context enables OpenClaw to make informed decisions about which agents to run, in what order, with what parameters, and how to evaluate results.
