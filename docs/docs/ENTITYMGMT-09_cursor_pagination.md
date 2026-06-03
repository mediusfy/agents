

# ENTITYMGMT-09: Cursor-Based Pagination & Multi-Field Filtering

## Story

As a user, I want to list entities with cursor-based pagination and multi-field filtering so that I can efficiently page through large result sets and filter by specific criteria.

## Gherkin Scenarios

1. **Cursor-based pagination**: `GET /api/v1/entities?schema_id=sch-customer&limit=20` returns 20 entities with `next_cursor` token encoding `(created_at, id)` tuple.
2. **Next page via cursor**: `GET /api/v1/entities?schema_id=sch-customer&limit=20&cursor=<token>` returns next 20 entities with no duplicates.
3. **Multi-field AND filtering**: `?filter=status==active&filter=region~eu` returns only entities matching ALL filters.
4. **Limit min clamping**: `limit=0` defaults to 1.
5. **Limit max clamping**: `limit=200` caps at 100.
6. **Invalid cursor**: Returns `ErrInvalidCursor` with HTTP 400.
7. **Include soft-deleted**: `include_deleted=true` includes soft-deleted entities.

## Architecture

### Database Layer (PostgreSQL)

**Files:**
- `entity-management/database/migrations/ENTITYMGMT-09_000_cursor_pagination_filtering.up.sql`
- `entity-management/database/migrations/ENTITYMGMT-09_000_cursor_pagination_filtering.down.sql`

**Key Functions:**
- `encode_cursor_token(created_at, id)` — Base64-encodes `(created_at, id)` tuple
- `decode_cursor_token(token)` — Decodes base64 token back to `(created_at, id)`
- `build_filter_clause(field, op, param_idx)` — Generates parameterized SQL WHERE clause
- `list_entities_cursor(schema_id, limit, cursor, filters[], include_deleted)` — Main pagination function
- `list_entities_cursor_with_meta(...)` — Application-facing wrapper with limit+1 logic

**Key Indexes:**
- `idx_entities_schema_created_id` — Composite B-tree `(schema_id, created_at DESC, id DESC)` for cursor ordering
- `idx_entities_schema_status_filter` — Composite for `status==X` filter pattern
- `idx_entities_schema_region_filter` — Composite for `region~X` filter pattern  
- `idx_entities_schema_status_region` — Composite for multi-field `status+region` filter
- `idx_entities_attributes_gin` — GIN index for JSONB attribute filtering

### Application Layer (Go)

**Files:**
- `internal/application/list_entity.go` — `ListEntitiesUseCase` orchestrates pagination
- `internal/domain/types.go` — Added `EntitiesQueried` and `InvalidCursorProvided` events
- `internal/ports/event_publisher.go` — `PublishEntitiesQueried` and `PublishInvalidCursorProvided`
- `cmd/server/main.go` — Wired `eventPublisher` into `ListEntitiesUseCase`

### Caching (Redis)

**File:** `entity-management/config/redis.conf`

- Cursor token cache (24h TTL)
- Entity page cache (60s TTL, optional)
- Request idempotency cache (7d TTL, secondary to DB)

## Domain Events

### `entitymanagement.entities.queried`
Published on successful paginated list query.
- **Owner:** EntityManagement context
- **Consumers:** ObservabilityContext (query performance, traffic patterns)
- **Payload:** `{schema_id, limit, filters_applied, has_cursor, has_next_page, total_count, duration_ms}`

### `entitymanagement.invalid_cursor`
Published on invalid/expired/tampered cursor token.
- **Owner:** EntityManagement context  
- **Consumers:** SecurityContext (tamper detection), ObservabilityContext (error rate)
- **Payload:** `{provided_cursor, schema_id, error_detail, request_origin}`

## Seed Data

**File:** `entity-management/database/seeds/ENTITYMGMT-09_000_cursor_pagination_filtering_seed.sql`

- 100 Customer entities with varied status (70 active, 20 inactive, 10 deleted) and regions (eu-west-1, us-east-1, us-west-2, ap-southeast-1, eu-central-1)
- Created_at spans 90 days for realistic pagination testing
- Includes soft-deleted entities for `include_deleted` testing

## Verification

Run `SELECT * FROM verify_cursor_pagination();` after seeding to validate:
- First page returns correct count
- Ordering is consistent (created_at DESC, id DESC)
- Multi-field filtering returns correct subset
- Cursor encode/decode roundtrip works
- Invalid cursor detection works
