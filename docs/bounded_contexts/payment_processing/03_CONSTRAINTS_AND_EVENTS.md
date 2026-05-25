

# Payment Processing - Multi-Cloud Constraints & Event Modeling

## Event Triggers Reference

### Core Domain Events

| Event ID | Name | Source Context | Description | Payload Fields |
|----------|------|---------------|-------------|----------------|
| EVT-001 | PaymentReceived | Gateway/API | Incoming payment request received by the system | `idempotency_key`, `amount`, `currency`, `source_token` |
| EVT-002 | PaymentValidated | Payment Validation | Input validation passed successfully | `idempotency_key`, `amount`, `currency`, `source_token`, `validated_at` |
| EVT-003 | PaymentValidationFailed | Payment Validation | Input validation failed | `idempotency_key`, `failure_reason`, `failed_fields[]` |
| EVT-004 | PaymentCharged** | Payment Processing | PSP confirmed successful charge | `payment_id`, `idempotency_key`, `amount`, `currency`, `gateway_txn_id` |
| EVT-005 | PaymentSucceeded | Payment Processing | Entire payment flow completed successfully | `payment_id`, `amount`, `currency`, `region`, `completed_at` |
| EVT-006 | PaymentFailed | Payment Processing | Charge failed at PSP | `payment_id`, `idempotency_key`, `failure_reason`, `gateway_error_code`, `region` |
| EVT-007 | PSPCircuitBreakerTripped | Payment Processing | Circuit breaker opened for a PSP | `psp_name`, `region`, `failure_count`, `threshold`, `opened_at` |
| EVT-008 | PaymentOutboxPublished | Payment Event Publishing | Event successfully published to bus | `event_id`, `event_type`, `region`, `bus_type`, `published_at` |
| EVT-009 | PaymentOutboxDLQ | Payment Event Publishing | Event moved to dead-letter queue | `event_id`, `event_type`, `region`, `failure_reason`, `retry_count` |

**Note**: `PaymentCharged` is an internal processing event. Downstream consumers receive `PaymentSucceeded`.

---

## Multi-Cloud Constraints

### Data Residency Laws

| Constraint | Rule | Enforcement |
|------------|------|-------------|
| GDPR (EU) | Payment data must stay in EU region | `region = 'eu-west'` partition; no cross-region queries |
| PSD2 (EU) | Strong Customer Authentication per region | SCA handled in-region with local PSP adapters |
| US State Laws (CCPA) | Payment data stored in US region | `region = 'us-east'` partition |
| APAC (SG/JP) | Data stored in APAC region | `region = 'ap-southeast'` partition |

### Regional Network Latency

| Operation | Target | Degradation Strategy |
|-----------|--------|---------------------|
| Validation (in-region) | <50ms | Synchronous, local cache |
| PSP charge (in-region) | <200ms | Circuit breaker, exponential backoff |
| Event propagation (cross-region) | <5s | Async, eventual consistency |
| Idempotency check (in-region) | <10ms | Redis cache, DB fallback |

### Cloud-Specific Event Bus Adapters

| Cloud Provider | Service | Adapter Pattern |
|----------------|---------|-----------------|
| AWS | EventBridge | Regional event bus per region |
| Azure | Event Grid | Regional topic per region |
| GCP | Pub/Sub | Regional topic per region |

---

## Event Modeling Diagrams

### Happy Path Flow

```
Request → [Validation] → PaymentValidated 
                            ↓
                      [Processing] → Idempotency Check → PSP Charge → PaymentSucceeded
                                                                         ↓
                                                                    [Outbox Write]
                                                                         ↓
                                                                    [Event Publishing]
                                                                         ↓
                                                              Regional Event Bus
```

### Failure Paths

```
1. Validation Failure:
   Request → [Validation] → PaymentValidationFailed → Response (422)

2. PSP Failure (retryable):
   PaymentValidated → [Processing] → Idempotency OK → PSP Error → PaymentFailed → Outbox

3. Circuit Breaker Open:
   PaymentValidated → [Processing] → Breaker Open → Immediate Failure → PSPCircuitBreakerTripped

4. Event Publishing Failure:
   PaymentSucceeded → [Outbox] → Publish Fail → Retry (3x) → DLQ
```

---

## Idempotency Strategy

### Key Design

- **Input**: Caller provides `Idempotency-Key` header (UUID v4)
- **Storage**: Unique index on `(region, idempotency_key)` per partition
- **Global uniqueness**: Partial unique index `WHERE status = 'succeeded'` across all regions
- **Cache**: Redis with 24h TTL
- **TTL for idempotency records**: 24 hours (configurable)

### State Machine

```
                    ┌──────────┐
                    │  Pending  │
                    └────┬─────┘
                         │
              ┌──────────┼──────────┐
              │          │          │
              ▼          ▼          ▼
        ┌──────────┐ ┌──────┐ ┌──────────────┐
        │ Succeeded │ │Failed│ │Valdn_Failed  │
        └──────────┘ └──────┘ └──────────────┘
              │          │
              │ (no retry)│ (retryable)
              ▼          ▼
          [Idempotent   [Can re-process
           response]    with same key]
```

---

## PCI Compliance Scope

### Tokenization Flow

```
[Client]                    [Payment Validation]             [Payment Processing]
   │                               │                               │
   ├── source_token ───────────────▶                               │
   │ (NEVER raw PAN)                │  (passes token through)      │
   │                               ├──── source_token ────────────▶│
   │                               │                               ├──▶ PSP (tokenized charge)
   │                               │                               │
   │                               │                               │
```

### SAQ A Eligibility
- This service **never stores, processes, or transmits** PAN
- All payment sources are tokenized by a PCI-compliant vault (Stripe, Braintree, etc.)
- The service qualifies for **SAQ A** (merchant with fully tokenized cardholder data)

### Audit Trail
- `payment_events` outbox table provides a complete audit trail of all payment state transitions
- Consider `pgaudit` extension for full DML audit logging on `payments` table
