# Local-First SRE Workspace Theme

> **Stories**: WORKSPACE-01 · WORKSPACE-02 · WORKSPACE-03 · WORKSPACE-04  
> **Priority**: P0 (2 stories) + P1 (2 stories)  
> **Phase**: Phase 1 (P0) + Phase 2 (P1)

---

## Theme Overview

The Local-First SRE Workspace theme enables SRE engineers to **work offline, sync seamlessly, and collaborate in real-time** without depending on cloud connectivity. Built on CRDTs (Conflict-free Replicated Data Types), WebRTC, and progressive sync, the workspace provides a resilient, always-available experience.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SRE Engineer's Browser                        │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    Workspace Application                      │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │    │
│  │  │ Dashboard    │  │ Runbook      │  │ Incident Viewer  │  │    │
│  │  │ (Offline)    │  │ Editor (YAML)│  │ (Timeline)       │  │    │
│  │  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘  │    │
│  │         │                 │                    │            │    │
│  │  ┌──────┴─────────────────┴────────────────────┴─────────┐  │    │
│  │  │                    Sync Layer                          │  │    │
│  │  │  ┌────────────┐  ┌────────────┐  ┌────────────────┐  │  │    │
│  │  │  │ CRDT Engine│  │ P2P Sync  │  │ Cloud Sync     │  │  │    │
│  │  │  │ (Y.js)     │  │ (WebRTC)  │  │ (WebSocket)    │  │  │    │
│  │  │  └────────────┘  └────────────┘  └────────────────┘  │  │    │
│  │  └──────────────────────────────────────────────────────┘  │    │
│  │                              │                              │    │
│  │  ┌───────────────────────────┴───────────────────────────┐  │    │
│  │  │                   Local Store                          │  │    │
│  │  │  ┌──────────────────┐  ┌──────────────────────────┐   │  │    │
│  │  │  │  IndexedDB        │  │  SQLite (via sql.js)     │   │  │    │
│  │  │  │  (Dexie.js)       │  │  (Structured queries)    │   │  │    │
│  │  │  └──────────────────┘  └──────────────────────────┘   │  │    │
│  │  └──────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Story Details

### WORKSPACE-01: Offline-Capable SRE Dashboard

**Data Flow:**

```
Application Start
    │
    ├── Check Connectivity
    │   ├── Online → Load from local store, sync cloud in background
    │   └── Offline → Load from local store only
    │
    ├── Render Dashboard
    │   ├── Incidents (cached)
    │   ├── Runbooks (cached)
    │   ├── Service Health (cached)
    │   └── Connectivity indicator
    │
    ├── User Interaction
    │   ├── Changes saved to local store immediately
    │   ├── CRDT ops generated and stored
    │   ├── Cloud sync queued (if online) or deferred (if offline)
    │   └── P2P sync sent to online peers
    │
    └── Connectivity Change
        ├── Lost → Show offline indicator, queue all changes
        └── Restored → Initiate progressive cloud sync
```

**Local Storage Schema:**

```typescript
// Key data stores in IndexedDB
interface LocalStore {
  incidents: {
    key: string;            // incident_id
    value: IncidentDocument; // CRDT document
    indexes: ['status', 'severity', 'team', 'created_at'];
  };
  
  runbooks: {
    key: string;            // runbook_id
    value: RunbookDocument;  // CRDT document
    indexes: ['service', 'severity', 'name'];
  };
  
  syncQueue: {
    key: string;            // auto-increment
    value: SyncQueueItem;
    indexes: ['status', 'priority', 'type'];
  };
  
  workspaceConfig: {
    key: string;            // config key
    value: any;
  };
  
  pendingChanges: {
    key: string;            // change_id
    value: PendingChange;
    indexes: ['synced', 'created_at'];
  };
}
```

**Acceptance Criteria:**
- ✅ Dashboard loads from local store first (offline-first), syncs with cloud in background
- ✅ All core features work offline: viewing incidents, runbooks, service health
- ✅ Changes made offline are queued and synced when connectivity is restored
- ✅ Sync conflicts are resolved using CRDT-based strategies
- ✅ User sees clear connectivity status indicator and sync progress

---

### WORKSPACE-02: Local-First Runbook Authoring and Versioning

**CRDT-Based Runbook Editing:**

```typescript
import * as Y from 'yjs';

// Initialize a Y.js document for a runbook
const doc = new Y.Doc();
const runbookMap = doc.getMap('runbook');
const stepsArray = doc.getArray('steps');

// Multiple engineers can edit concurrently:
// Engineer A edits step 1
stepsArray.push([{ step_number: 1, name: 'Check primary', action: 'execute_query' }]);

// Engineer B edits step 2 simultaneously
stepsArray.push([{ step_number: 2, name: 'Promote replica', action: 'run_script' }]);

// CRDT ensures both changes are merged without conflicts
// Result: [step1, step2] (order preserved, no data loss)

// Local persistence
const persistence = new Y.IndexeddbPersistence('runbook-rb-db-failover', doc);

// When online, sync to Git:
// 1. Convert CRDT state → YAML string
// 2. Create Git commit with changes
// 3. Push to runbooks repository
```

