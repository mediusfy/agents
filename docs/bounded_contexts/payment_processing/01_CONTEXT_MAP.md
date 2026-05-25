

# Payment Processing - Bounded Context Map

## Overview

The original monolithic "Payment Processing Service" has been split into **three bounded contexts** following Domain-Driven Design principles and architectural review feedback. This split ensures separation of concerns, reduces PCI compliance scope, and enables independent scaling per region in a multi-cloud topology.

---

## Bounded Contexts

### 1. Payment Validation Context
- **Domain**: Input validation and policy enforcement
- **Responsibility**: Validates incoming payment requests (amount > 0, supported currency, non-empty source token, idempotency key format). Emits validation result events.
- **PCI Scope**: **Out of scope** — never touches raw PAN. Operates on tokens only.
- **Owns**: Validation rules, allowed currencies, idempotency key format policy
- **Does NOT own**: PSP connections, charging logic, raw financial data

### 2. Payment Processing Context
- **Domain**: Payment orchestration and execution
- **Responsibility**: Handles actual payment charging via Payment Service Providers (PSPs), manages retries, tracks charge state, uses transactional outbox pattern.
- **PCI Scope**: **Reduced scope (SAQ A)** — only tokenized data; no raw PAN storage
- **Owns**: Payment state machine (pending → succeeded/failed), charge retry policy, outbox table, idempotency enforcement
- **Does NOT own**: Input validation policies, event routing configuration

### 3. Payment Event Publishing Context
- **Domain**: Multi-cloud event bus integration
- **Responsibility**: Reads from the transactional outbox (read-only), publishes events to multi-cloud event buses (AWS EventBridge, Azure Event Grid, GCP Pub/Sub), manages dead-letter queues per region.
- **PCI Scope**: **Out of scope** — reads anonymized event payloads only
- **Owns**: Event routing metadata, DLQ governance, delivery retry policies
- **Does NOT own**: Any payment domain data

---

## Context Map Relationships

```
[Client / Gateway]
       │
       ▼
┌──────────────────────────────────┐
│  Payment Validation Context      │  ← Conformist (conforms to API contract)
│  - Validates input               │
│  - Checks idempotency key format │
│  - Emits: PaymentValidationFailed│
│           or PaymentValidated    │
└──────────────┬───────────────────┘
               │ PaymentValidated (with token, amount, currency, idempotency_key)
               ▼
┌──────────────────────────────────┐
│  Payment Processing Context      │  ← Customer/Supplier (Processing is Customer of Validation)
│  - Deduplicates by idempotency   │
│  - Charges via PSP               │
│  - Writes to transactional outbox│
│  - Emits: PaymentSucceeded       │
│           or PaymentFailed       │
│  - Owns: payments table (region  │
│    partitioned), outbox table    │
└──────────────┬───────────────────┘
               │ Outbox rows (unpublished events)
               ▼
┌──────────────────────────────────┐
│  Payment Event Publishing Context│  ← Conformist (reads outbox, never writes domain data)
│  - Reads unpublished outbox rows │
│  - Routes to regional event bus │
│  - Handles DLQ + retries        │
│  - Owns: routing config, DLQs   │
└──────────────────────────────────┘
```

### Relationship Types

| Direction | Type | Description |
|-----------|------|-------------|
| Validation → Processing | **Customer/Supplier** | Processing depends on Validation's output (PaymentValidated). Validation is upstream supplier. |
| Processing → Publishing | **Conformist** | Publishing reads Processing's outbox. Publishing conforms to the outbox schema without influencing it. |
| Client → Validation | **Conformist** | Validation conforms to the API contract defined by the gateway/client. |

---

## Data Ownership

| Data Entity | Owned By | Notes |
|-------------|----------|-------|
| Validation result (pass/fail) | Payment Validation Context | Transient, not persisted beyond logging |
| Payment record (amount, currency, status, token) | Payment Processing Context | Stored in region-partitioned `payments` table |
| Idempotency key + status | Payment Processing Context | Enforced via unique indexes |
| Outbox events | Payment Processing Context (write) / Payment Event Publishing Context (read) | Outbox table owned by Processing; Publishing reads only |
| Event routing metadata | Payment Event Publishing Context | Config maps, DLQ configs |
| Raw PAN | **NEVER STORED** | Tokenized upstream by PCI-compliant vault |

---

## Event Flow

```
Incoming Request
     │
     ▼
[Payment Validation Context]
  ├── Validation fails  →  PaymentValidationFailed (response immediately)
  └── Validation passes → PaymentValidated event
                              │
                              ▼
                    [Payment Processing Context]
                      ├── Idempotency dedup
                      ├── Charge via PSP
                      ├── Write to outbox table
                      ├── PaymentSucceeded → response to caller
                      └── PaymentFailed → response to caller
                              │
                              ▼ (outbox rows)
                    [Payment Event Publishing Context]
                      ├── Read unpublished rows
                      ├── Publish to regional event bus
                      └── Mark as published / send to DLQ
```

---

## Multi-Cloud Constraints

### Data Residency
- Payment records are **partitioned by region** (`region` column on `payments` table)
- Cross-region data transfer is forbidden by application policy
- Only anonymized event payloads traverse regional boundaries

### Regional Latency
- Each region has its own deployment of all three contexts
- Local processing target: **<200ms** for validation + charging
- Cross-region event propagation: **async, eventual consistency**

### Cloud-Agnostic Event Bus Adapter
- Payment Event Publishing Context uses an adapter pattern
- Supports: AWS EventBridge, Azure Event Grid, GCP Pub/Sub
- DLQ per region per cloud provider
