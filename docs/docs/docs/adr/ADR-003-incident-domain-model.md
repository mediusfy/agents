# ADR-003: Incident Domain Model & State Machine

**Status:** Accepted  
**Date:** 2025-01-23  
**Context:** TRIAGE-03 (Self-Healing Runbook Execution), ADR-002 (Eventing Strategy)  
**Deciders:** CTO, Backend Engineer, SRE Engineer

---

## Context

The incident management platform needs a robust domain model for incidents that integrates with:
- A self-healing runbook execution engine (TRIAGE-03)
- Cross-context eventing (NATS JetStream via ADR-002)
- Persistence (PostgreSQL)
- Multi-classifier pipeline (ML-based + rule-based)

Incidents transition through distinct states, and at each transition, domain events must be emitted for downstream consumers (notifications, runbook executors, Cost anomaly correlators).

---

## Decision: Incident Aggregate

The Incident is a **DDD Aggregate** with the following properties:

### Aggregate Identity

```go
type IncidentID struct {
    value string // UUID v7 (time-sortable)
}
```

### Aggregate Fields

```go
type Incident struct {
    ID              IncidentID
    TenantID        TenantID        // multi-tenant partition key
    Classification  Classification  // severity, service, category
    State           IncidentState   // current state machine state
    RunbookRef      *RunbookRef     // optional: linked self-healing runbook
    Remediation     *Remediation    // execution details if remediating
    Escalation      *Escalation     // escalation info if escalated
    Timeline        []TimelineEntry // ordered, append-only log
    Metadata        map[string]string // flexible extensibility
    Tags            []string

    // Version for optimistic concurrency
    Version         int

    // Timestamps
    CreatedAt       time.Time
    UpdatedAt       time.Time
    ClassifiedAt    *time.Time
    RemediationStartedAt *time.Time
    ResolvedAt      *time.Time
    EscalatedAt     *time.Time
}
```

### Value Objects

```go
type Classification struct {
    Severity    Severity        // critical, high, medium, low
    ServiceName string          // service that triggered the incident
    Category    IncidentCategory // e.g., "latency", "error_budget", "cost_anomaly"
    Summary     string          // human-readable summary
    Detail      string          // markdown description
    Confidence  float64         // 0.0–1.0 classifier confidence score
    ClassifierID string         // which classifier made this determination
}

type Severity string // const: SeverityCritical, SeverityHigh, SeverityMedium, SeverityLow

type RunbookRef struct {
    RunbookID     string
    RunbookName   string
    Steps         []RunbookStep    // ordered execution steps
    TriggeredBy   string           // "auto" or user email
    TriggeredAt   time.Time
}

type RunbookStep struct {
    Order       int
    Name        string
    Action      ActionType        // "restart", "rollback", "scale_up", "run_script", etc.
    Target      string            // e.g., service name, deployment name
    Parameters  map[string]string
    Result      *StepResult
}

type StepResult struct {
    Status      StepStatus        // pending, running, success, failed, skipped
    Output      string
    StartedAt   *time.Time
    CompletedAt *time.Time
    Error       string
}

type Remediation struct {
    RunbookID     string
    AllSteps      []RunbookStep
    OverallStatus RemediationStatus // running, succeeded, partial, failed
    StartedAt     time.Time
    CompletedAt   *time.Time
    CompletedBy   string            // "auto" or user email
}

type Escalation struct {
    Level       int               // 1, 2, 3
    AssignedTo  string            // user or team
    Reason      string
    EscalatedAt time.Time
    AckedAt     *time.Time
}

type TimelineEntry struct {
    Timestamp time.Time
    EventType string              // e.g., "classified", "remediation_started"
    Actor     string              // system or user
    Detail    string
}
```

---

## State Machine

The Incident state machine controls all valid transitions and enforces domain invariants.

### States

