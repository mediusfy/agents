

# Rufkis — Requirements Analysis

## ⚠️ Ambiguity Flags (Blocking Clarifications Needed)

| # | Ambiguity | Impact | Suggested Resolution |
|---|-----------|--------|---------------------|
| 1 | **Target K8s Distribution** — EKS, GKE, AKS, OpenShift, vanilla? | Affects API compatibility, auth integration | Clarify target cloud(s) |
| 2 | **Multi-cloud / Data Residency** — Not mentioned at all | Potential compliance failure for regulated data | Define regional constraints |
| 3 | **User Roles & Permissions** — Not defined | Cannot design authZ model | Define role hierarchy (admin, viewer, operator) |
| 4 | **Scale** — How many clusters? Nodes? Namespaces? | Affects API pagination, real-time streaming, DB choice | Define SLOs at P50/P95/P99 |
| 5 | **Read vs. Write** — Is this read-only monitoring or full K8s CRUD? | Entirely different risk profiles | Define operation scope |
| 6 | **Monday.com feature depth** — Boards only? Automations? Dashboards? Integrations? | Architecture complexity varies 10x | Specify which monday.com paradigms to replicate |
| 7 | **Authentication** — SSO? OIDC? K8s RBAC token? | Security architecture | Define IdP and auth flow |
| 8 | **Real-time requirements** — WebSockets? Polling? Server-sent events? | Backend cost model | Define max acceptable latency for state updates |
| 9 | **Persistence** — Event-sourced audit log or transient board state? | DB schema and bounded context design | Define data retention policy |
| 10 | **Alerting integration** — PagerDuty? Slack? Email? In-house? | Event trigger consumers | Define downstream notification targets |

## Assumptions (for initial decomposition)
Pending clarification above, I assume:
- Multi-cloud (AWS EKS + GCP GKE) with US/EU regions
- OIDC-based auth (Okta/Azure AD)
- Full read + write (deploy, scale, delete) with confirmation gates
- Real-time WebSocket push for board updates
- Primary monday.com features: Board view (table), Kanban view, Timeline (Gantt), Dashboard widgets
- Kubernetes-native audit events integrated
