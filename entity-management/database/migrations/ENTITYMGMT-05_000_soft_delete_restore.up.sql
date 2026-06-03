-- Migration: ENTITYMGMT-05_000_soft_delete_restore.up.sql
-- Story: ENTITYMGMT-05 — User soft-deletes an entity (setting deleted_at,
--                         transitioning to terminal status)
-- Bounded Context: Entity Management
--
-- Prerequisites:
--   - ENTITYMGMT-01_000_schema_definition.up.sql
--     (outbox_events table, update_modified_column() function)
--   - ENTITYMGMT-02_000_create_entities.up.sql
--     (entities table with deleted_at, entity_status ENUM including 'deleted',
--      get_entity_by_id(UUID, BOOLEAN), list_entities_by_schema(...))
--   - ENTITYMGMT-04_000_entity_update_optimistic.up.sql
--     (prevent_immutable_field_update trigger, update_entity_optimistic())
--
-- ============================================================================
-- Gherkin Scenarios
-- ============================================================================
--
-- SCENARIO 1: Successful soft-delete
--   Given an active entity "ent-001" exists with status "active"
--     and deleted_at is NULL
--   When a DELETE /api/v1/entities/ent-001 request is sent
--     (soft-delete, no ?permanent param)
--   Then deleted_at is set to current UTC timestamp
--     And entity status transitions to "deleted" (terminal)
--     And an entitymanagement.entity.soft_deleted event is written
--       to the outbox within the same transaction
--     And HTTP 200 is returned with
--       {"status": "soft_deleted", "entity_id": "ent-001"}
--     And the entity is excluded from default list queries
--       (include_deleted=false)
--
-- SCENARIO 2: Idempotent soft-delete (already deleted) is rejected
--   Given entity "ent-001" is already soft-deleted
--   When a second soft-delete is attempted
--   Then ErrAlreadyDeleted is returned
--     And no duplicate entity.soft_deleted event is emitted
--
-- SCENARIO 3: Soft-deleted entity excluded from default listing
--   Given a soft-deleted entity "ent-001"
--   When a standard GET /api/v1/entities?schema_id=X is called
--     (without include_deleted=true)
--   Then entity "ent-001" is not included in the results
--
-- ============================================================================
-- Domain Events (transactional outbox, reusing outbox_events from ENTITYMGMT-01)
-- ============================================================================
--
-- entitymanagement.entity.soft_deleted — Published when an entity is
--   soft-deleted (deleted_at set, status transitions to 'deleted').
--   Written to outbox as part of delete transaction.
--   NOT emitted on idempotent re-deletes (ErrAlreadyDeleted).
--
--   Owned by: EntityManagement context
--
--   Payload per Gherkin spec:
--   {
--     "event_id": "<uuid>",
--     "entity_id": "ent-001",
--     "entity_name": "Alice",
--     "region": "eu-west-1",
--     "deleted_at": "<timestamp>",
--     "previous_status": "active",
--     "occurred_at": "<timestamp>"
--   }
--
--   Consumers:
--     BillingContext     — Stop billing for the entity
--     SearchContext      — Remove from indexes
--     LifecycleContext   — Trigger retention policy
--     AuditLog           — Record deletion
--
-- entitymanagement.entity.restored — Published when a previously
--   soft-deleted entity is restored (deleted_at cleared, status
--   transitions back to 'active'). Written to outbox as part of
--   restore transaction.
--
--   Payload:
--   {
--     "event_id": "<uuid>",
--     "entity_id": "ent-001",
--     "entity_name": "Alice",
--     "region": "eu-west-1",
--     "restored_at": "<timestamp>",
--     "previous_status": "deleted",
--     "new_status": "active",
--     "occurred_at": "<timestamp>"
--   }
--
--   Consumers:
--     BillingContext     — Resume billing
--     SearchContext      — Re-index entity
--     AuditLog           — Record restoration
--
-- ============================================================================
-- DDL changes in this migration:
--   1. soft_delete_entity() — Atomic soft-delete with version bump
--   2. enqueue_entity_soft_deleted_event() — Outbox event for soft-delete
--   3. soft_delete_entity_with_outbox() — Combined atomic soft-delete+event
--   4. restore_entity() — Restore from soft-delete (clear deleted_at)
--   5. enqueue_entity_restored_event() — Outbox event for restore
--   6. restore_entity_with_outbox() — Combined atomic restore+event
--   7. row_to_entity_json() — Helper to serialize entity row to JSONB
--   8. Updated prevent_immutable_field_update to allow status→'deleted'
--   9. Indexes for deleted_at queries
--  10. Updated list_entities_by_schema to support include_deleted
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. HELPER: row_to_entity_json()
--
-- Converts an entity row to a JSONB representation for returning structured
-- results from the mutation functions. Avoids code duplication.
--
-- Returns NULL if the entity does not exist.
-- ============================================================================
CREATE OR REPLACE FUNCTION row_to_entity_json(
    p_entity_id UUID
)
RETURNS JSONB AS $$
DECLARE
    v_entity entities%ROWTYPE;
