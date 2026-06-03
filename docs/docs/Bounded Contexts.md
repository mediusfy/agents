# Bounded Contexts — Standard Service (Entity Management)

## Context: `entity-management`

### Domain
Dynamic schema-driven entity registry. Platform engineers define typed entity schemas, then create, read, update, soft-delete, hard-delete, restore, and list entity instances that conform to those schemas.

### Ubiquitous Language

| Term | Definition |
|------|-----------|
| **EntitySchema** | A blueprint defining the structure (typed attributes, constraints) of a type of entity. Aggregate root for schema operations. |
| **Entity** | A concrete instance conforming to an EntitySchema. Carries canonical fields (id, name, type, region, status) and dynamic schema-defined attributes. |
| **AttributeType** | Supported data types: string, enum, map, int, bool, json. |
| **EntityStatus** | Lifecycle state machine: active ↔ inactive → deleted (terminal). |
| **DataResidencyZone** | Geographic boundary for entity data storage: us-east-1, eu-west-1. |
| **Cursor** | Opaque pagination token encoding (created_at, id) tuple for cursor-based listing. |
| **Optimistic Concurrency** | Version field on Entity; updates require ExpectedVersion to match current version or return ErrStaleVersion (HTTP 409). |
| **ImmutableFields** | Fields that cannot change after creation: id, region, data_residency_zone, type, created_at. |
| **Transactional Outbox** | Pattern for reliable event publication: domain event is saved to outbox_messages table within the same DB transaction as the aggregate mutation, then asynchronously relayed to NATS. |
| **IdempotencyKey** | Client-supplied key (7-day TTL) ensuring create-once semantics. Duplicate requests return the existing entity without side effects. |
| **UnitOfWork** | Transactional boundary spanning aggregate persistence + outbox event persistence. |

### Domain Events (Owned by this context)

| Event | When Fired |
|-------|-----------|
| `entitymanagement.schema.defined` | New EntitySchema created with typed attributes |
| `entitymanagement.schema.updated` | Existing EntitySchema attributes/version changed |
| `entitymanagement.entity.created` | New Entity instance created (NOT on idempotent replay) |
| `entitymanagement.entity.read` | Entity retrieved by ID (fire-and-forget observability event) |
| `entitymanagement.entity.updated` | Entity mutated via optimistic concurrency (includes changed_fields) |
| `entitymanagement.entity.soft_deleted` | Entity soft-deleted (deleted_at set, status → deleted) |
| `entitymanagement.entity.hard_deleted` | Soft-deleted entity permanently removed from DB |
| `entitymanagement.entity.restored` | Soft-deleted entity restored (deleted_at cleared, status → active) |
| `entitymanagement.entities.queried` | Paginated list query executed |
| `entitymanagement.invalid_cursor` | Invalid/tampered cursor token provided |
| `entitymanagement.residency.region_routed` | Entity routed to specific data residency zone |
| `entitymanagement.outbox.event_published` | Outbox relay successfully delivered event to NATS |
| `entitymanagement.outbox.event_failed` | Outbox event exhausted retries (dead letter) |
| `entitymanagement.app.started` | Application initialization complete |
| `entitymanagement.app.startup_failed` | Application initialization failed |

### Integration Patterns

| Pattern | Partner Context | Details |
|---------|---------------|---------|
| **Customer-Supplier** | Downstream consumers of `entitymanagement.*` events | NATS pub/sub: entity.created → Billing, Search, Notification; entity.updated → SearchIndexer, AuditLog, WebhookDispatcher; entity.soft_deleted → BillingContext, SearchContext, LifecycleContext |
| **Shared Kernel** | ResidencyContext | DataResidencyZone mapping (region→zone) is shared domain logic |
| **Anti-Corruption Layer** | Postgres persistence via adapter pattern | Port interfaces (EntityRepository, SchemaRepository) defined in domain layer; Postgres implementations in adapters layer shield domain from SQL |
| **Open-Host Service** | HTTP API (REST over chi) | All CRUD operations exposed via REST endpoints with uniform error responses |

### Multi-Cloud Constraints

1. **Data Residency**: Entities are tagged with DataResidencyZone based on region mapping (us-east-1 → ZoneUSEast1, eu-west-1 → ZoneEUWest1). The zone is an immutable field after creation.
2. **Regional Routing**: Observability spans include region attributes. Cross-region reads are tracked via entity.read events.
3. **Latency**: NATS event bus operates within region; cross-region event consumption is handled by downstream consumers.
4. **GDPR/CCPA Compliance**: Hard-delete events (`entitymanagement.entity.hard_deleted`) are published for compliance erasure confirmation.