```
                  ┌──────────────────────────┐
                  │       CLASSIFIED         │
                  │  (initial state after    │
                  │   classification)        │
                  └────────────┬─────────────┘
                               │
                  ┌────────────▼─────────────┐
                  │       REMEDIATING        │
                  │  (runbook execution in   │
                  │   progress)              │
                  └────┬──────────────┬──────┘
                       │              │
              ┌────────▼───┐   ┌──────▼────────┐
              │  RESOLVED  │   │  ESCALATED     │
              │ (success)  │   │ (human needed) │
              └────────────┘   └───────┬────────┘
                                       │
                              ┌────────▼────────┐
                              │  RESOLVED (post │
                              │  human action)  │
                              └─────────────────┘
```

### State Definitions

| State | Description |
|---|---|
| `CLASSIFIED` | Incident has been analyzed and categorized. Default initial state. Runbook may be auto-assigned. |
| `REMEDIATING` | A self-healing runbook is actively executing remediation steps. |
| `RESOLVED` | Remediation completed successfully OR incident was manually resolved. Terminal state. |
| `ESCALATED` | Remediation failed or classification confidence was too low. Human intervention required. Can transition to RESOLVED on manual action. |

### Transition Rules

| From | To | Condition | Action |
|---|---|---|---|
| `*` | `CLASSIFIED` | Classification result received | Set `Classification`, `ClassifiedAt` |
| `CLASSIFIED` | `REMEDIATING` | Runbook auto-triggered (or operator initiated) | Create `RunbookRef`, set `RemediationStartedAt` |
| `REMEDIATING` | `RESOLVED` | All runbook steps completed successfully | Set `ResolvedAt`, `OverallStatus = succeeded` |
| `REMEDIATING` | `ESCALATED` | A step failed and no retry configured | Create `Escalation`, stop further steps |
| `REMEDIATING` | `ESCALATED` | Confidence < threshold (auto-escalation) | Create `Escalation` |
| `ESCALATED` | `RESOLVED` | Operator manually resolves | Set `ResolvedAt`, record operator info |
| `ESCALATED` | `REMEDIATING` | Operator retries auto-remediation | Resume from failed step or restart |

**Invariants enforced by the aggregate:**
1. Once `RESOLVED`, no further transitions (terminal state)
2. `ESCALATED → RESOLVED` requires a user actor, not system
3. `CLASSIFIED → REMEDIATING` requires a valid `RunbookRef`
4. All transitions must append to `Timeline`

### Transition Method

```go
func (i *Incident) TransitionToRemediating(runbook RunbookRef) error {
    if i.State != IncidentStateClassified {
        return fmt.Errorf("cannot transition from %s to REMEDIATING", i.State)
    }
    i.State = IncidentStateRemediating
    i.RunbookRef = &runbook
    now := time.Now()
    i.RemediationStartedAt = &now
    i.Version++
    i.UpdatedAt = now
    i.Timeline = append(i.Timeline, TimelineEntry{
        Timestamp: now,
        EventType: "remediation_started",
        Actor:     runbook.TriggeredBy,
        Detail:    fmt.Sprintf("Runbook %s triggered", runbook.RunbookName),
    })
    i.AddDomainEvent(RemediationStartedEvent{
        IncidentID: i.ID,
        Runbook:    runbook,
        Timestamp:  now,
    })
    return nil
}
```

---

## Domain Events

Each state transition emits a CloudEvents-compliant domain event (per ADR-002).

### Event Catalog

