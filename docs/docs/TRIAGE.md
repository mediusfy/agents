# Autonomous Agent Triage Theme

> **Stories**: TRIAGE-01 · TRIAGE-02 · TRIAGE-03 · TRIAGE-04  
> **Priority**: P0 (3 stories) + P1 (1 story)  
> **Phase**: Phase 1 — Foundation & Core Automation

---

## Theme Overview

The Autonomous Agent Triage theme provides **AI-powered incident management** that classifies, diagnoses, heals, and escalates incidents autonomously. The triage agent uses Large Language Models combined with heuristics to achieve high-accuracy classification, root cause analysis, and runbook matching.

---

## Story Flow

```
Alert from Monitoring Source
(Prometheus, Datadog, Grafana, CloudWatch, Webhook)
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    TRIAGE-01: Classification                            │
│                                                                         │
│  1. Parse alert payload (title, description, labels, raw data)          │
│  2. LLM classifies severity (P0-P4) with confidence score               │
│  3. Assign ownership based on service ownership mapping                 │
│  4. Suggest matching runbooks                                           │
│  5. Return classification result                                        │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
               ┌─────────────────┴─────────────────┐
               ▼                                   ▼
┌──────────────────────────────┐     ┌──────────────────────────────────┐
│  TRIAGE-02: RCA Analysis     │     │  TRIAGE-04: Escalation Check     │
│                              │     │                                  │
│  1. Collect context:         │     │  Is it P0?                       │
│     - Logs (last 60 min)     │     │  Self-healing failed?            │
│     - Metrics (promql)       │     │  Low confidence (<70%)?          │
│     - Traces (OTel)          │     │                                  │
│     - Recent Git changes     │     │  If YES → Escalate               │
│  2. LLM analyzes context     │     │  If NO → Self-healing            │
│  3. Ranked root causes       │     │                                  │
└──────────────────────────────┘     └──────────┬───────────────────────┘
                                                │
                     ┌──────────────────────────┘
                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    TRIAGE-03: Self-Healing                              │
│                                                                         │
│  1. Match incident to runbook with confidence scoring                   │
│  2. If confidence > 90%:                                                │
│     a. Execute dry-run (validate all steps)                             │
│     b. Create GitOps remediation PR                                    │
│     c. Report results to incident timeline                              │
│  3. If dry-run fails or confidence < 90%: escalate                      │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Story Details

### TRIAGE-01: AI-Powered Incident Triage

**Classification Model Architecture:**

```
Alert Input
    │
    ├── Feature Extraction
    │   ├── Title + Description (NLP features)
    │   ├── Raw Payload (structured data)
    │   ├── Labels & Metadata
    │   └── Historical similarity search
    │
    ├── LLM Classifier (Primary)
    │   ├── Severity: P0-P4 with rationale
    │   └── Confidence score (0-1)
    │
    ├── Heuristic Classifier (Fallback)
    │   ├── Pattern-based rules
    │   ├── Threshold comparisons
    │   └── Used when LLM confidence < threshold
    │
    └── Ensemble Output
        ├── Severity: P0-P4
        ├── Confidence: 0-1
        ├── Rationale text
        └── Alternative classifications
```

**Severity Definitions:**

| Severity | Definition | Response Time | Example |
|----------|------------|---------------|---------|
| **P0** | Critical service outage, customer impact | Immediate (< 15 min) | Payment service down |
| **P1** | Major functionality degraded | < 1 hour | High error rate > 5% |
| **P2** | Partial degradation | < 4 hours | Latency increase < 500ms |
| **P3** | Minor issue, workaround available | < 24 hours | UI cosmetic bug |
| **P4** | Informational | Best effort | Disk usage > 70% |

**Acceptance Criteria:**
- ✅ Ingests alerts from Prometheus, Datadog, Grafana, CloudWatch, generic webhooks
- ✅ Severity classification with confidence score (P0-P4)
- ✅ Owner assignment based on service ownership mapping and on-call schedule
- ✅ Classification accuracy >= 90% for P0/P1
- ✅ API returns classification result with confidence, rationale, and alternatives

---

### TRIAGE-02: Automated Root Cause Analysis

**Context Collection:**

```python
# Simplified RCA context collection
class RCAContextCollector:
    def collect(self, incident, time_range_minutes=60):
        end_time = incident.timestamp
        start_time = end_time - timedelta(minutes=time_range_minutes)
        
        return {
            'logs': self.log_service.query(
                service=incident.service,
                start=start_time,
                end=end_time,
                severity=['error', 'critical']
            ),
            'metrics': self.metrics_service.query_range(
                queries=[
                    f'{incident.service}_error_rate',
                    f'{incident.service}_latency_p99',
                    f'{incident.service}_request_count',
                    'system_cpu_usage',
                    'system_memory_usage'
                ],
                start=start_time,
                end=end_time
            ),
            'traces': self.trace_service.query(
                service=incident.service,
                start=start_time,
                end=end_time,
                error=True
            ),
            'changes': self.git_service.query_changes(
                paths=[f'services/{incident.service}/**'],
                start=start_time - timedelta(days=1),
                end=end_time
            )
        }
