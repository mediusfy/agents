# ADR-005: Offline-Capable SRE Dashboard Local-First Architecture

**Status:** Accepted  
**Date:** 2026-06-03  
**Author:** Senior Database Engineer  
**Workspace:** WORKSPACE-01  

## Context

The SRE Dashboard must function reliably in environments with intermittent or absent network connectivity. SRE engineers frequently operate from data centers, disaster sites, or during network outages where cloud connectivity cannot be guaranteed. The dashboard must:

1. Load data from a local-first store (IndexedDB/SQLite in the browser)
2. Support all read operations offline (incident history, runbook references, service topology)
3. Queue write operations locally when offline (incident notes, runbook edits)
4. Clearly indicate online/offline status, last sync timestamp, and pending changes
5. Enforce data residency (e.g., EU engineer's local store only contains EU-authorized data)

## Decision

We will implement a **local-first architecture** where:

### 1. Browser-side store (IndexedDB/SQLite) is the primary data source

The browser's local store is treated as the authoritative data source for the dashboard UI. Cloud data is a synchronized replica. This reverses the traditional "cloud-first, cache locally" pattern.

**Rationale:** This ensures the dashboard is fully functional offline without any cloud dependency. The browser store uses SQLite (via OPFS/WA-SQLite) for structured data and IndexedDB for blob/document storage.

### 2. WORKSPACE-01 owns the dashboard layer, WORKSPACE-02 owns the sync engine

Following the architectural review feedback, we established a clear boundary:

| Concern | Owned By |
|---------|----------|
| Sync engine, CRDT merge, pending sync tracking | WORKSPACE-02 |
| Dashboard UI state, connectivity monitoring, local change queue, data residency | WORKSPACE-01 |
| Incident triage model (incidents, notes, runbooks, services, topology) | TRIAGE-01 |

WORKSPACE-01 consumes WORKSPACE-02 primitives rather than rebuilding them. The `workflow_id` column in `dashboard_local_change_queue` references WORKSPACE-02 sync workflows.

### 3. CRDT-based conflict resolution

All synced entities carry vector clock columns (`source_version`, `change_version`, `sync_version`) for conflict-free replicated data type (CRDT) merging. This ensures:

- Concurrent edits from multiple devices converge to a consistent state
- No "last write wins" data loss
- Offline edits are reconciled deterministically upon sync

### 4. Data residency enforcement at the database level

Data residency is enforced via:
- **`data_residency_zone`** table defining geographic zones (EU, US, APAC, GLOBAL)
- **`data_residency_policy`** table defining per-zone, per-entity-type permissions
- **`enforce_data_residency()`** function that returns boolean allow/deny
- **`data_residency_audit`** table logging all enforcement actions
- All data-carrying tables have a `data_residency_zone` column tagged at write time

The application layer MUST call `enforce_data_residency()` before any data operation that crosses zone boundaries.

### 5. Outbox pattern for event publication

All four defined events use the shared `outbox_events` table with database triggers:

- `workspace.DashboardSyncStatusChanged` — triggered on `dashboard_sync_status` change
- `sre.DashboardLoadedFromLocalStore` — triggered on `dashboard_session` creation
- `sre.NetworkConnectivityChanged` — triggered on `dashboard_connectivity_log` insert
- `sre.DataResidencyEnforced` — triggered on `data_residency_audit` insert

A background poller reads from `outbox_events WHERE status = 'pending'` and publishes to NATS JetStream.

### 6. Retention and cleanup policies

| Table | Retention | Mechanism |
|-------|-----------|-----------|
| `dashboard_local_change_queue` | 7 days (synced); Max 10K pending | Indexed cleanup query + app-layer guard |
| `dashboard_connectivity_log` | Max 1000 entries per device | App-layer capped insert |
| `data_residency_audit` | 30 days | Scheduled cleanup job |
| `dashboard_sync_batch` | 30 days (completed) | Indexed cleanup query |
| `dashboard_cached_snapshot` | 5 min TTL | Application refresh cycle |

## Consequences

### Positive

- ✅ Dashboard is fully functional offline — no cloud dependency for reads
- ✅ Writes are never lost — queued locally and synced when connectivity returns
- ✅ Clear UX indicators — sync status, pending counts, last sync time
- ✅ Data residency compliance out of the box — zone-tagged at storage level
- ✅ CRDT-based merging ensures no data conflicts on sync

### Negative

- ❌ Increased client-side storage complexity (SQLite + IndexedDB management)
- ❌ Larger initial sync payload when a device first connects (full state download)
- ❌ CRDT merge logic adds implementation complexity over simple last-write-wins
- ❌ Data residency checks add latency to cross-zone data access

### Mitigations

| Risk | Mitigation |
|------|------------|
| Large initial sync | Progressive sync with prioritized entity types (incidents first, then topology) |
| Storage bloat on client | Compaction, TTL-based eviction, capped entity counts |
| CRDT complexity | Use proven CRDT library (e.g., Automerge, Yjs) or WORKSPACE-02 merge functions |
| Connectivity flap | Debounce threshold (min 5 seconds between connectivity state changes) |

## Related Decisions

- **ADR-002** — Eventing strategy (outbox + NATS JetStream)
- **ADR-003** — Incident domain model (TRIAGE-01)
- **ADR-004** — Eventing infrastructure for triage
- **WORKSPACE-02** — CRDT sync engine and merge functions
