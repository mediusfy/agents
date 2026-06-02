


# Rufkis — Multi-Cloud Constraints & Data Residency

## Architecture Constraints

### 1. Data Residency & Sovereignty
- **Cluster metadata** (workload states, events, diagnostics) **must** be stored regionally — a cluster hosted in `eu-central-1` cannot have its state persisted in `us-east-1`.
- **Cost data** from FinOps must respect cloud provider region boundaries. Cross-region cost aggregation is permitted only at the organizational account level, not at the workload level.
- **Agent audit logs** — MCP policy violations and agent actions are subject to the data residency of the cluster the agent operates on.

### 2. Network Latency Boundaries
- The **Wails desktop app** connects to each cluster's API server over Tailscale. Tailscale DERP relays introduce 30-80ms latency; direct connections are sub-10ms.
- **WebSocket connections** must be established per-cluster. A single WebSocket cannot aggregate multi-region clusters due to Tailscale routing requirements.
- **AI Diagnostics** — LLM inference requests from a cluster in `ap-southeast-1` should be routed to the nearest inference endpoint (e.g., AWS Bedrock in Singapore, not us-west-2).

### 3. Cloud Provider Lock-In Mitigation
- Cost ingestion uses an **Anti-Corruption Layer** to normalize AWS Cost Explorer, GCP Billing Export, and Azure Cost Management into a common `finops.CostRecord` schema.
- Cluster monitoring uses the **standard Kubernetes API** (no cloud-specific extensions). Cloud-managed K8s (EKS, GKE, AKS) are accessed identically.
- Biometric auth is platform-native (macOS LocalAuthentication, Windows Hello, Linux PAM via Tailscale identity) — abstracted behind the Identity ACL.

## Integration Patterns for Multi-Cloud

| Concern | Pattern | Rationale |
|---------|---------|-----------|
| Cost data ingestion | Anti-Corruption Layer | Each cloud provider has a different billing API/schema |
| Cluster connectivity | Tailscale mesh | Single identity plane across clouds; no public endpoints |
| Event streaming | Per-cluster WebSocket | Tailscale routing + data residency requires locality |
| Policy enforcement | OPA/Gatekeeper (in-cluster) | Decouples policy from cloud-specific IAM |
| GitOps repos | Cloud-agnostic Git provider | GitHub/GitLab/Bitbucket abstract cloud-specific CI/CD |
