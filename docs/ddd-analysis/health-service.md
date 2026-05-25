# Health Service — DDD Analysis

## Bounded Contexts

| Context Name | Ubiquitous Language | Integration Pattern |
|---|---|---|
| **HealthCheck** | health probe, liveness, readiness, endpoint, status payload, orchestrator | **Shared Kernel** (single service, no external context yet) |

Since this is a single-endpoint microservice, the HealthCheck context owns everything. No anti-corruption layers or customer-supplier patterns are needed today.

## User Stories

| ID | Title | Gherkin | Events |
|---|---|---|---|
| HEALTH-01 | Health endpoint returning 200 | Given the HTTP service is running; When GET /healthz; Then 200, body {"status":"ok"}, Content-Type application/json | `health.CheckPerformed` |

## Event Triggers

| Event Name | Owner | Consumers | Payload Schema (sketch) |
|---|---|---|---|
| `health.CheckPerformed` | HealthCheck | Monitoring/Alerting, Orchestrator (e.g. K8s liveness probe) | `{ httpMethod, path, responseStatusCode, responseBody, responseContentType, timestamp }` |

## Multi-Cloud / Data Residency Constraints

- **None applicable.** The /healthz endpoint carries no user data, PII, or business payload. It is stateless and can be deployed identically across any cloud region without regulatory concern.