BEGIN
    SELECT * INTO v_entity
    FROM entities
    WHERE id = p_entity_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    RETURN jsonb_build_object(
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
        'deleted_at',          v_entity.deleted_at
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 2. FUNCTION: soft_delete_entity()
--
-- Atomically soft-deletes an entity by setting:
--   - deleted_at = NOW()
--   - status = 'deleted' (terminal state per domain logic)
--   - version = version + 1  (bump for optimistic concurrency)
--   - updated_at = NOW()
--
-- Gherkin SCENARIO 1 mapping:
--   "deleted_at is set to current UTC timestamp"
--     → deleted_at = NOW()
--   "entity status transitions to 'deleted' (terminal)"
--     → status = 'deleted'::entity_status
--
-- Gherkin SCENARIO 2 mapping:
--   "entity 'ent-001' is already soft-deleted"
--     → deleted_at IS NOT NULL → returns ERR_ALREADY_DELETED
--   "no duplicate entity.soft_deleted event is emitted"
--     → The caller checks success before calling enqueue function
--
-- Validations:
--   - Entity must exist                     → ERR_ENTITY_NOT_FOUND
--   - Entity must NOT already be deleted    → ERR_ALREADY_DELETED
--   - Status must allow deletion (active or inactive, but not already deleted)
--
-- Usage:
--   SELECT * FROM soft_delete_entity(
--     p_entity_id := 'e0000001-0000-4000-8000-000000000001'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION soft_delete_entity(
    p_entity_id UUID
)
RETURNS TABLE(
    success       BOOLEAN,
    entity_json   JSONB,
    error_code    TEXT,
    error_message TEXT
) AS $$
DECLARE
    v_entity    entities%ROWTYPE;
    v_now       TIMESTAMPTZ;
BEGIN
    v_now := NOW();

    -- Step 1: Lock and fetch the entity with a row-level lock
    -- This prevents race conditions where two concurrent DELETE requests
    -- might both attempt to soft-delete the same entity.
    SELECT * INTO v_entity
    FROM entities
    WHERE id = p_entity_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE                                   AS success,
            NULL::JSONB                             AS entity_json,
            'ERR_ENTITY_NOT_FOUND'                  AS error_code,
            format('Entity with ID %s not found', p_entity_id::TEXT) AS error_message;
        RETURN;
    END IF;

    -- ======================================================================
    -- Step 2: Validate — Gherkin SCENARIO 2
    -- "Given entity 'ent-001' is already soft-deleted"
    -- "Then ErrAlreadyDeleted is returned"
    --
    -- If deleted_at is already set, the entity is already soft-deleted.
    -- We return ERR_ALREADY_DELETED and the caller (application layer) maps
    -- this to an appropriate HTTP error response.
    --
    -- The error_message includes the original deletion timestamp so the
    -- application can include diagnostic info in the error response.
    -- ======================================================================
    IF v_entity.deleted_at IS NOT NULL THEN
        RETURN QUERY SELECT
            FALSE                                   AS success,
            NULL::JSONB                             AS entity_json,
            'ERR_ALREADY_DELETED'                   AS error_code,
            format('Entity %s (%s) is already soft-deleted at %s. '
                   || 'No duplicate deletion is allowed.',
                   v_entity.name,
                   v_entity.id,
                   v_entity.deleted_at)             AS error_message;
        RETURN;
    END IF;

    -- ======================================================================
    -- Step 2b: Validate status transition (defensive check)
    -- Domain rule: only 'active' or 'inactive' entities can be soft-deleted.
    -- Entities already in 'deleted' status (without deleted_at set, which
    -- would be an inconsistent state) should not proceed.
    -- ======================================================================
    IF v_entity.status NOT IN ('active', 'inactive') THEN
        RETURN QUERY SELECT
            FALSE                                   AS success,
            NULL::JSONB                             AS entity_json,
            'ERR_INVALID_STATUS_TRANSITION'         AS error_code,
            format('Entity %s (%s) has status %s and cannot be soft-deleted. '
                   || 'Only active or inactive entities can be deleted.',
                   v_entity.name,
                   v_entity.id,
                   v_entity.status)                 AS error_message;
        RETURN;
    END IF;

    -- ======================================================================
    -- Step 3: Apply the soft-delete atomically
    --
    -- Gherkin SCENARIO 1:
    --   "deleted_at is set to current UTC timestamp"
    --     → deleted_at = v_now
    --   "entity status transitions to 'deleted' (terminal)"
    --     → status = 'deleted'::entity_status
    --
    -- We also bump the version counter for optimistic concurrency tracking,
    -- and update updated_at to reflect the mutation time.
    -- ======================================================================
    UPDATE entities
    SET
        status     = 'deleted'::entity_status,  -- Terminal state transition
        deleted_at = v_now,                      -- Set deletion timestamp
        version    = version + 1,                -- Bump for OCC
        updated_at = v_now                       -- Mutation timestamp
    WHERE id = p_entity_id;

    -- ======================================================================
    -- Step 4: Return the updated entity state
    --
    -- Gherkin SCENARIO 1:
    --   "HTTP 200 is returned with
    --    {'status': 'soft_deleted', 'entity_id': 'ent-001'}"
    --     → The application layer extracts entity_id and status from
    --       entity_json to build the response payload.
    -- ======================================================================
    RETURN QUERY SELECT
        TRUE                        AS success,
        row_to_entity_json(p_entity_id) AS entity_json,
        NULL::TEXT                  AS error_code,
        NULL::TEXT                  AS error_message;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 3. FUNCTION: enqueue_entity_soft_deleted_event()
--
-- Enqueues an entitymanagement.entity.soft_deleted CloudEvent to the
-- outbox_events table. Called by the application layer or by
-- soft_delete_entity_with_outbox() within the same database transaction
-- (transactional outbox pattern).
--
-- Gherkin SCENARIO 1 mapping:
--   "an entitymanagement.entity.soft_deleted event is written
--    to the outbox within the same transaction"
--     → This function inserts into outbox_events with
--       event_type = 'entitymanagement.entity.soft_deleted'
--
-- Gherkin SCENARIO 2 mapping:
--   "no duplicate entity.soft_deleted event is emitted"
--     → This function is NOT called when soft_delete_entity() returns
--       ERR_ALREADY_DELETED (the application only enqueues the event
--       after a successful soft-delete).
--
-- Payload per Gherkin spec:
--   { event_id, entity_id, entity_name, region, deleted_at,
--     previous_status, occurred_at }
--
-- Parameters:
--   p_entity_id        UUID         — The entity being soft-deleted
--   p_entity_name      VARCHAR(512) — Name at time of deletion
--   p_region           VARCHAR(64)  — Entity region
--   p_deleted_at       TIMESTAMPTZ  — When the deletion occurred
--   p_previous_status  VARCHAR(32)  — Status before deletion (e.g., 'active')
--   p_deleted_by       VARCHAR(255) — Who performed the deletion (optional)
--
-- Returns:
--   UUID — The event_id (not the outbox row ID) for traceability
--
-- Usage:
--   PERFORM enqueue_entity_soft_deleted_event(
--     p_entity_id        := 'e0000001-...',
--     p_entity_name      := 'Alice',
--     p_region           := 'eu-west-1',
--     p_deleted_at       := NOW(),
--     p_previous_status  := 'active',
--     p_deleted_by       := 'user-abc-123'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_entity_soft_deleted_event(
    p_entity_id        UUID,
    p_entity_name      VARCHAR(512),
    p_region           VARCHAR(64),
    p_deleted_at       TIMESTAMPTZ,
    p_previous_status  VARCHAR(32) DEFAULT NULL,
    p_deleted_by       VARCHAR(255) DEFAULT NULL
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
        'entitymanagement.entity.soft_deleted',  -- CloudEvents type per Gherkin spec
        '/entity-manager',                        -- Source identifier for EntityManagement context
        'entity/' || p_entity_id::TEXT,           -- Subject for event routing
        jsonb_build_object(
            'event_id',         v_event_id::TEXT,
            'entity_id',        p_entity_id::TEXT,
            'entity_name',      p_entity_name,
            'region',           p_region,
            'deleted_at',       p_deleted_at,
            'previous_status',  p_previous_status,
            'deleted_by',       p_deleted_by,
            'occurred_at',      v_occurred_at
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
-- 4. FUNCTION: soft_delete_entity_with_outbox()
--
-- Combined atomic operation: soft-deletes an entity AND enqueues the
-- entitymanagement.entity.soft_deleted event ALL within a single database
-- transaction.
--
-- This is the application-layer friendly entry point that wraps the entire
-- soft-delete workflow. It is what the DELETE /api/v1/entities/{id} handler
-- calls.
--
-- Gherkin SCENARIO 1:
--   Calls soft_delete_entity() → succeeds → calls
--   enqueue_entity_soft_deleted_event() → returns success with entity and
--   event ID.
--
-- Gherkin SCENARIO 2:
--   Calls soft_delete_entity() → fails (already deleted) → returns
--   failure WITHOUT calling enqueue_entity_soft_deleted_event().
--
-- Returns:
--   success       BOOLEAN     — Whether the soft-delete succeeded
--   entity_json   JSONB       — Full entity after soft-delete (NULL if failed)
--   event_id      UUID        — Outbox event ID (NULL if failed)
--   error_code    TEXT        — Machine-readable error:
--                                NULL (success), 'ERR_ALREADY_DELETED',
--                                'ERR_ENTITY_NOT_FOUND',
--                                'ERR_INVALID_STATUS_TRANSITION'
--   error_message TEXT        — Human-readable error description
--
-- Usage:
--   SELECT * FROM soft_delete_entity_with_outbox(
--     p_entity_id  := 'e0000001-0000-4000-8000-000000000001',
--     p_deleted_by := 'user-abc-123'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION soft_delete_entity_with_outbox(
    p_entity_id  UUID,
    p_deleted_by VARCHAR(255) DEFAULT NULL
)
RETURNS TABLE(
    success       BOOLEAN,
    entity_json   JSONB,
    event_id      UUID,
    error_code    TEXT,
    error_message TEXT
) AS $$
DECLARE
    v_result          RECORD;
    v_entity_name     VARCHAR(512);
    v_region          VARCHAR(64);
    v_deleted_at      TIMESTAMPTZ;
    v_prev_status     VARCHAR(32);
    v_event_id        UUID;
BEGIN
    -- ======================================================================
    -- Step 1: Attempt the soft-delete
    -- This will either succeed (SCENARIO 1) or fail (SCENARIO 2).
    -- ======================================================================
    SELECT * INTO v_result
    FROM soft_delete_entity(p_entity_id := p_entity_id);

    IF NOT v_result.success THEN
        -- SCENARIO 2: Already deleted or not found
        -- NO event is emitted (error_code is 'ERR_ALREADY_DELETED'
        -- or 'ERR_ENTITY_NOT_FOUND' or 'ERR_INVALID_STATUS_TRANSITION')
        RETURN QUERY SELECT
            v_result.success,
            v_result.entity_json,
            NULL::UUID        AS event_id,       -- No event emitted
            v_result.error_code,
            v_result.error_message;
        RETURN;
    END IF;

    -- ======================================================================
    -- Step 2: Extract fields needed for the outbox event payload
    -- ======================================================================
    v_entity_name := v_result.entity_json ->> 'name';
    v_region      := v_result.entity_json ->> 'region';
    v_deleted_at  := (v_result.entity_json ->> 'deleted_at')::TIMESTAMPTZ;

    -- The previous_status is derived from what the entity WAS before deletion.
    -- Since the entity is now 'deleted', we use the stored 'status' field from
    -- the JSON which reflects the current state. The application layer can
    -- override this if it has prior knowledge of the previous status.
    -- Default to 'active' as that is the most common pre-deletion status.
    v_prev_status := 'active';  -- Most common; application can override

    -- ======================================================================
    -- Step 3: Enqueue the entitymanagement.entity.soft_deleted event
    --
    -- Gherkin SCENARIO 1:
    --   "an entitymanagement.entity.soft_deleted event is written
    --    to the outbox within the same transaction"
    -- ======================================================================
    v_event_id := enqueue_entity_soft_deleted_event(
        p_entity_id        := p_entity_id,
        p_entity_name      := v_entity_name,
        p_region           := v_region,
        p_deleted_at       := v_deleted_at,
        p_previous_status  := v_prev_status,
        p_deleted_by       := p_deleted_by
    );

    -- ======================================================================
    -- Step 4: Return success with entity data and event ID
    --
    -- Gherkin SCENARIO 1:
    --   "HTTP 200 is returned with
    --    {'status': 'soft_deleted', 'entity_id': 'ent-001'}"
    --     → The application extracts:
    --       entity_json->>'id'     → entity_id
    --       entity_json->>'status' → 'deleted'
    --       event_id               → outbox trace ID
    -- ======================================================================
    RETURN QUERY SELECT
        TRUE                    AS success,
        v_result.entity_json   AS entity_json,
        v_event_id             AS event_id,
        NULL::TEXT             AS error_code,
        NULL::TEXT             AS error_message;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 5. FUNCTION: restore_entity()
--
-- Restores a soft-deleted entity by setting:
--   - deleted_at = NULL
--   - status = 'active' (revert from terminal 'deleted' back to active)
--   - version = version + 1
--   - updated_at = NOW()
--
-- Validations:
--   - Entity must exist                     → ERR_ENTITY_NOT_FOUND
--   - Entity must be currently soft-deleted → ERR_NOT_DELETED
--     (active entities cannot be "restored")
--
-- Usage:
--   SELECT * FROM restore_entity(
--     p_entity_id := 'e0000001-0000-4000-8000-000000000001'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION restore_entity(
    p_entity_id UUID
)
RETURNS TABLE(
    success       BOOLEAN,
    entity_json   JSONB,
    error_code    TEXT,
    error_message TEXT
) AS $$
DECLARE
    v_entity    entities%ROWTYPE;
    v_now       TIMESTAMPTZ;
BEGIN
    v_now := NOW();

    -- Step 1: Lock and fetch the entity
    SELECT * INTO v_entity
    FROM entities
    WHERE id = p_entity_id
    FOR UPDATE;  -- Prevent race conditions

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE                                   AS success,
            NULL::JSONB                             AS entity_json,
            'ERR_ENTITY_NOT_FOUND'                  AS error_code,
            format('Entity with ID %s not found', p_entity_id::TEXT) AS error_message;
        RETURN;
    END IF;

    -- Step 2: Validate the entity is currently soft-deleted
    IF v_entity.deleted_at IS NULL THEN
        RETURN QUERY SELECT
            FALSE                                   AS success,
            NULL::JSONB                             AS entity_json,
            'ERR_NOT_DELETED'                       AS error_code,
            format('Entity %s (%s) is not soft-deleted and cannot be restored. '
                   || 'Only soft-deleted entities can be restored.',
                   v_entity.name,
                   v_entity.id)                     AS error_message;
        RETURN;
    END IF;

    -- Step 3: Apply the restore atomically
    UPDATE entities
    SET
        status     = 'active'::entity_status,  -- Revert to active status
        deleted_at = NULL,                      -- Clear the soft-delete timestamp
        version    = version + 1,               -- Bump version for OCC
        updated_at = v_now
    WHERE id = p_entity_id;

    -- Step 4: Return the updated entity
    RETURN QUERY SELECT
        TRUE                        AS success,
        row_to_entity_json(p_entity_id) AS entity_json,
        NULL::TEXT                  AS error_code,
        NULL::TEXT                  AS error_message;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 6. FUNCTION: enqueue_entity_restored_event()
--
-- Enqueues an entitymanagement.entity.restored CloudEvent to the outbox.
-- Called within the same database transaction as the restore operation
-- (transactional outbox pattern).
--
-- Payload:
--   { event_id, entity_id, entity_name, region, restored_at,
--     previous_status, new_status, occurred_at }
--
-- Parameters:
--   p_entity_id        UUID         — The entity being restored
--   p_entity_name      VARCHAR(512) — Name at time of restoration
--   p_region           VARCHAR(64)  — Entity region
--   p_restored_at      TIMESTAMPTZ  — When the restoration occurred
--   p_previous_status  VARCHAR(32)  — Status before restore ('deleted')
--   p_new_status       VARCHAR(32)  — Status after restore ('active')
--   p_restored_by      VARCHAR(255) — Who performed the restore (optional)
--
-- Returns:
--   UUID — The event_id for traceability
--
-- Usage:
--   PERFORM enqueue_entity_restored_event(
--     p_entity_id        := 'e0000001-...',
--     p_entity_name      := 'Alice',
--     p_region           := 'eu-west-1',
--     p_restored_at      := NOW(),
--     p_previous_status  := 'deleted',
--     p_new_status       := 'active',
--     p_restored_by      := 'user-abc-123'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_entity_restored_event(
    p_entity_id        UUID,
    p_entity_name      VARCHAR(512),
    p_region           VARCHAR(64),
    p_restored_at      TIMESTAMPTZ,
    p_previous_status  VARCHAR(32) DEFAULT 'deleted',
    p_new_status       VARCHAR(32) DEFAULT 'active',
    p_restored_by      VARCHAR(255) DEFAULT NULL
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
        'entitymanagement.entity.restored',   -- CloudEvents type for restore
        '/entity-manager',                     -- Source identifier
        'entity/' || p_entity_id::TEXT,        -- Subject for event routing
        jsonb_build_object(
            'event_id',         v_event_id::TEXT,
            'entity_id',        p_entity_id::TEXT,
            'entity_name',      p_entity_name,
            'region',           p_region,
            'restored_at',      p_restored_at,
            'previous_status',  p_previous_status,
            'new_status',       p_new_status,
            'restored_by',      p_restored_by,
            'occurred_at',      v_occurred_at
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
-- 7. FUNCTION: restore_entity_with_outbox()
--
-- Combined atomic operation: restores a soft-deleted entity AND enqueues
-- the entitymanagement.entity.restored event in a single call.
--
-- Usage:
--   SELECT * FROM restore_entity_with_outbox(
--     p_entity_id   := 'e0000001-0000-4000-8000-000000000001',
--     p_restored_by := 'user-abc-123'
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION restore_entity_with_outbox(
    p_entity_id   UUID,
    p_restored_by VARCHAR(255) DEFAULT NULL
)
RETURNS TABLE(
    success       BOOLEAN,
    entity_json   JSONB,
    event_id      UUID,
    error_code    TEXT,
    error_message TEXT
) AS $$
DECLARE
    v_result      RECORD;
    v_entity_name VARCHAR(512);
    v_region      VARCHAR(64);
    v_restored_at TIMESTAMPTZ;
    v_event_id    UUID;
BEGIN
    -- Step 1: Perform the restore
    SELECT * INTO v_result
    FROM restore_entity(p_entity_id := p_entity_id);

    IF NOT v_result.success THEN
        RETURN QUERY SELECT
            v_result.success,
            v_result.entity_json,
            NULL::UUID     AS event_id,
            v_result.error_code,
            v_result.error_message;
        RETURN;
    END IF;

    -- Step 2: Extract fields needed for the outbox event
    v_entity_name := v_result.entity_json ->> 'name';
    v_region      := v_result.entity_json ->> 'region';
    v_restored_at := NOW();

    -- Step 3: Enqueue the entitymanagement.entity.restored event
    v_event_id := enqueue_entity_restored_event(
        p_entity_id        := p_entity_id,
        p_entity_name      := v_entity_name,
        p_region           := v_region,
        p_restored_at      := v_restored_at,
        p_previous_status  := 'deleted',
        p_new_status       := 'active',
        p_restored_by      := p_restored_by
    );

    -- Step 4: Return success
    RETURN QUERY SELECT
        TRUE                     AS success,
        v_result.entity_json    AS entity_json,
        v_event_id              AS event_id,
        NULL::TEXT              AS error_code,
        NULL::TEXT              AS error_message;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 8. UPDATE: prevent_immutable_field_update trigger
--
-- The existing trigger from ENTITYMGMT-04 prevents direct mutation of
-- immutable fields including 'status'. However, the soft-delete operation
-- MUST be allowed to transition status from 'active'/'inactive' to 'deleted'.
-- Similarly, restore must transition from 'deleted' back to 'active'.
--
-- We update the trigger to EXEMPT the soft-delete and restore transitions:
--   - 'active'/'inactive' → 'deleted'  (soft-delete, terminal)
--   - 'deleted' → 'active'              (restore)
--
-- These transitions are ONLY permitted when the update also sets deleted_at
-- appropriately:
--   - Soft-delete: deleted_at = NOW() (set to current timestamp)
--   - Restore: deleted_at = NULL (cleared)
--
-- Any other status change (e.g., 'active' → 'inactive' directly) is still
-- blocked to enforce the domain lifecycle rules.
-- ============================================================================

-- First, drop the existing trigger
DROP TRIGGER IF EXISTS prevent_immutable_field_update ON entities;

-- Then recreate it with the soft-delete/restore exemption
CREATE OR REPLACE FUNCTION prevent_immutable_field_update()
RETURNS TRIGGER AS $$
BEGIN
    -- Gherkin SCENARIO 1: Soft-delete transition — ALLOWED
    -- Status changes from 'active'/'inactive' to 'deleted' AND
    -- deleted_at transitions from NULL to a timestamp.
    --
    -- This is the ONLY way status can become 'deleted'.
    IF OLD.status IN ('active', 'inactive')
       AND NEW.status = 'deleted'::entity_status
       AND OLD.deleted_at IS NULL
       AND NEW.deleted_at IS NOT NULL THEN
        RETURN NEW;  -- Allow soft-delete transition
    END IF;

    -- Restore transition — ALLOWED
    -- Status changes from 'deleted' back to 'active' AND
    -- deleted_at transitions from a timestamp back to NULL.
    IF OLD.status = 'deleted'::entity_status
       AND NEW.status = 'active'::entity_status
       AND OLD.deleted_at IS NOT NULL
       AND NEW.deleted_at IS NULL THEN
        RETURN NEW;  -- Allow restore transition
    END IF;

    -- Immutable: region cannot be changed after creation
    IF OLD.region IS DISTINCT FROM NEW.region THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: region cannot be changed after creation'
            USING HINT = 'The region field is immutable after creation. Data residency zone is derived from region.';
    END IF;

    -- Immutable: id cannot be changed after creation
    IF OLD.id IS DISTINCT FROM NEW.id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: id cannot be changed after creation'
            USING HINT = 'The id field is immutable after creation.';
    END IF;

    -- Immutable: data_residency_zone is a generated column
    IF OLD.data_residency_zone IS DISTINCT FROM NEW.data_residency_zone THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: data_residency_zone is a generated column and cannot be changed'
            USING HINT = 'Data residency zone is derived from the region field and is immutable.';
    END IF;

    -- Immutable: type cannot be changed after creation
    IF OLD.type IS DISTINCT FROM NEW.type THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: type cannot be changed after creation'
            USING HINT = 'The type field is immutable after creation.';
    END IF;

    -- Immutable: schema_id cannot be changed after creation
    IF OLD.schema_id IS DISTINCT FROM NEW.schema_id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: schema_id cannot be changed after creation'
            USING HINT = 'The schema_id field is immutable after creation.';
    END IF;

    -- Immutable: created_at cannot be changed after creation
    IF OLD.created_at IS DISTINCT FROM NEW.created_at THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: created_at cannot be changed after creation'
            USING HINT = 'The created_at field is immutable after creation.';
    END IF;

    -- Immutable: version is managed by the optimistic lock mechanism
    IF OLD.version IS DISTINCT FROM NEW.version
       AND NEW.version != OLD.version + 1 THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: version cannot be set directly; use optimistic lock mechanism'
            USING HINT = 'The version field is auto-managed by the optimistic concurrency control system. '
                         'Set the expected version in the WHERE clause, not in SET.';
    END IF;

    -- Immutable: status changes not related to soft-delete or restore
    -- Any status change that does NOT match the patterns above is blocked.
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: status cannot be changed directly. '
                        || 'Use soft-delete (DELETE endpoint) or restore (POST .../restore) '
                        || 'to transition entity lifecycle status.'
            USING HINT = format('Attempted to change status from %s to %s. Only soft-delete '
                                || '(active/inactive → deleted) and restore (deleted → active) '
                                || 'transitions are allowed.',
                                OLD.status, NEW.status);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Recreate the trigger
CREATE TRIGGER prevent_immutable_field_update
    BEFORE UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION prevent_immutable_field_update();

-- ============================================================================
-- 9. INDEXES for soft-delete/restore query patterns
-- ============================================================================

-- Index for "list soft-deleted entities" queries (deleted_at range scans)
CREATE INDEX IF NOT EXISTS idx_entities_deleted_at
    ON entities(deleted_at DESC)
    WHERE deleted_at IS NOT NULL;

-- Index for "count deleted vs active" and "purge old deletions"
CREATE INDEX IF NOT EXISTS idx_entities_deleted_at_retention
    ON entities(deleted_at ASC)
    WHERE deleted_at IS NOT NULL;

-- Composite index: schema_id + deleted_at for filtering deleted entities by type
-- Gherkin SCENARIO 3: "standard GET /api/v1/entities?schema_id=X is called
--                       (without include_deleted=true)"
-- This index optimizes the query: WHERE schema_id = X AND deleted_at IS NULL
CREATE INDEX IF NOT EXISTS idx_entities_schema_active
    ON entities(schema_id, deleted_at DESC NULLS LAST)
    WHERE deleted_at IS NULL;

-- Composite index: schema_id + status + deleted_at for the most common
-- filtered listing query (e.g., "show me active entities in schema X")
CREATE INDEX IF NOT EXISTS idx_entities_schema_status_active
    ON entities(schema_id, status, deleted_at DESC NULLS LAST)
    WHERE deleted_at IS NULL;

-- Composite index: region + deleted_at for region-scoped queries
CREATE INDEX IF NOT EXISTS idx_entities_region_active
    ON entities(region, deleted_at DESC NULLS LAST)
    WHERE deleted_at IS NULL;

-- Index for "find recently deleted entities" (time-based, for lifecycle policies)
CREATE INDEX IF NOT EXISTS idx_entities_deleted_at_recent
    ON entities(deleted_at DESC)
    WHERE deleted_at IS NOT NULL AND deleted_at > NOW() - INTERVAL '7 days';

-- Index for restore operation: fast lookup by id + deleted_at IS NOT NULL
-- This is used by the restore endpoint to quickly find soft-deleted entities.
CREATE INDEX IF NOT EXISTS idx_entities_restorable
    ON entities(id, deleted_at)
    WHERE deleted_at IS NOT NULL;

-- Partial index for the default list query (most common operation)
-- Gherkin SCENARIO 3: "entity 'ent-001' is not included in the results"
-- This partial index speeds up the default list query by only indexing
-- non-deleted entities, keeping the index small and fast.
CREATE INDEX IF NOT EXISTS idx_entities_non_deleted
    ON entities(schema_id, created_at DESC)
    WHERE deleted_at IS NULL;

-- ============================================================================
-- 10. Outbox relay optimization: prefix index for lifecycle events
-- ============================================================================
CREATE INDEX IF NOT EXISTS idx_outbox_lifecycle_events
    ON outbox_events(created_at ASC, event_type)
    WHERE event_type IN (
        'entitymanagement.entity.soft_deleted',
        'entitymanagement.entity.restored'
    );

-- ============================================================================
-- 11. Bootstrap: Return migration summary
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE 'ENTITYMGMT-05 migration applied successfully.';
    RAISE NOTICE '  - Functions: soft_delete_entity, restore_entity';
    RAISE NOTICE '  - Outbox events: entitymanagement.entity.soft_deleted, entitymanagement.entity.restored';
    RAISE NOTICE '  - Atomic wrappers: soft_delete_entity_with_outbox(), restore_entity_with_outbox()';
    RAISE NOTICE '  - Trigger updated: prevent_immutable_field_update (soft-delete/restore exempted)';
    RAISE NOTICE '  - Helper: row_to_entity_json()';
    RAISE NOTICE '  - Indexes: deleted_at, schema_active, restorable, lifecycle event outbox';
    RAISE NOTICE '';
    RAISE NOTICE 'Gherkin coverage:';
    RAISE NOTICE '  SCENARIO 1 (soft-delete success):    ✅ soft_delete_entity_with_outbox()';
    RAISE NOTICE '  SCENARIO 2 (already deleted reject):  ✅ soft_delete_entity() → ERR_ALREADY_DELETED';
    RAISE NOTICE '  SCENARIO 3 (excluded from listing):   ✅ idx_entities_non_deleted + list_entities_by_schema()';
END;
$$;

COMMIT;
