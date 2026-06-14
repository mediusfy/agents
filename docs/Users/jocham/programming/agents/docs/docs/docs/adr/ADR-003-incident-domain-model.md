# ADR-003: Incident Domain Model & State Machine (v2 — TRIAGE-02 RCA Extension)

**Status:** Updated (v2)  
**Date:** 2025-01-23  
**Context:** TRIAGE-02 (RCA Service), TRIAGE-03 (Self-Healing Runbooks), ADR-002 (Eventing)  
**Deciders:** CTO, Backend Engineer, SRE Engineer  

---

## Decision: Incident Aggregate (v2 — RCA-Aware)

The Incident is a **DDD Aggregate**. v2 adds **RCA suggestions**, **region**, **git changes references**, and a **description** field to support TRIAGE-02's Root Cause Analysis service.

### Aggregate Identity

```go
type IncidentID struct {
    value string // UUID v7 (time-sortable, KSUID-compatible)
}
```

### Aggregate Fields

```go
type Incident struct {
    ID              IncidentID
    Title           string              // short title from alert
    Description     string              // rich markdown description (v2: added)
    Severity        Severity            // P0–P4
    Status          IncidentStatus      // state machine state
    ServiceID       string              // affected service UUID
    Region          string              // cloud region (v2: added)
    Classification  Classification      // classification metadata
    RCASuggestions  []RCASuggestion     // RCA suggestions (v2: embedded list)
    GitChanges      []GitChangeRef      // git changes references (v2: added)
    Timeline        []TimelineEntry     // ordered, append-only log
    Metadata        map[string]string   // flexible extensibility
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
type Severity string // "P0" | "P1" | "P2" | "P3" | "P4"

type Classification struct {
    Summary         string   // human-readable summary
    Detail          string   // markdown description
    Confidence      float64  // 0.0–1.0
    ClassifierID    string   // which classifier
    Category        string   // e.g. "latency", "error_budget", "cost_anomaly"
}

// v2: RCA suggestion embedded in incident
type RCASuggestion struct {
    ID              string    // UUID
    Summary         string    // one-line root cause hypothesis
    Description     string    // detailed analysis in markdown
    Confidence      float64   // 0.0–1.0
    Evidence        []string  // log snippets, metric links, etc.
    SuggestedAction string    // recommended remediation
    GeneratedBy     string    // "llm", "rule_engine", "human"
    GeneratedAt     time.Time
    Status          string    // "pending_review" | "accepted" | "rejected"
}

// v2: git changes reference
type GitChangeRef struct {
    Repo        string    // e.g. "github.com/org/payment-api"
    Branch      string    // e.g. "main"
    CommitSHA   string    // full SHA
    Author      string    // committer email
    Message     string    // commit message
    Files       []string  // affected files
    Timestamp   time.Time
}

type TimelineEntry struct {
    Timestamp   time.Time
    EventType   string   // e.g. "classified", "rca_generated", "remediation_started"
    Actor       string   // "system" or user email
    Detail      string
}
```

---

## State Machine

```
                  +--------------------------+
                  |       CLASSIFIED         |
                  |  (initial state after    |
                  |   classification)        |
                  +------------+-------------+
                               |
                  +------------v-------------+
                  |       REMEDIATING        |
                  |  (runbook execution in   |
                  |   progress)              |
                  +----+--------------+------+
                       |              |
              +--------v---+   +------v--------+
              |  RESOLVED  |   |  ESCALATED     |
              | (success)  |   | (human needed) |
              +------------+   +-------+--------+
                                       |
                              +--------v--------+
                              |  RESOLVED (post |
                              |  human action)  |
                              +-----------------+
```

### States

| State | Description |
|---|---|
| `CLASSIFIED` | Incident classified with severity, service, category. Initial state. |
| `REMEDIATING` | Self-healing runbook in progress. |
| `RESOLVED` | Remediation completed or manually resolved. Terminal state. |
| `ESCALATED` | Remediation failed or confidence too low. Human intervention required. |

### Transition Rules

| From | To | Condition |
|---|---|---|
| `*` | `CLASSIFIED` | Classification result received |
| `CLASSIFIED` | `REMEDIATING` | Runbook auto-triggered or operator initiated |
| `REMEDIATING` | `RESOLVED` | All runbook steps succeeded |
| `REMEDIATING` | `ESCALATED` | Step failed, or confidence < threshold |
| `ESCALATED` | `RESOLVED` | Operator manually resolves |
| `ESCALATED` | `REMEDIATING` | Operator retries auto-remediation |

**v2 RCA-specific transition:** `CLASSIFIED → (RCA generated)` does **not** change the state. RCA suggestions are attached alongside the classification — they are advisory metadata, not state.

---

## Domain Events (v2 Additions)

| Event Type | Payload | Trigger |
|---|---|---|
| `triage.RCASuggestionGenerated.v1` | `IncidentID, RCASuggestion` | New RCA suggestion attached |
| `triage.RCASuggestionAccepted.v1` | `IncidentID, SuggestionID` | Human accepted an RCA |
| `triage.RCASuggestionRejected.v1` | `IncidentID, SuggestionID, Reason` | Human rejected an RCA |

All existing events from v1 (IncidentClassified, RemediationStarted, etc.) remain unchanged.

---

## Persistence Decision: PostgreSQL (not Firestore)

### Chosen: PostgreSQL with JSONB

**Rationale:**

1. **Existing investment:** TRIAGE-01 already uses PostgreSQL (`incidents`, `incident_classifications`, `extracted_incident_data` tables). Adding Firestore would introduce dual-write complexity for no benefit.

2. **Cross-context joins:** Incidents join with `services`, `sre_teams`, and (in future) GITOPS/FINOPS tables. Postgres handles this natively; Firestore does not.

