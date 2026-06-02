

# ADR-004: Incident Domain Model Schema & State Machine

**Status:** Proposed  
**Date:** 2025-01-17  
**Affected Agents:** Backend Engineer, Database Engineer, SRE/DevOps  

---

## Context

GITOPS-01 (Automated Incident Response) needs a formal incident domain model that defines how incidents are recorded, how their state changes over time, and how external consumers (like GITOPS-01) hook into the lifecycle.

This ADR defines:
1. The **Incident aggregate** schema and supporting types
2. The **state machine** governing valid transitions
3. The **persistence layer** approach (hexagonal repository)
4. The **GITOPS-01 hook point** — how the remediation automation plugs in

### Domain vocabulary

| Term | Definition |
|---|---|
| **Incident** | A detected anomaly or failure requiring automated or manual remediation |
| **Severity** | Impact classification (critical, high, medium, low) |
| **Status** | Current stage in the incident lifecycle |
| **Runbook** | A predefined remediation procedure (may contain multiple steps) |
| **Remediation** | The active resolution attempt (1:1 with incident during active remediation) |
| **Step** | A single action within a runbook (e.g., "Roll back deployment", "Scale up replicas") |
| **Classification** | The process of determining severity, affected service, and appropriate runbook |

---

## Decision

### 1. Incident Record Schema

```sql
-- Core incident aggregate
CREATE TABLE incidents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title           TEXT NOT NULL,
    description     TEXT NOT NULL DEFAULT '',
    severity        TEXT NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low')),
    status          TEXT NOT NULL DEFAULT 'detected'
                    CHECK (status IN ('detected','classifying','classified','remediating','resolved','escalated')),
    source          TEXT NOT NULL,                     -- e.g., 'prometheus', 'cloud-monitoring', 'manual'
    source_id       TEXT NOT NULL DEFAULT '',           -- external alert ID (e.g., alertmanager fingerprint)
    service         TEXT NOT NULL,                     -- affected service/aggregate name
    resource_id     TEXT NOT NULL DEFAULT '',           -- specific resource identifier (e.g., deployment name)
    runbook_id      UUID,                              -- assigned runbook (set at classification)
    metadata        JSONB NOT NULL DEFAULT '{}',       -- extensible attributes
    detected_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    classified_at   TIMESTAMPTZ,                       -- set when status → classified
    remediating_at  TIMESTAMPTZ,                       -- set when status → remediating
    resolved_at     TIMESTAMPTZ,                       -- set when status → resolved
    escalated_at    TIMESTAMPTZ,                       -- set when status → escalated
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_incidents_status ON incidents (status);
CREATE INDEX idx_incidents_severity ON incidents (severity);
CREATE INDEX idx_incidents_service ON incidents (service);
CREATE INDEX idx_incidents_source_id ON incidents (source_id);
CREATE INDEX idx_incidents_created_at ON incidents (created_at DESC);

-- Runbook definitions (reference data)
CREATE TABLE runbooks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    description     TEXT NOT NULL DEFAULT '',
    trigger_type    TEXT NOT NULL,                     -- e.g., 'severity:critical+service:api-gateway'
    steps           JSONB NOT NULL DEFAULT '[]',       -- ordered array of step definitions
    owner_team      TEXT NOT NULL DEFAULT '',
    version         INTEGER NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Remediation tracking (1:1 with incident during remediation)
CREATE TABLE incident_remediations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    incident_id     UUID NOT NULL REFERENCES incidents(id),
    runbook_id      UUID NOT NULL REFERENCES runbooks(id),
    pr_url          TEXT,                              -- GitOps PR URL
    pr_status       TEXT NOT NULL DEFAULT 'pending'
                    CHECK (pr_status IN ('pending','in_progress','ci_passed','ci_failed','merged','abandoned')),
    current_step    INTEGER NOT NULL DEFAULT 0,        -- index into runbook.steps
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_remediations_incident ON incident_remediations (incident_id);
CREATE INDEX idx_remediations_pr_status ON incident_remediations (pr_status);
```

### 2. State Machine

```
                    ┌──────────────────────────────────────────────────┐
                    │                                                  │
                    ▼                                                  │
              ┌──────────┐     ┌──────────────┐     ┌────────────┐    │
    Alert ──▶ │ detected │────▶│ classifying  │────▶│ classified │    │
              └──────────┘     └──────────────┘     └─────┬──────┘    │
                                                          │           │
                                          ┌───────────────┘           │
                                          ▼                           │
                                    ┌────────────┐                    │
               ┌────────────────────│ remediating│────────────────────┘
               │                    └─────┬──────┘
               ▼                          ▼
         ┌──────────┐              ┌───────────┐
         │ resolved │              │ escalated │
         └──────────┘              └───────────┘
```

**Transition Rules:**