| Transition | Event Type | Payload Summary | Consumer(s) |
|---|---|---|---|
| → `CLASSIFIED` | `triage.IncidentClassified.v1` | `IncidentID, Classification, ClassifiedAt` | Runbook Matcher, Notification, FinOps |
| `CLASSIFIED → REMEDIATING` | `triage.RemediationStarted.v1` | `IncidentID, RunbookRef, StartedAt` | Runbook Executor, Notification |
| Step completed | `triage.RemediationStepCompleted.v1` | `IncidentID, StepOrder, StepResult` | Runbook Executor, Notification |
| Step failed | `triage.RemediationStepFailed.v1` | `IncidentID, StepOrder, Error` | Runbook Executor, Escalation Evaluator |
| `REMEDIATING → RESOLVED` | `triage.IncidentResolved.v1` | `IncidentID, FinalStatus, ResolvedAt` | FinOps (cost closure), Notification, SRE Dashboard |
| `REMEDIATING → ESCALATED` | `triage.IncidentEscalated.v1` | `IncidentID, Escalation, Reason` | On-call (PagerDuty/Opsgenie), Slack |
| `ESCALATED → RESOLVED` | `triage.IncidentResolved.v1` | `IncidentID, ResolvedBy, ResolvedAt` | same as above |

### CloudEvents Format

```json
{
    "specversion": "1.0",
    "id": "evt-001-f6a8b1c3...",
    "source": "/incidents/triage/v1",
    "type": "triage.IncidentClassified.v1",
    "time": "2025-01-23T14:30:00Z",
    "datacontenttype": "application/json",
    "data": {
        "incident_id": "inc-001-a1b2c3...",
        "tenant_id": "tenant-42",
        "classification": {
            "severity": "critical",
            "service": "payment-api",
            "category": "latency",
            "summary": "p99 latency > 2s for payment-api"
        },
        "classified_at": "2025-01-23T14:30:00Z"
    },
    "traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
}
```

---

## Persistence Layer Interface

The persistence layer follows the **Hexagonal (Ports & Adapters)** pattern.

### Repository Port

```go
package repository

type IncidentRepository interface {
    // Save saves the aggregate; uses version for optimistic concurrency.
    // Returns ErrConcurrencyConflict if version mismatch.
    Save(ctx context.Context, incident *Incident) error

    // Load reconstitutes the aggregate from events or snapshot.
    Load(ctx context.Context, id IncidentID) (*Incident, error)

    // ListByState queries incidents by current state.
    ListByState(ctx context.Context, state IncidentState, limit, offset int) ([]*Incident, error)

    // ListUnresolvedSince finds active incidents older than duration.
    ListUnresolvedSince(ctx context.Context, since time.Duration) ([]*Incident, error)
}
```

### Storage Schema (PostgreSQL)

```sql
-- Main aggregate table
CREATE TABLE incidents (
    id              UUID PRIMARY KEY,           -- UUID v7
    tenant_id       TEXT NOT NULL,
    version         INT NOT NULL DEFAULT 1,
    state           TEXT NOT NULL CHECK (state IN (
                        'classified', 'remediating', 'resolved', 'escalated'
                    )),
    classification  JSONB NOT NULL,             -- full Classification value object
    runbook_ref     JSONB,                      -- RunbookRef, nullable
    remediation     JSONB,                      -- Remediation, nullable
    escalation      JSONB,                      -- Escalation, nullable
    metadata        JSONB DEFAULT '{}',
    tags            TEXT[] DEFAULT '{}',

    -- Timestamps
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    classified_at           TIMESTAMPTZ,
    remediation_started_at  TIMESTAMPTZ,
    resolved_at             TIMESTAMPTZ,
    escalated_at            TIMESTAMPTZ,

    -- Optimistic concurrency
    CONSTRAINT fk_incident_version UNIQUE (id, version)
);

-- Append-only timeline (separate table for write scalability)
CREATE TABLE incident_timeline (
    id          BIGSERIAL PRIMARY KEY,
    incident_id UUID NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    timestamp   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    event_type  TEXT NOT NULL,
    actor       TEXT NOT NULL DEFAULT 'system',
    detail      TEXT
);

CREATE INDEX idx_incident_timeline ON incident_timeline (incident_id, timestamp);

-- Query indexes
CREATE INDEX idx_incidents_state ON incidents (state, created_at DESC);
CREATE INDEX idx_incidents_tenant ON incidents (tenant_id, created_at DESC);
CREATE INDEX idx_incidents_unresolved ON incidents (state, created_at) 
    WHERE state IN ('classified', 'remediating', 'escalated');
```