**Runbook Editor Features:**

```
┌──────────────────────────────────────────────────────────────┐
│  ● Runbook Editor — database-failover.yaml          [Sync: ●] │
├──────────────────────────────────────────────────────────────┤
│  name: database-failover                                      │
│  version: 1.2.0                                               │
│  service: database                                            │
│  severity: [P0, P1]                                           │
│  environments: [production]                                    │
│                                                               │
│  trigger_conditions:                                          │
│    metric: database_connection_errors                         │
│    operator: gt                                                │
│    threshold: 100                                              │
│                                                               │
│  steps:                                                       │
│    - step_number: 1                                            │
│      name: Identify primary                                    │
│      action: execute_query                                    │
│      parameters:                                               │
│        query: "SHOW PRIMARY"                                   │
│  ┌────────────────────────────────────────────────────────┐   │
│  │ ✓ YAML valid | Last saved: 2 min ago (offline)        │   │
│  │ Collaborators: ● Alice (editing) ● Bob (viewing)      │   │
│  └────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

**Acceptance Criteria:**
- ✅ Runbook editor works fully offline with YAML validation
- ✅ Changes use CRDT (Y.js) for conflict-free concurrent editing
- ✅ Local changes are auto-synced to Git repository when online
- ✅ Multiple engineers can edit the same runbook with automatic merge
- ✅ Version history is preserved locally and in Git

---

### WORKSPACE-03: P2P Sync Between Team Members

**WebRTC P2P Architecture:**

```
┌──────────────────┐         ┌──────────────────┐
│  Engineer A      │         │  Engineer B      │
│  (Browser)       │         │  (Browser)       │
│                  │         │                  │
│  ┌────────────┐  │         │  ┌────────────┐  │
│  │ CRDT Doc   │  │         │  │ CRDT Doc   │  │
│  │ (Y.js)     │  │         │  │ (Y.js)     │  │
│  └──────┬─────┘  │         │  └──────┬─────┘  │
│         │        │         │         │        │
│  ┌──────┴─────┐  │         │  ┌──────┴─────┐  │
│  │ P2P Sync   │◄─┼─────────┼─►│ P2P Sync   │  │
│  │ (WebRTC)   │  │ WebRTC  │  │ (WebRTC)   │  │
│  └────────────┘  │ Data    │  └────────────┘  │
│                  │ Channel │                  │
│  ┌────────────┐  │         │  ┌────────────┐  │
│  │ Signaling  │◄─┼─────────┼─►│ Signaling  │  │
│  │ (via API)  │  │         │  │ (via API)  │  │
│  └────────────┘  │         │  └────────────┘  │
└──────────────────┘         └──────────────────┘
         │                           │
         └───────────┬───────────────┘
                     │
            ┌────────┴────────┐
            │  Signaling      │
            │  Server (API)   │
            │  (STUN/TURN)    │
            └─────────────────┘
```

**P2P Sync Protocol:**

```
1. Connection Establishment:
   a. Engineer A signals via API: { workspace_id, peer_id, signal_data: { type: 'offer', sdp } }
   b. Signaling server relays to Engineer B
   c. Engineer B responds with answer
   d. WebRTC connection established

2. Data Synchronization:
   a. On local change: serialize CRDT operations
   b. Send ops via WebRTC data channel: { doc_id, ops: [...], timestamp }
   c. Peer applies CRDT ops locally (automatic merge)
   d. Acknowledge receipt

3. Conflict Resolution:
   a. CRDTs handle concurrent edits automatically
   b. No manual conflict resolution needed
   c. All peers converge to same state (eventual consistency)
```

**Acceptance Criteria:**
- ✅ P2P sync uses WebRTC for direct browser-to-browser connections
- ✅ Changes synced in real-time across online team members
- ✅ P2P sync works without cloud backend (LAN-only mode via local signaling)
- ✅ Sync includes: incident timeline updates, runbook edits, annotations
- ✅ Connection status and sync state visible per team member

---

### WORKSPACE-04: Progressive Sync to Cloud Backend

**Sync Priority Queue:**

```
On Connectivity Restored:
    │
    ├── Priority 1: Incident Timeline Updates
    │   ├── Incident status changes
    │   ├── Timeline entries
    │   └── Urgent annotations
    │
    ├── Priority 2: Runbook Changes
    │   ├── Runbook edits
    │   ├── New runbook versions
    │   └── Runbook metadata updates
    │
    ├── Priority 3: Configuration Changes
    │   ├── Dashboard layout
    │   ├── User preferences
    │   └── Saved filters
    │
    └── Priority 4: Annotations & Notes
        ├── User annotations
        ├── Personal notes
        └── Bookmarks