| From | To | Trigger | By |
|---|---|---|---|
| `detected` | `classifying` | Alert ingested, classification begins | Incident Service (auto/manual) |
| `classifying` | `classified` | Severity + affected service + runbook determined | Classification Engine |
| `classified` | `remediating` | Runbook assigned + GITOPS-01 PR creation initiated | **GITOPS-01 Hook** |
| `remediating` | `resolved` | PR merged, fix verified, alert resolved | GITOPS-01 or Manual Verification |
| `remediating` | `escalated` | SLO breach during remediation / manual decision | Escalation Timer or Human |
| `resolved` | *(terminal)* | — | — |
| `escalated` | *(terminal)* | — | — |
| *(any)* | `escalated` | On escalation timeout or human override | Escalation Policy |

**Invalid transitions** (MUST be rejected at the application layer):
- `detected` → `remediating` (skip classification)
- `resolved` → `remediating` (a resolved incident must be re-detected as a new incident)
- `escalated` → `remediating` (escalation is terminal for the automation path)

### 3. Persistence Layer Approach

Following the hexagonal architecture pattern established in ADR-002:

```
┌─────────────────────────────────────────────────────┐
│                    Domain Layer                       │
│  ┌─────────────┐  ┌──────────────────┐              │
│  │ Incident    │  │ IncidentService   │              │
│  │ Aggregate   │  │   (Use Cases)    │              │
│  └─────────────┘  └────────┬─────────┘              │
│                            │                         │
│  ┌─────────────────────────▼──────────────────────┐  │
│  │          IncidentRepository (Port)              │  │
│  │   Save(incident) Load(id) List(filter)         │  │
│  └─────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────┤
│                   Adapter Layer                       │
│  ┌─────────────────────────────────────────────────┐  │
│  │     PgIncidentRepository (Adapter)               │  │
│  │   - SQL queries / sqlx or pgx                   │  │
│  │   - Transactional outbox write                   │  │
│  │   - Status transition validation                 │  │
│  └─────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**Key principles:**
- **Repository is the ONLY persistence abstraction** — services never touch SQL directly
- **Constructor-based DI** — `NewIncidentService(repo IncidentRepository, publisher EventPublisher)` — no global state
- **Status transitions** are enforced in the domain aggregate, not in SQL CHECK constraints (to allow future state additions without migrations)
- **All writes go through a single DB transaction** that includes both domain data and outbox entry (see ADR-003)

### 4. GITOPS-01 Hook Point

GITOPS-01 enters the incident lifecycle at the **classified** → **remediating** transition.

**Trigger Flow:**

```
1. Incident reaches "classified" status
   └── runbook_id is non-null
   └── incident.Classified event published to Pub/Sub (via outbox)

2. GITOPS-01 subscriber receives incident.Classified event
   └── Extracts incident_id, runbook_id, severity, service
   └── Looks up runbook steps from runbooks table

3. GITOPS-01 creates a GitOps PR
   └── Creates branch, applies runbook changes to IaC repo
   └── Creates/updates incident_remediations row
   └── Publishes gitops.RemediationPRCreated event

4. GITOPS-01 transitions incident status to "remediating"
   └── Calls IncidentService.TransitionToRemediating(incidentID, remediationID)
   └── Updates incident.status = 'remediating', incident.remediating_at = NOW()
   └── Publishes incident.Remediating event via outbox

5. GITOPS-01 monitors CI status
   └── Publishes gitops.CICheckCompleted on CI result

6. On PR merge:
   └── Publishes gitops.PullRequestStatusPublished
   └── Calls IncidentService.TransitionToResolved(incidentID)
```

**GITOPS-01 consumes:**
- `incident.classified` — (trigger to start remediation)
- `incident.resolved` — (for cleanup / post-mortem)
- `incident.escalated` — (for rollback / abort)

**GITOPS-01 emits:**
- `gitops.remediation_pr_created`
- `gitops.ci_check_completed`
- `gitops.pull_request_status_published`

### 5. CloudEvents Schemas

```jsonc
// incident.classified
{
  "specversion": "1.0",
  "type": "incident.classified",
  "source": "//incident-service",
  "id": "uuid-v7",
  "time": "2025-01-17T10:00:00Z",
  "datacontenttype": "application/json",
  "data": {
    "incident_id": "uuid",
    "severity": "critical",
    "service": "api-gateway",
    "runbook_id": "uuid",
    "runbook_name": "rollback-canary-deploy",
    "classification_summary": "5xx errors > 1% on api-gateway canary"
  }
}