```

**RCA Output Format:**

```json
{
  "rank": 1,
  "title": "Database connection pool exhaustion",
  "confidence": 0.88,
  "evidence": [
    {
      "source": "logs",
      "snippet": "ERROR: could not acquire connection from pool - pool exhausted",
      "timestamp": "2026-06-03T02:20:15Z",
      "severity": "error"
    },
    {
      "source": "metrics",
      "snippet": "db_connections_active: 200 (threshold: 180)",
      "timestamp": "2026-06-03T02:20:00Z",
      "severity": "critical"
    },
    {
      "source": "git_changes",
      "snippet": "commit a1b2c3d: Connection leak introduced in pool release logic",
      "timestamp": "2026-06-02T15:00:00Z",
      "severity": "high"
    }
  ],
  "suggested_remediation": "Increase max pool size to 300, rollback recent config change",
  "related_runbooks": ["rb-database-connection-pool"]
}
```

**Acceptance Criteria:**
- ✅ RCA engine consumes logs, metrics, traces, and recent change events
- ✅ Produces ranked list of root causes with evidence snippets and confidence scores
- ✅ Integrates with OpenTelemetry for trace analysis
- ✅ Integrates with Git history for recent change correlation
- ✅ RCA results stored with incident record for post-mortem analysis

---

### TRIAGE-03: Self-Healing Runbook Execution

**Runbook Matching Algorithm:**

```python
def match_runbook(incident, runbooks):
    """Match incident to runbook using embedding similarity + rules."""
    best_match = None
    best_confidence = 0
    
    for runbook in runbooks:
        # Rule-based matching (service, severity, symptoms)
        rule_score = rule_based_match(incident, runbook)
        
        # Embedding similarity (semantic matching)
        embedding_score = embedding_similarity(
            incident.description,
            runbook.description + ' '.join(runbook.trigger_conditions)
        )
        
        # Combined confidence
        confidence = 0.6 * rule_score + 0.4 * embedding_score
        
        if confidence > best_confidence and confidence > 0.7:
            best_match = runbook
            best_confidence = confidence
    
    return best_match, best_confidence
```

**Acceptance Criteria:**
- ✅ Self-healing agent matches incidents to runbooks with confidence scoring
- ✅ Automated GitOps PR creation for matched runbooks (confidence > 90%)
- ✅ Dry-run execution before actual remediation
- ✅ Results reported back to incident timeline
- ✅ Agent provides rollback plan in PR description

---

### TRIAGE-04: Escalation Logic with Human-in-the-Loop

**Escalation Policy Configuration:**

```yaml
# escalation-policy.yaml
tiers:
  - level: 1
    name: "Primary On-Call Engineer"
    on_call_schedule: "sre-primary"
    timeout_minutes: 15
    notification_channels: [pagerduty, slack]
    
  - level: 2
    name: "Team Lead"
    on_call_schedule: "sre-leads"
    timeout_minutes: 10
    notification_channels: [pagerduty, slack, sms]
    
  - level: 3
    name: "SRE Manager"
    on_call_schedule: "sre-managers"
    timeout_minutes: 5
    notification_channels: [pagerduty, phone]

rules:
  - id: "p0-escalation"
    condition: "incident.severity == 'P0'"
    target_tier: 1
    
  - id: "self-healing-failure"
    condition: "self_healing.status == 'failed'"
    target_tier: 1
    
  - id: "low-confidence"
    condition: "classification.confidence < 0.7"
    target_tier: 1
    
  - id: "tier-1-timeout"
    condition: "escalation.tier == 1 && escalation.status == 'timeout'"
    target_tier: 2
    
  - id: "tier-2-timeout"
    condition: "escalation.tier == 2 && escalation.status == 'timeout'"
    target_tier: 3
```

**Acceptance Criteria:**
- ✅ Escalation policy is configurable as code
- ✅ Escalation triggers: P0 incidents, self-healing failure, classification confidence < 70%
- ✅ On-call engineer is paged with full incident context and suggested steps
- ✅ Multi-tier escalation: engineer → team lead → SRE manager
- ✅ Escalation and response tracked in incident timeline

---

## API Endpoints Summary

| Method | Path | Story | Description |
|--------|------|-------|-------------|
| `POST` | `/triage/classify` | TRIAGE-01 | Classify an incident |
| `GET` | `/triage/classifications/{id}` | TRIAGE-01 | Get classification details |
| `POST` | `/triage/rca` | TRIAGE-02 | Trigger root cause analysis |
| `GET` | `/triage/rca/{incident_id}` | TRIAGE-02 | Get RCA results |
| `POST` | `/triage/self-healing/execute` | TRIAGE-03 | Execute self-healing |
| `GET` | `/triage/self-healing/status/{id}` | TRIAGE-03 | Get self-healing status |
| `POST` | `/triage/escalations` | TRIAGE-04 | Trigger escalation |
| `GET` | `/triage/escalations/{id}` | TRIAGE-04 | Get escalation status |
| `GET` | `/triage/escalations/policy` | TRIAGE-04 | Get escalation policy |
| `PUT` | `/triage/escalations/policy` | TRIAGE-04 | Update escalation policy |

---

## Implementation Tasks

| Task | Effort | Description |
|------|--------|-------------|
| TRIAGE-01-T1 | 3d | Alert ingestion pipeline |
| TRIAGE-01-T2 | 4d | LLM-based severity classifier |
| TRIAGE-01-T3 | 2d | Service ownership mapping |
| TRIAGE-02-T1 | 4d | Context collector service |
| TRIAGE-02-T2 | 4d | RCA analysis engine |
| TRIAGE-02-T3 | 2d | RCA storage and API |
| TRIAGE-03-T1 | 3d | Runbook matching engine |
| TRIAGE-03-T2 | 3d | Self-healing orchestrator |
| TRIAGE-03-T3 | 2d | Incident timeline integration |
| TRIAGE-04-T1 | 3d | Escalation policy engine |
| TRIAGE-04-T2 | 2d | Paging integration |
| TRIAGE-04-T3 | 2d | Multi-tier escalation + tracking |

**Total Effort: 34 days**
