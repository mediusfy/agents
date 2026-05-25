

# Architecture Review: MESSAGE-01 through MESSAGE-05

## Review Date
2026-05-25

## Verdict
**Approved to proceed** — with 6 actionable recommendations.

## 1. Pattern Alignment — ✅ Good

| Pattern | Status | Notes |
|---------|--------|-------|
| Hexagonal (handler→service→repo/port) | ✅ | Clean separation. API handler (thin) → service → repository/event bus |
| Constructor-based DI | ✅ | No global state evident |
| errgroup + signal.NotifyContext | ✅ | Main.go template already implements this |
| Thin handlers | ✅ | Handlers do auth + basic shape check, delegate to service |
| Disposition errors | ✅ | MESSAGE-02 explicitly emits NotificationStatus 'Failed' on validation failure rather than crashing |
| Anti-Corruption Layer | ✅ | Required for inbound schema translation in MESSAGE-01 |

## 2. Event Schema Consistency — ✅ Good with Note

- `NotificationDetails.v1` and `NotificationStatus.v1` schemas from the event catalog align with MESSAGE-02/03/05.
- **Note:** MESSAGE-03 emits **both** `NotificationDetailsEvent` + `NotificationStatus 'Processed'`. This is correct per the event catalog and downstream consumer contracts.

## 3. ⚠️ MESSAGE-01: "No Event Emitted" — Revisit Recommended

**Problem:** The bounded context document explicitly states: *"Must emit NotificationStatus on every state transition (Received → Validating → Processed/Failed)"*. MESSAGE-01's "no event emitted until processing completes" contradicts this.

**Risk:** 
- Monitoring context cannot track ingestion success/failure independently.
- No ability to detect "stuck in queue" scenarios.
- Violates the own bounded context's stated constraints.

**Recommendation:** Emit `NotificationStatus 'Received'` immediately upon queue acceptance (MESSAGE-01), not only after processing (MESSAGE-03). This aligns the bounded context with its own constraints.

## 4. Scale / Latency Concerns — ✅ No Immediate Issues

- API → queue → async worker is standard for this workload.
- The errgroup concurrency model handles parallel consumer goroutines.
- No synchronous blocking on downstream events.
- **Caution:** Ensure Kafka producer flush timeouts are bounded in the service layer.

## 5. Missing Architectural Concerns — ⚠️ Medium Priority

| Concern | Gap | Recommendation |
|---------|-----|----------------|
| **Idempotency** | Dedup key defined (`notification_id + status`) but not enforced in stories. | Enforce idempotent writes in the repository layer (upsert on dedup key). |
| **Retry semantics** | No mention of retry on transient failures (Kafka broker down, DB timeout). | Add exponential backoff with configurable max attempts at the service layer. |
| **Ordering** | No ordering guarantees specified. | If order matters (e.g., status transitions), use Kafka partition key = `notification_id`. |
| **Dead-letter queue** | MESSAGE-05 mentions DLQ routing but doesn't specify DLQ schema. | DLQ entry should include original payload, error reason, and timestamp. |
| **Health checks** | Not mentioned. | Add `/healthz` + `/readyz` endpoints (already partially scaffolded in main.go). |

## 6. Multi-Cloud / Data Residency — ⚠️ Must Add

The existing **multi-cloud-constraints.md** (from Payment Processing context) states that constraints apply to **ALL bounded contexts**:

> Any event payload containing user PII (name, email, phone, address) must include a `region_of_origin` field.
> Downstream consumers MUST respect region boundaries.

**Action required in MESSAGE stories:**
- Add `region_of_origin` field to `NotificationDetails.v1` (contains recipient PII).
- Ensure Anti-Corruption Layer stamps `region_of_origin` from request metadata.
- Audit Logging Context must be multi-region — this is already stated as a cross-cutting concern.

## Summary of Recommendations

1. **Emit NotificationStatus 'Received' in MESSAGE-01** — aligns with bounded context constraints and enables monitoring.
2. **Add `region_of_origin` to NotificationDetails.v1** — required by cross-context data residency policy.
3. **Enforce idempotent dedup** in repository layer (`notification_id + status`).
4. **Add retry with exponential backoff** in service layer for transient Kafka/DB failures.
5. **Define DLQ schema** including original payload + error metadata.
6. **Add health check endpoints** (`/healthz`, `/readyz`).
