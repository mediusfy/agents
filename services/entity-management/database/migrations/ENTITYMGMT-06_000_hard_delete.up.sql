-- Migration: ENTITYMGMT-06_000_hard_delete.up.sql
-- Story: ENTITYMGMT-06 — User permanently removes a soft-deleted entity (hard-delete)
-- Bounded Context: Entity Management
--
-- Prerequisites:
--   - ENTITYMGMT-01_000_schema_definition.up.sql
--     (outbox_events table, update_modified_column() function)
--   - ENTITYMGMT-02_000_create_entities.up.sql
--     (entities table with deleted_at, entity_status ENUM including 'deleted',
--      request_idempotency table with ON DELETE CASCADE FK to entities)
--   - ENTITYMGMT-05_000_soft_delete_restore.up.sql
--     (soft_delete_entity(), row_to_entity_json(), outbox events for soft-delete)
--
-- ============================================================================
-- Gherkin Scenarios
-- ============================================================================
--
-- SCENARIO 1: Successful hard-delete (permanent removal)
--   Given entity "ent-001" is soft-deleted (deleted_at set, status="deleted")
--   When a DELETE /api/v1/entities/ent-001?permanent=true request is sent
--   Then the entity record is permanently removed from the database
--     And an entitymanagement.entity.hard_deleted event is written to the outbox
--     And HTTP 200 is returned with {"status": "hard_deleted", "entity_id": "ent-001"}
--
-- SCENARIO 2: Active entity cannot be hard-deleted
--   Given entity "ent-002" is active (deleted_at is NULL)
--   When a hard-delete is attempted on entity "ent-002"
--   Then ErrNotDeleted is returned (HTTP 400)
--     And message: "entity must be soft-deleted before hard deletion"
--     And no data is modified
--
-- SCENARIO 3: Non-existent entity returns 404
--   Given entity "ent-999" does not exist
--   When a hard-delete is attempted
--   Then HTTP 404 Not Found is returned
--
-- ============================================================================
-- Domain Events (transactional outbox, reusing outbox_events from ENTITYMGMT-01)
-- ============================================================================
--
-- entitymanagement.entity.hard_deleted — Published when a soft-deleted entity
--   is permanently removed from the database. Written to outbox within the same
--   transaction as the DELETE. NOT emitted on error scenarios (SCENARIO 2, 3).
--
--   Owned by: EntityManagement context
--
--   Payload per Gherkin spec:
--   {
--     "event_id": "<uuid>",
--     "entity_id": "ent-001",
--     "entity_name": "Alice",
--     "region": "eu-west-1",
--     "deleted_at": "<original soft-delete timestamp>",
--     "hard_deleted_at": "<current timestamp>",
--     "occurred_at": "<timestamp>"
--   }
--
--   Consumers:
--     ComplianceContext  — Confirm GDPR/CCPA erasure
--     AuditLog           — Permanent deletion record
--     ResidencyContext   — Confirm regional data removal
--
-- ============================================================================
-- DDL changes in this migration:
--   1. hard_delete_entity() — Permanently removes a soft-deleted entity
--   2. enqueue_entity_hard_deleted_event() — Outbox event for hard-delete
--   3. hard_delete_entity_with_outbox() — Combined atomic delete+event
--   4. prune_orphaned_idempotency() — Clean up idempotency keys for deleted entities
--
-- ============================================================================
-- NO table schema changes: hard-delete uses the existing entities table
-- and outbox_events table. Only new functions are added.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. FUNCTION: hard_delete_entity()
--
-- Permanently removes a soft-deleted entity from the database.
-- The entity MUST already be soft-deleted (deleted_at IS NOT NULL).
--
-- Gherkin SCENARIO 1 mapping:
--   "entity 'ent-001' is soft-deleted (deleted_at set, status='deleted')"
--     → deleted_at IS NOT NULL, status = 'deleted'
--   "the entity record is permanently removed from the database"
--     → DELETE FROM entities WHERE id = p_entity_id AND deleted_at IS NOT NULL
--
-- Gherkin SCENARIO 2 mapping:
--   "entity 'ent-002' is active (deleted_at is NULL)"
--     → deleted_at IS NULL → returns ERR_NOT_DELETED
--   "no data is modified"
--     → DELETE is not executed (the WHERE clause excludes active entities)
--
-- Gherkin SCENARIO 3 mapping:
--   "entity 'ent-999' does not exist"
--     → SELECT ... FOR UPDATE returns no rows → returns ERR_ENTITY_NOT_FOUND
--   "HTTP 404 Not Found is returned"
--     → Application maps ERR_ENTITY_NOT_FOUND to HTTP 404
--
-- Validations:
--   - Entity must exist                     → ERR_ENTITY_NOT_FOUND (SCENARIO 3)
--   - Entity must be soft-deleted           → ERR_NOT_DELETED (SCENARIO 2)
--   - Entity status must be 'deleted'       → ERR_INVALID_STATUS (defensive)
--
-- Returns the deleted entity's metadata (name, region, deleted_at) so the
-- caller can construct the outbox event payload.
--
-- Cascading cleanup:
--   - request_idempotency rows referencing this entity are auto-deleted
--     via ON DELETE CASCADE FK on request_idempotency(entity_id)
--   - outbox_events rows are NOT deleted (they reference aggregate_id as
--     a TEXT field, not a FK) — event history is preserved
--
-- Usage:
--   SELECT * FROM hard_delete_entity(
--     p_entity_id := 'e0000001-0000-4000-8000-000000000001'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION hard_delete_entity(
    p_entity_id UUID
)
RETURNS TABLE(
    success         BOOLEAN,
    deleted_entity  JSONB,
    error_code      TEXT,
    error_message   TEXT
) AS $$
DECLARE
    v_entity    entities%ROWTYPE;
    v_now       TIMESTAMPTZ;
BEGIN
    v_now := NOW();

    -- ======================================================================
    -- Step 1: Lock and fetch the entity with a row-level lock
    -- This prevents race conditions where one request soft-deletes while
    -- another attempts to hard-delete concurrently.
    --
    -- Gherkin SCENARIO 3: "entity 'ent-999' does not exist"
    --   → SELECT ... FOR UPDATE returns no rows → NOT FOUND → 404
    -- ======================================================================
    SELECT * INTO v_entity
    FROM entities
    WHERE id = p_entity_id
    FOR UPDATE;  -- Row-level lock prevents concurrent modification

    IF NOT FOUND THEN
        -- SCENARIO 3: Entity does not exist — HTTP 404
        RETURN QUERY SELECT
            FALSE                                   AS success,
            NULL::JSONB                             AS deleted_entity,
            'ERR_ENTITY_NOT_FOUND'                  AS error_code,
            format('Entity with ID %s not found', p_entity_id::TEXT) AS error_message;
        RETURN;
    END IF;

    -- ======================================================================
    -- Step 2: Validate — Gherkin SCENARIO 2
    -- "Given entity 'ent-002' is active (deleted_at is NULL)"
    -- "Then ErrNotDeleted is returned (HTTP 400)"
    --
    -- If deleted_at is NULL, the entity has NOT been soft-deleted yet
    -- and cannot be hard-deleted. The entity must first be soft-deleted
    -- via the DELETE endpoint (without ?permanent=true).
    --
    -- Error message per Gherkin: "entity must be soft-deleted before hard deletion"
    -- ======================================================================
    IF v_entity.deleted_at IS NULL THEN
        RETURN QUERY SELECT
            FALSE                                   AS success,
            NULL::JSONB                             AS deleted_entity,
            'ERR_NOT_DELETED'                       AS error_code,
            format('Entity %s (%s) is not soft-deleted. '
                   || 'Entity must be soft-deleted before hard deletion. '
                   || 'Current status: %s',
                   v_entity.name,
                   v_entity.id,
                   v_entity.status)                 AS error_message;
        RETURN;
    END IF;

    -- ======================================================================
    -- Step 2b: Validate status is 'deleted' (defensive check)
    -- The entity's status must be 'deleted' to be hard-deleted.
    -- This catches inconsistent states where deleted_at is set but status
    -- isn't 'deleted'.
    -- ======================================================================
    IF v_entity.status != 'deleted'::entity_status THEN
        RETURN QUERY SELECT
            FALSE                                   AS success,
            NULL::JSONB                             AS deleted_entity,
            'ERR_INVALID_STATUS'                    AS error_code,
            format('Entity %s (%s) has deleted_at set but status is %s. '
                   || 'Expected status: deleted. Cannot hard-delete in this state.',
                   v_entity.name,
                   v_entity.id,
                   v_entity.status)                 AS error_message;
        RETURN;
    END IF;

    -- ======================================================================
    -- Step 3: Permanently remove the entity
    --
    -- Gherkin SCENARIO 1:
    --   "the entity record is permanently removed from the database"
    --     → DELETE FROM entities WHERE id = p_entity_id AND deleted_at IS NOT NULL
    --
    -- Note: request_idempotency rows with FK to this entity are auto-deleted
    -- via ON DELETE CASCADE (defined in ENTITYMGMT-02).
    --
    -- We use DELETE ... RETURNING to capture the pre-deletion data for the
    -- outbox event payload. This happens atomically within the transaction.
    -- ======================================================================
    DELETE FROM entities
    WHERE id = p_entity_id
      AND deleted_at IS NOT NULL  -- Safety: double-verify soft-delete status
    RETURNING * INTO v_entity;

    -- ======================================================================
    -- Step 4: Return the deleted entity's metadata for outbox event payload
    --
    -- Gherkin SCENARIO 1:
    --   "HTTP 200 is returned with {"status": "hard_deleted", "entity_id": "ent-001"}"
    --     → The application layer extracts:
    --       - deleted_entity->>'id'       → entity_id
    --       - deleted_entity->>'name'     → entity_name
    --       - deleted_entity->>'region'   → region
    --       - deleted_entity->>'deleted_at' → original soft-delete timestamp
    --       - NOW()                       → hard_deleted_at
    --
    -- The entity JSON includes ALL fields that existed before deletion,
    -- allowing the outbox event to capture the full picture.
    -- ======================================================================
    RETURN QUERY SELECT
        TRUE                        AS success,
        jsonb_build_object(
            'id',                  v_entity.id::TEXT,
            'schema_id',           v_entity.schema_id::TEXT,
            'schema_version',      v_entity.schema_version,
            'name',                v_entity.name,
            'type',                v_entity.type,
            'region',              v_entity.region,
            'data_residency_zone', v_entity.data_residency_zone,
            'status',              v_entity.status,
            'version',             v_entity.version,
            'attributes',          v_entity.attributes,
            'metadata',            v_entity.metadata,
            'created_at',          v_entity.created_at,
            'updated_at',          v_entity.updated_at,
            'deleted_at',          v_entity.deleted_at,
            'hard_deleted_at',     v_now           -- When the permanent removal occurred
        ) AS deleted_entity,
        NULL::TEXT                  AS error_code,
        NULL::TEXT                  AS error_message;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 2. FUNCTION: enqueue_entity_hard_deleted_event()
--
-- Enqueues an entitymanagement.entity.hard_deleted CloudEvent to the
-- outbox_events table. Called by the application layer or by
-- hard_delete_entity_with_outbox() within the same database transaction
-- (transactional outbox pattern).
--
-- Gherkin SCENARIO 1 mapping:
--   "an entitymanagement.entity.hard_deleted event is written to the outbox"
--     → This function inserts into outbox_events with
--       event_type = 'entitymanagement.entity.hard_deleted'
--
-- Gherkin SCENARIO 2 & 3 mapping:
--   "no event is written" → This function is NOT called when
--     hard_delete_entity() returns an error (SCENARIO 2: ERR_NOT_DELETED,
--     SCENARIO 3: ERR_ENTITY_NOT_FOUND).
--
-- Payload per Gherkin spec:
--   {
--     "event_id": "<uuid>",
--     "entity_id": "ent-001",
--     "entity_name": "Alice",
--     "region": "eu-west-1",
--     "deleted_at": "<original soft-delete timestamp>",
--     "hard_deleted_at": "<current timestamp>",
--     "occurred_at": "<timestamp>"
--   }
--
-- Parameters:
--   p_entity_id       UUID         — The entity being permanently removed
--   p_entity_name     VARCHAR(512) — Entity name at time of deletion
--   p_region          VARCHAR(64)  — Entity region
--   p_deleted_at      TIMESTAMPTZ  — Original soft-delete timestamp (from deleted_at)
--   p_hard_deleted_at TIMESTAMPTZ  — When the permanent removal occurred
--
-- Returns:
--   UUID — The event_id (not the outbox row ID) for traceability
--
-- Usage:
--   PERFORM enqueue_entity_hard_deleted_event(
--     p_entity_id       := 'e0000001-...',
--     p_entity_name     := 'Alice',
--     p_region          := 'eu-west-1',
--     p_deleted_at      := '2025-06-01T12:00:00Z',
--     p_hard_deleted_at := NOW()
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_entity_hard_deleted_event(
    p_entity_id       UUID,
    p_entity_name     VARCHAR(512),
    p_region          VARCHAR(64),
    p_deleted_at      TIMESTAMPTZ,
    p_hard_deleted_at TIMESTAMPTZ
)
RETURNS UUID AS $$
DECLARE
    v_event_id    UUID;
    v_occurred_at TIMESTAMPTZ;
BEGIN
    v_event_id    := gen_random_uuid();
    v_occurred_at := NOW();

    INSERT INTO outbox_events (
        id,
        event_id,
        aggregate_id,
        aggregate_type,
        event_type,
        source,
        subject,
        payload,
        status,
        retry_count,
        last_error,
        created_at
    ) VALUES (
        gen_random_uuid()::TEXT,
        v_event_id::TEXT,
        p_entity_id::TEXT,
        'entity',
        'entitymanagement.entity.hard_deleted',  -- CloudEvents type per Gherkin spec
        '/entity-manager',                        -- Source identifier for EntityManagement context
        'entity/' || p_entity_id::TEXT,           -- Subject for event routing
        jsonb_build_object(
            'event_id',        v_event_id::TEXT,
            'entity_id',       p_entity_id::TEXT,
            'entity_name',     p_entity_name,
            'region',          p_region,
            'deleted_at',      p_deleted_at,         -- Original soft-delete timestamp
            'hard_deleted_at', p_hard_deleted_at,     -- When permanent removal occurred
            'occurred_at',     v_occurred_at
        ),
        'pending',   -- Not yet processed by the outbox relay
        0,           -- Initial retry count
        NULL,        -- No error yet
        v_occurred_at
    );

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 3. FUNCTION: hard_delete_entity_with_outbox()
--
-- Combined atomic operation: permanently removes a soft-deleted entity AND
-- enqueues the entitymanagement.entity.hard_deleted event ALL within a single
-- database transaction.
--
-- This is the application-layer friendly entry point that wraps the entire
-- hard-delete workflow. It is what the DELETE /api/v1/entities/{id}?permanent=true
-- handler calls.
--
-- Gherkin SCENARIO 1:
--   Calls hard_delete_entity() → succeeds → calls
--   enqueue_entity_hard_deleted_event() → returns success with entity data
--   and event ID.
--
-- Gherkin SCENARIO 2:
--   Calls hard_delete_entity() → fails (entity not soft-deleted) → returns
--   ERR_NOT_DELETED WITHOUT calling enqueue_entity_hard_deleted_event().
--   "no data is modified" → DELETE was not executed.
--
-- Gherkin SCENARIO 3:
--   Calls hard_delete_entity() → fails (entity not found) → returns
--   ERR_ENTITY_NOT_FOUND WITHOUT calling enqueue_entity_hard_deleted_event().
--
-- Returns:
--   success         BOOLEAN   — Whether the hard-delete succeeded
--   deleted_entity  JSONB     — Full entity state as it existed before deletion
--                                (NULL if failed). Contains hard_deleted_at field.
--   event_id        UUID      — Outbox event ID (NULL if failed)
--   error_code      TEXT      — Machine-readable error:
--                                NULL (success), 'ERR_NOT_DELETED',
--                                'ERR_ENTITY_NOT_FOUND', 'ERR_INVALID_STATUS'
--   error_message   TEXT      — Human-readable error description
--
-- Usage:
--   SELECT * FROM hard_delete_entity_with_outbox(
--     p_entity_id := 'e0000001-0000-4000-8000-000000000001'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION hard_delete_entity_with_outbox(
    p_entity_id UUID
)
RETURNS TABLE(
    success         BOOLEAN,
    deleted_entity  JSONB,
    event_id        UUID,
    error_code      TEXT,
    error_message   TEXT
) AS $$
DECLARE
    v_result          RECORD;
    v_entity_id       UUID;
    v_entity_name     VARCHAR(512);
    v_region          VARCHAR(64);
    v_deleted_at      TIMESTAMPTZ;
    v_hard_deleted_at TIMESTAMPTZ;
    v_event_id        UUID;
BEGIN
    -- ======================================================================
    -- Step 1: Attempt the hard-delete
    -- This will either succeed (SCENARIO 1) or fail (SCENARIO 2 or 3).
    -- ======================================================================
    SELECT * INTO v_result
    FROM hard_delete_entity(p_entity_id := p_entity_id);

    IF NOT v_result.success THEN
        -- SCENARIO 2: Entity not soft-deleted (ERR_NOT_DELETED)
        -- SCENARIO 3: Entity not found (ERR_ENTITY_NOT_FOUND)
        -- NO event is emitted in either case.
        RETURN QUERY SELECT
            v_result.success,
            v_result.deleted_entity,
            NULL::UUID        AS event_id,       -- No event emitted
            v_result.error_code,
            v_result.error_message;
        RETURN;
    END IF;

    -- ======================================================================
    -- Step 2: Extract fields needed for the outbox event payload
    -- ======================================================================
    v_entity_id       := p_entity_id;
    v_entity_name     := v_result.deleted_entity ->> 'name';
    v_region          := v_result.deleted_entity ->> 'region';
    v_deleted_at      := (v_result.deleted_entity ->> 'deleted_at')::TIMESTAMPTZ;
    v_hard_deleted_at := (v_result.deleted_entity ->> 'hard_deleted_at')::TIMESTAMPTZ;

    -- ======================================================================
    -- Step 3: Enqueue the entitymanagement.entity.hard_deleted event
    --
    -- Gherkin SCENARIO 1:
    --   "an entitymanagement.entity.hard_deleted event is written to the outbox"
    -- ======================================================================
    v_event_id := enqueue_entity_hard_deleted_event(
        p_entity_id       := v_entity_id,
        p_entity_name     := v_entity_name,
        p_region          := v_region,
        p_deleted_at      := v_deleted_at,
        p_hard_deleted_at := v_hard_deleted_at
    );

    -- ======================================================================
    -- Step 4: Return success with deleted entity data and event ID
    --
    -- Gherkin SCENARIO 1:
    --   "HTTP 200 is returned with {"status": "hard_deleted", "entity_id": "ent-001"}"
    --     → The application extracts:
    --       deleted_entity->>'id'    → entity_id
    --       event_id                 → outbox trace ID
    -- ======================================================================
    RETURN QUERY SELECT
        TRUE                       AS success,
        v_result.deleted_entity    AS deleted_entity,
        v_event_id                 AS event_id,
        NULL::TEXT                 AS error_code,
        NULL::TEXT                 AS error_message;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 4. FUNCTION: prune_orphaned_idempotency()
--
-- Cleans up idempotency key records that reference entities which have been
-- hard-deleted. Under normal operation, ON DELETE CASCADE on the
-- request_idempotency(entity_id) FK handles this automatically when
-- hard_delete_entity() removes the entity row.
--
-- However, this function serves as a safety net for:
--   - Manual database operations that bypass the hard_delete_entity() function
--   - Data integrity audits
--   - Recovery from edge cases where cascading deletes were not triggered
--
-- Returns the number of orphaned rows cleaned up.
--
-- Usage:
--   SELECT prune_orphaned_idempotency();
-- ============================================================================
CREATE OR REPLACE FUNCTION prune_orphaned_idempotency()
RETURNS INTEGER AS $$
DECLARE
    v_deleted INTEGER;
BEGIN
    DELETE FROM request_idempotency ri
    WHERE NOT EXISTS (
        SELECT 1 FROM entities e
        WHERE e.id = ri.entity_id
    );
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 5. INDEXES for hard-delete query patterns
-- ============================================================================

-- Index for the hard-delete lookup pattern: find soft-deleted entities
-- The hard-delete function queries: WHERE id = $1 AND deleted_at IS NOT NULL
-- The existing primary key index on (id) covers the id lookup, and this
-- partial index optimizes the deleted_at check within the hard-delete path.
CREATE INDEX IF NOT EXISTS idx_entities_hard_deletable
    ON entities(id, deleted_at)
    WHERE deleted_at IS NOT NULL;

-- Index for bulk hard-delete operations (retention policy enforcement)
-- Allows efficient batch deletion of entities soft-deleted before a date:
--   DELETE FROM entities WHERE deleted_at < NOW() - INTERVAL '30 days'
-- This index covers that query pattern.
CREATE INDEX IF NOT EXISTS idx_entities_deleted_at_bulk_hard_delete
    ON entities(deleted_at ASC)
    WHERE deleted_at IS NOT NULL;

-- Index for GDPR erasure queries: find entities by region + soft-delete status
-- Allows efficient queries like:
--   "Find all entities in eu-west-1 that are eligible for GDPR erasure"
CREATE INDEX IF NOT EXISTS idx_entities_region_deleted
    ON entities(region, deleted_at ASC)
    WHERE deleted_at IS NOT NULL;

-- Outbox relay optimization: prefix index for hard_deleted events
-- Speeds up the outbox relay when polling for hard_deleted events
CREATE INDEX IF NOT EXISTS idx_outbox_hard_deleted_events
    ON outbox_events(created_at ASC, event_type)
    WHERE event_type = 'entitymanagement.entity.hard_deleted';

-- ============================================================================
-- 6. Bootstrap: Return migration summary
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE 'ENTITYMGMT-06 migration applied successfully.';
    RAISE NOTICE '  - Functions: hard_delete_entity, enqueue_entity_hard_deleted_event,';
    RAISE NOTICE '               hard_delete_entity_with_outbox, prune_orphaned_idempotency';
    RAISE NOTICE '  - Outbox event: entitymanagement.entity.hard_deleted';
    RAISE NOTICE '  - Indexes: idx_entities_hard_deletable, idx_entities_deleted_at_bulk_hard_delete,';
    RAISE NOTICE '             idx_entities_region_deleted, idx_outbox_hard_deleted_events';
    RAISE NOTICE '';
    RAISE NOTICE 'Gherkin coverage:';
    RAISE NOTICE '  SCENARIO 1 (hard-delete success):       ✅ hard_delete_entity_with_outbox()';
    RAISE NOTICE '  SCENARIO 2 (not soft-deleted rejection): ✅ hard_delete_entity() → ERR_NOT_DELETED';
    RAISE NOTICE '  SCENARIO 3 (not found):                  ✅ hard_delete_entity() → ERR_ENTITY_NOT_FOUND';
END;
$$;

COMMIT;