```

**Progressive Sync Implementation:**

```typescript
class ProgressiveSyncEngine {
  private queue: SyncQueueItem[];
  private isPaused: boolean = false;
  private bandwidth: number = 0; // estimated bandwidth in bps
  
  async syncNextBatch(): Promise<SyncResult> {
    const batch = this.getNextBatch(); // respect priority ordering
    if (batch.length === 0) return { status: 'completed' };
    
    const chunkedBatch = this.chunkItems(batch, this.getOptimalChunkSize());
    
    for (const chunk of chunkedBatch) {
      if (this.isPaused) break;
      
      try {
        const response = await this.cloudSync.sync(chunk);
        this.markAsSynced(chunk);
        this.updateProgress(chunk.length, chunkedBatch.length);
      } catch (error) {
        if (this.isRetryable(error)) {
          await this.scheduleRetry(chunk);
        } else {
          this.markAsFailed(chunk, error);
        }
      }
      
      // Bandwidth-aware pacing
      await this.pacingDelay();
    }
    
    return { status: this.queue.length === 0 ? 'completed' : 'partial' };
  }
  
  private getOptimalChunkSize(): number {
    // Adapt chunk size based on bandwidth
    if (this.bandwidth > 10_000_000) return 100;     // > 10 Mbps
    if (this.bandwidth > 1_000_000) return 50;        // > 1 Mbps
    if (this.bandwidth > 100_000) return 20;          // > 100 Kbps
    return 5; // Slow connection
  }
}
```

**Sync Progress UI:**

```
Sync Status: Syncing (5 of 23 items remaining)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╸░░░░░░ 78%

Priority Queue:
  ✅ Incident Timeline Updates     — 3 of 3 synced
  ✅ Runbook Changes               — 2 of 2 synced
  ▶ Configuration Changes          — 13 of 18 syncing
     [░░░░░░░░░░░░░░░░░░░░░░░░░] 72%
  ⏳ Annotations & Notes           — 0 of 5 pending

Failed Items: 1
  [Retry] annotation-abc123 — Network timeout (retry in 30s)
```

**Acceptance Criteria:**
- ✅ Sync order prioritization: incident timeline > runbook changes > configuration changes
- ✅ Sync progress visible with per-item status (pending, syncing, synced, failed)
- ✅ Failed syncs retried with exponential backoff
- ✅ Sync is bandwidth-aware (progressive, chunked uploads)
- ✅ User can pause/resume sync and view sync history

---

## API Endpoints Summary

| Method | Path | Story | Description |
|--------|------|-------|-------------|
| `POST` | `/workspace/sync` | WORKSPACE-04 | Sync changes to cloud |
| `GET` | `/workspace/sync/status` | WORKSPACE-04 | Get sync status |
| `POST` | `/workspace/sync/pause` | WORKSPACE-04 | Pause sync |
| `POST` | `/workspace/sync/resume` | WORKSPACE-04 | Resume sync |
| `GET` | `/workspace/p2p/peers` | WORKSPACE-03 | List P2P peers |
| `POST` | `/workspace/p2p/signal` | WORKSPACE-03 | Exchange WebRTC signaling |
| `GET` | `/workspace/p2p/sync-status` | WORKSPACE-03 | P2P sync status |

---

## Implementation Tasks

| Task | Effort | Description |
|------|--------|-------------|
| WORKSPACE-01-T1 | 3d | Local-first data layer (IndexedDB + CRDT) |
| WORKSPACE-01-T2 | 4d | Offline-capable dashboard UI |
| WORKSPACE-01-T3 | 3d | Background sync engine with conflict resolution |
| WORKSPACE-02-T1 | 4d | YAML runbook editor with offline support |
| WORKSPACE-02-T2 | 3d | CRDT (Y.js) integration for runbooks |
| WORKSPACE-02-T3 | 3d | Git sync bridge |
| WORKSPACE-03-T1 | 4d | WebRTC signaling and P2P connection management |
| WORKSPACE-03-T2 | 3d | CRDT-based P2P sync protocol |
| WORKSPACE-03-T3 | 2d | Team presence UI |
| WORKSPACE-04-T1 | 3d | Priority-based sync queue |
| WORKSPACE-04-T2 | 3d | Progressive sync engine |
| WORKSPACE-04-T3 | 2d | Sync progress UI |

**Total Effort: 37 days**

---

## Offline-First Principles Applied

| Principle | Implementation |
|-----------|---------------|
| **Local-first** | IndexedDB + SQLite as primary data source; cloud is backup |
| **CRDTs** | Y.js for conflict-free concurrent editing |
| **P2P** | WebRTC for direct peer-to-peer sync without cloud relay |
| **Progressive Sync** | Priority-ordered, bandwidth-aware, chunked cloud sync |
| **Resilient** | Works fully offline; queue + retry for failed syncs |
| **Transparent** | Clear connectivity/sync status visible at all times |