// gitops.remediation_pr_created
{
  "specversion": "1.0",
  "type": "gitops.remediation_pr_created",
  "source": "//gitops-01",
  "id": "uuid-v7",
  "time": "2025-01-17T10:01:00Z",
  "datacontenttype": "application/json",
  "data": {
    "incident_id": "uuid",
    "remediation_id": "uuid",
    "pr_url": "https://github.com/org/repo/pull/42",
    "pr_branch": "remediation/incident-abc-123",
    "runbook_steps_applied": ["rollback-canary-v2", "scale-up-read-replicas"]
  }
}

// gitops.ci_check_completed
{
  "specversion": "1.0",
  "type": "gitops.ci_check_completed",
  "source": "//gitops-01",
  "id": "uuid-v7",
  "time": "2025-01-17T10:15:00Z",
  "datacontenttype": "application/json",
  "data": {
    "incident_id": "uuid",
    "remediation_id": "uuid",
    "pr_url": "https://github.com/org/repo/pull/42",
    "ci_status": "passed | failed",
    "ci_run_url": "https://ci.example.com/runs/789",
    "check_duration_seconds": 840
  }
}

// gitops.pull_request_status_published
{
  "specversion": "1.0",
  "type": "gitops.pull_request_status_published",
  "source": "//gitops-01",
  "id": "uuid-v7",
  "time": "2025-01-17T10:20:00Z",
  "datacontenttype": "application/json",
  "data": {
    "incident_id": "uuid",
    "remediation_id": "uuid",
    "pr_url": "https://github.com/org/repo/pull/42",
    "pr_status": "merged | abandoned",
    "merge_sha": "abc123def456"
  }
}
```

---

## Consequences

**Positive:**
- ✅ Clear state machine prevents invalid transitions at the domain level
- ✅ GITOPS-01 hook point is explicit — it's a single well-defined transition (classified → remediating)
- ✅ Schema supports both automated (GITOPS) and manual (human-in-the-loop) remediation paths
- ✅ Extensible via `metadata JSONB` and `runbook_id` for future enhancements
- ✅ Timestamped audit trail (`*_at` columns) for compliance and post-mortems
- ✅ Separation of concerns: Runbooks are reference data, remediations track active attempts

**Negative:**
- ❌ Status transitions duplicated in application code AND database (CHECK constraint only for valid values, not transitions — intentional for flexibility)
- ❌ `incident_remediations` table only supports one active remediation per incident (covers Phase 1; multi-attempt can be added later)
- ❌ No versioning/optimistic locking on incidents yet (can be added with `version INTEGER` column in Phase 2 if concurrent updates become an issue)

**Risks & Mitigations:**
- **Risk:** Stale incidents in `detected` or `classifying` status → **Mitigation:** Cloud Scheduler job that escalates incidents older than 15m in non-terminal states
- **Risk:** Runbook assigned but GITOPS-01 fails to create PR → **Mitigation:** `incident_remediations.pr_status` tracks failure; retry logic with exponential backoff; fallback to human escalation
- **Risk:** Concurrent state transitions race condition → **Mitigation:** Use `UPDATE ... WHERE status = 'classified'` conditional update; if 0 rows affected, the transition is rejected

---

## Architectural Constraints

The following constraints are imposed on downstream agents:

1. **Affected: Backend Engineer** — MUST implement the `IncidentRepository` port with all CRUD operations. MUST enforce state transitions in the domain aggregate (not in the handler). MUST use constructor-based DI (`NewIncidentService(repo, publisher)`). MUST integrate the transactional outbox (see ADR-003) into every repository write method.

2. **Affected: Database Engineer** — MUST create the three tables (`incidents`, `runbooks`, `incident_remediations`) with the exact schema above. MUST add the `idx_outbox_unpublished` index as defined in ADR-003. MUST create migration files for both up and down.

3. **Affected: SRE/DevOps** — MUST configure the Pub/Sub subscription for GITOPS-01 to filter on `incident.classified` events. MUST ensure GITOPS-01's service account has `roles/pubsub.subscriber` and GitHub write access for PR creation.

4. **Affected: GITOPS-01 implementation** — MUST consume `incident.classified` events (where `runbook_id` is non-null). MUST call `IncidentService.TransitionToRemediating()` after successful PR creation. MUST NOT attempt to modify incidents in any other status.

---

## Future Considerations (Post-Phase 1)

- **Optimistic locking** — Add `version INTEGER` to incidents for concurrent update safety
- **Multi-step remediation** — Support runbooks with conditional branching between steps
- **Post-mortem integration** — Attach post-mortem documents to `resolved` incidents
- **Analytics materialization** — Stream resolved incidents to BigQuery for trend analysis
- **Incident correlation** — Group related incidents under a parent incident (e.g., cascading failures)

---

## References

- ADR-002: Notification Service Architecture (hexagonal pattern, CloudEvents)
- ADR-003: GITOPS-01 Eventing Infrastructure (transactional outbox + Pub/Sub)
- [CloudEvents 1.0 Specification](https://github.com/cloudevents/spec)
