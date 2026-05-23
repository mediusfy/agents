

# Payment Processing Bounded Context

## Overview

This document defines the **Payment Processing** bounded context within the OpenClaw ecosystem, designed using Domain-Driven Design (DDD) principles.

---

## Context Map

```
┌─────────────────┐     PaymentRequest     ┌──────────────────────┐
│  Ordering BC    │ ─────────────────────> │  PaymentProcessing   │
│  (Upstream)     │                        │  (This Bounded       │
└─────────────────┘                        │   Context)           │
                                           │                      │
┌─────────────────┐     PaymentSucceeded   │  ┌────────────────┐  │
│  Notification   │ <───────────────────── │  │ Payment (Agg.) │  │
│  BC (Downstream)│     PaymentFailed      │  │  - status (VO) │  │
└─────────────────┘                        │  │  - amount      │  │
                                           │  │  - currency    │  │
┌─────────────────┐     PaymentSucceeded   │  │  - origin      │  │
│  Ledger BC      │ <───────────────────── │  │    _region     │  │
│  (Downstream)   │     PaymentFailed      │  └────────┬───────┘  │
└─────────────────┘                        │           │          │
                                           │  ┌────────▼───────┐  │
                                           │  │ Transaction    │  │
                                           │  │ (Child Entity) │  │
                                           │  └────────────────┘  │
└──────────────────────┘
```

## User Stories

### US-001: Successful Payment Flow
**Title:** Payment Processing Service handles incoming payments and emits `PaymentSucceeded` event

**Gherkin:**
```gherkin
Given an incoming payment request with valid credentials
When the Payment Processing Service validates and processes the payment
Then the payment is successfully processed
And a 'PaymentSucceeded' event is emitted
```

### US-002: Failed Payment Flow
**Title:** Payment Processing Service handles payment failures and emits `PaymentFailed` event

**Gherkin:**
```gherkin
Given an incoming payment request with invalid or insufficient credentials
When the Payment Processing Service validates and attempts to process the payment
Then the payment processing fails
And a 'PaymentFailed' event is emitted
```

---

## Event Triggers

| Event ID | Event Name | Description |
|---|---|---|
| EVT-001 | `PaymentRequestReceived` | An incoming payment request arrives with valid credentials. Trigger: External client submits a payment request. |
| EVT-002 | `PaymentValidated` | Credentials and data integrity checks pass successfully. Trigger: Successful validation of payment request. |
| EVT-003 | `PaymentProcessed` | Payment has been processed through the underlying financial infrastructure (PSP/acquirer). Trigger: Successful PSP response. |
| EVT-004 | `PaymentSucceeded` | The payment lifecycle completed successfully. Emitted as domain event to downstream BCs. Trigger: `PaymentProcessed` confirms success. |
| EVT-005 | `PaymentFailed` | Payment processing failed. Carries failure reason details. Emitted for downstream compensatory actions. Trigger: Validation failure or PSP rejection. |

---

## DDD Tactical Design

### Aggregate
- **Payment** — the single aggregate root
  - PaymentId (UUID) — identity
  - Status (Value Object: `pending | validated | processing | succeeded | failed`)
  - Amount (Value Object: Money)
  - Currency (ISO 4217)
  - OriginRegion (Value Object: e.g., `eu-west`, `us-east`)
  - AggregateVersion (for optimistic concurrency)

### Child Entity
- **Transaction** — represents a single PSP attempt (supports retries and split captures)
  - TransactionId, PaymentId (FK), PspReference, Status (`initiated | authorized | captured | failed`), AttemptNumber, Amount, Error fields

### Process Manager (Saga)
- Orchestrates the flow: **Validate → Process PSP → Emit Event**
- The aggregate records state changes; the Process Manager reads current state, decides next step, and calls aggregate commands.

### Ports & Adapters (Hexagonal Architecture)
- **Port:** `PSPGateway` interface in domain layer
- **Adapters:** Cloud-specific implementations (e.g., `StripeAdapter`, `GovCloudAdapter`) for data residency compliance

### Anti-Corruption Layer (ACL)
- At the ingress boundary, translate upstream (Ordering BC) command formats into the PaymentProcessing ubiquitous language (`PaymentRequestReceived`)

### CQRS
- **Commands:** Write-side uses Payment aggregate + repository
- **Queries:** Read-side uses `payment_projections` denormalized table for fast user-facing queries

---

## Architectural Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Aggregate Design | Single `Payment` root + `Transaction` child entity | Avoids eventual consistency headaches; clean retry/split capture support |
| Orchestration | Process Manager pattern | Keeps aggregate pure; Process Manager handles flow logic |
| Integration | Event-driven via message broker | At-least-once delivery, traceability, decoupled deployment |
| Cloud Integration | Ports & Adapters pattern | Domain never knows about cloud; adapters enforce data residency |
| Query Model | Lightweight CQRS (same DB, separate tables) | Avoids complex query logic on aggregate; no need for event sourcing |
| Upstream Integration | Anti-Corruption Layer | Protects domain from upstream model changes |
| Idempotency | Idempotency Key table + Redis cache (optional) | Prevents duplicate charges from duplicate requests |
| Data Residency | Schema-per-region + app-level routing | Enforces data partitioning at repository level across multi-cloud |

---

## Multi-Cloud & Data Residency Constraints

1. **Data Partitioning:** Payment data is partitioned by `origin_region` at the schema level (e.g., `eu_west.payments`, `us_east.payments`)
2. **Repository Routing:** The repository layer selects the correct schema/connection string based on the payment's region tag
3. **Cross-Region Queries:** Aggregated via read model subscriber publishing to a global view (materialized view or analytics DB)
4. **No Cross-Region Writes:** Payment data never leaves its region of origin in write operations
5. **Latency Awareness:** PSP adapters select the nearest PSP endpoint based on region

---

## Event Flow Diagram

```
Client / Upstream BC
       │
       ▼
┌──────────────────────────────┐
│  Anti-Corruption Layer (ACL) │
│  (Translate to ubiquitous    │
│   language)                  │
└──────────┬───────────────────┘
           │ PaymentRequestReceived
           ▼
┌──────────────────────────────┐
│  Process Manager (Saga)      │
│  1. Validate credentials     │
│  2. Call aggregate command   │
│  3. Call PSP via adapter     │
│  4. Emit domain event        │
└──────────┬───────────────────┘
           │
     ┌─────┴─────┐
     │           │
     ▼           ▼
  Success      Failure
     │           │
     ▼           ▼
PaymentSucceeded  PaymentFailed
     │           │
     └─────┬─────┘
           │
           ▼
    Message Broker (Kafka/EventBridge)
           │
     ┌─────┴─────┐
     │           │
     ▼           ▼
Notification   Ledger
   BC           BC
```