3. **RCA as JSONB:** `RCASuggestions` and `GitChanges` are variable-length, nested lists accessed as a unit (read all suggestions for an incident). JSONB is the ideal Postgres type.

4. **Transactional outbox:** ADR-002 requires transactional outbox for reliable event publishing. Postgres supports this with a single ACID transaction; Firestore would require a two-phase commit.

5. **Compliance:** The platform targets data residency compliance. Postgres (single-region or read-replica) is simpler to audit than Firestore's global replication model.

### Storage Schema (PostgreSQL)

```sql
-- Main aggregate table (extended for RCA v2)
CREATE TABLE incidents (
    id              UUID PRIMARY KEY,              -- UUID v7
    version         INT NOT NULL DEFAULT 1,
    title           TEXT NOT NULL,
    description     TEXT NOT NULL DEFAULT '',       -- v2: added
    severity        severity_level NOT NULL,        -- P0-P4 enum (existing)
    status          incident_status NOT NULL DEFAULT 'classified',
                                                     -- v2: uses new enum values
    service_id      UUID REFERENCES services(id),
    region          VARCHAR(50) NOT NULL DEFAULT '', -- v2: added
    classification  JSONB NOT NULL,
    rca_suggestions JSONB DEFAULT '[]'::jsonb,      -- v2: array of RCASuggestion
    git_changes     JSONB DEFAULT '[]'::jsonb,      -- v2: array of GitChangeRef
    metadata        JSONB DEFAULT '{}'::jsonb,
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

-- Query indexes
CREATE INDEX idx_incidents_status      ON incidents (status, created_at DESC);
CREATE INDEX idx_incidents_severity    ON incidents (severity, created_at DESC);
CREATE INDEX idx_incidents_service     ON incidents (service_id);
CREATE INDEX idx_incidents_region      ON incidents (region);
CREATE INDEX idx_incident_timeline     ON incident_timeline (incident_id, timestamp);
CREATE INDEX idx_incidents_unresolved  ON incidents (status, created_at)
    WHERE status IN ('classified', 'remediating', 'escalated');
CREATE INDEX idx_incidents_severity_status ON incidents (severity, status);

-- GIN index for RCA suggestions queries
CREATE INDEX idx_incidents_rca_suggestions ON incidents USING GIN (rca_suggestions);
```

### Updated ENUMs

Extend the existing `incident_status` enum from TRIAGE-01 to align with the state machine:

```sql
-- Migrate from TRIAGE-01 values ('new', 'classified', 'flagged', 'resolved')
-- to state machine values ('classified', 'remediating', 'resolved', 'escalated')
ALTER TYPE incident_status ADD VALUE IF NOT EXISTS 'remediating';
ALTER TYPE incident_status ADD VALUE IF NOT EXISTS 'escalated';
-- Note: 'new' and 'flagged' remain for backward compatibility during migration
```

---

## Repository Port (v2)

```go
package repository

type IncidentRepository interface {
    Save(ctx context.Context, incident *Incident) error
    Load(ctx context.Context, id IncidentID) (*Incident, error)
    ListByStatus(ctx context.Context, status IncidentStatus, limit, offset int) ([]*Incident, error)
    ListBySeverity(ctx context.Context, severity Severity, limit, offset int) ([]*Incident, error)
    ListUnresolvedSince(ctx context.Context, since time.Duration) ([]*Incident, error)

    // v2: RCA-specific queries
    ListIncidentsPendingRCA(ctx context.Context, limit int) ([]*Incident, error)
    AttachRCASuggestion(ctx context.Context, incidentID IncidentID, suggestion RCASuggestion) error
    UpdateRCASuggestionStatus(ctx context.Context, incidentID IncidentID, suggestionID string, status string) error
}
```

---

## Consequences

1. **Positive:** RCA suggestions live inside the incident aggregate — no separate RCA service database needed. Read/write is atomic.
2. **Positive:** JSONB for `rca_suggestions` and `git_changes` allows schema evolution without migrations.
3. **Positive:** Postgres consistency ensures RCA suggestions are never orphaned from their incident.
4. **Positive:** GIN index on `rca_suggestions` enables efficient queries for pending RCA items.
5. **Negative:** JSONB sacrifices referential integrity — if an RCA suggestion references an external entity, that link is not enforced by the database.
6. **Negative:** Large `rca_suggestions` arrays (100+ per incident) could bloat the main row. Mitigation: cap at 20 suggestions; archive older ones to a side table if needed.

---

## Implementation Guidance

1. **Backend:** Implement the aggregate in `internal/incident/domain/` with constructor-based dependency injection. Only behavior methods — no exported setters.
2. **State Machine:** Use the existing `incident_status` enum from TRIAGE-01, extended with `remediating` and `escalated`.
3. **RCA Suggestions:** The TRIAGE-02 (RCA Service) writes to `incidents.rca_suggestions` via the repository. It does NOT change incident status.
4. **Git Changes:** Populated by GITOPS context when relevant commits are correlated to the incident time window.
5. **Event Publishing:** Use the transaction outbox pattern (per ADR-002). RCA events (`RCASuggestionGenerated`, etc.) go through the same outbox table.
6. **Migration:** Write a migration that adds the v2 columns (`description`, `region`, `rca_suggestions`, `git_changes`) as nullable with defaults, then backfill existing rows.

---

## References

- [ADR-002: Eventing Strategy](ADR-002-eventing-strategy.md)
- [TRIAGE-01 Schema](../database/TRIAGE-01_SCHEMA_SUMMARY.md)
- [DDD Aggregate Pattern](https://martinfowler.com/bliki/DDD_Aggregate.html)
- [Hexagonal Architecture](https://alistair.cockburn.us/hexagonal-architecture/)