### Adapter Implementation Rules

1. **`Save`** uses a `REPEATABLE READ` transaction: insert/update `incidents` + batch insert `incident_timeline` entries + insert `event_outbox` rows (see ADR-002)
2. **`Load`** reads the `incidents` row and reconstructs the aggregate; timeline is lazy-loaded for read models
3. **Optimistic concurrency**: if `version` in UPDATE doesn't match, return `ErrConcurrencyConflict`
4. No Event Sourcing for now — current state snapshot with append-only timeline is sufficient for our volume (sub-10k incidents/day)

---

## Relationship to Self-Healing Runbooks

The Incident aggregate and Runbook execution engine interact as follows:

```
                  ┌──────────────────┐
                  │   Classifier      │
                  │   Service         │
                  └────────┬─────────┘
                           │ IncidentClassified event
                           ▼
                  ┌──────────────────┐
                  │   Runbook         │
                  │   Matcher         │──── RunbookRef assigned to Incident
                  └────────┬─────────┘
                           │
                  ┌────────▼─────────┐
                  │   Runbook         │
                  │   Executor        │──── Executes steps asynchronously
                  └────────┬─────────┘
                           │
          ┌────────────────┼────────────────┐
          │                │                 │
   RemediationStep    StepFailed     AllStepsSucceeded
   Completed event    event          event
          │                │                 │
          ▼                ▼                 ▼
   Incident stays   Incident →        Incident →
   REMEDIATING      ESCALATED         RESOLVED
```

### Key Integration Points

1. **Auto-trigger**: When `IncidentClassified` is received, the Runbook Matcher checks if a runbook exists for `(ServiceName, Category, Severity)`. If confidence > 0.8 AND a runbook exists, emit `RemediationStarted` and transition to `REMEDIATING`.
2. **Step-by-step execution**: The Runbook Executor processes steps sequentially. Each step completion/failure emits events back to the Incident aggregate.
3. **Escalation trigger**: If a step fails AND `retry_count > max_retries`, the Incident transitions to `ESCALATED`.
4. **Post-resolution**: When `RESOLVED`, the FinOps context can finalize cost attribution and the SRE dashboard updates.

---

## Consequences

1. **Positive:** Clear, enforceable state machine prevents illegal transitions.
2. **Positive:** Domain events decouple the triage context from runbook execution and notification.
3. **Positive:** Optimistic concurrency prevents duplicate remediation launches.
4. **Positive:** Timeline provides a full audit trail without the complexity of event sourcing.
5. **Negative:** JSONB for value objects sacrifices some referential integrity but provides schema flexibility.
6. **Negative:** The aggregate is write-heavy (each step update triggers a save + outbox write). Mitigate by batching step updates where possible.

---

## Implementation Guidance

- Implement the aggregate with no exported setters — only behavior methods (`TransitionToRemediating`, `RecordStepResult`, `Escalate`, `Resolve`)
- Wire domain events through an `EventPublisher` interface injected into the aggregate (or collected on the aggregate and published by the repository after save)
- Use `errgroup` for concurrent step execution in the Runbook Executor
- For the state machine, consider `stateless` or a simple switch-based validator
- Monitor transition counts by state as a health metric
- All timestamps in UTC; stored as `TIMESTAMPTZ`

---

## References

- [ADR-002: Eventing Strategy](ADR-002-eventing-strategy.md) — Outbox pattern for domain event publishing
- [DDD Aggregate Pattern](https://martinfowler.com/bliki/DDD_Aggregate.html)
- [Hexagonal Architecture (Ports & Adapters)](https://alistair.cockburn.us/hexagonal-architecture/)
