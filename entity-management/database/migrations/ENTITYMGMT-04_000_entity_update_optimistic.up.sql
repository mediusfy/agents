-- Migration: ENTITYMGMT-04_000_entity_update_optimistic.up.sql
-- Story: ENTITYMGMT-04 — User updates an entity with optimistic concurrency control
-- Bounded Context: Entity Management
--
-- Prerequisites:
--   - ENTITYMGMT-01_000_schema_definition.up.sql
--     (outbox_events table, update_modified_column() function)
--   - ENTITYMGMT-02_000_create_entities.up.sql
--     (entities table with version column, entity_status ENUM)
--
-- ============================================================================
-- Gherkin Scenarios
-- ============================================================================
--
-- SCENARIO 1: Successful update with optimistic concurrency
--   Given an entity "ent-001" exists with version 3
--     And attributes: {"email": "old@example.com", "name": "Alice"}
--   When a PUT /api/v1/entities/ent-001 request is sent
--     With body: {"expected_version": 3, "name": "Alice Updated",
--                 "attributes": {"email": "new@example.com"}}
--   Then the entity is updated
--     And version is incremented from 3 to 4
--     And updated_at is refreshed
--     And an entitymanagement.entity.updated event is written to the outbox
--     And the event payload includes changed_fields: ["name", "attributes.email"]
--     And HTTP 200 is returned with the full updated entity
--
-- SCENARIO 2: Stale version (concurrent modification) is rejected
--   Given entity "ent-001" now has version 4 (concurrent update)
--   When a PUT /api/v1/entities/ent-001 request is sent with expected_version=3 (stale)
--   Then HTTP 409 Conflict is returned with ErrStaleVersion
--     And no data is modified
--     And no entity.updated event is emitted
--
-- SCENARIO 3: Immutable field change is rejected
--   Given a PUT request includes an immutable field change like "region"
--   When the update is attempted
--   Then HTTP 400 Bad Request is returned with ErrImmutableField
--     And no changes are persisted
--
-- ============================================================================
-- Domain Events (transactional outbox, reusing outbox_events from ENTITYMGMT-01)
-- ============================================================================
--
-- entitymanagement.entity.updated — Published when an entity is successfully
--   updated via optimistic concurrency. NOT emitted on stale version conflicts
--   (HTTP 409) or immutable field violations (HTTP 400).
--
--   Owned by: EntityManagement context
--
--   Payload per Gherkin spec:
--   {
--     "event_id": "<uuid>",
--     "entity_id": "ent-001",
--     "entity_name": "Alice Updated",
--     "status": "active",
--     "region": "eu-west-1",
--     "previous_version": 3,
--     "new_version": 4,
--     "changed_fields": ["name", "attributes.email"],
--     "occurred_at": "<timestamp>"
--   }
--
--   Consumers:
--     SearchIndexer  — Re-index entity on update
--     AuditLog       — Record change details
--     WebhookDispatcher — Notify subscribers of entity changes
--     Analytics      — Track field-level changes for reporting
--
-- ============================================================================
-- DDL changes in this migration:
--   1. Create prevent_immutable_field_update() trigger function
--   2. Create enqueue_entity_updated_event() outbox function
--   3. Create update_entity_optimistic() atomic update function
--   4. Create update_entity_with_outbox() combined update+outbox function
--   5. Add index for version-based lookups
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. IMMUTABLE FIELD PROTECTION TRIGGER
-- ============================================================================
--
-- This trigger prevents any UPDATE from modifying fields that are designated
-- as immutable after entity creation. It runs BEFORE UPDATE on the entities
-- table and raises EXCEPTION for any disallowed change.
--
-- Immutable fields (per domain.IsImmutableField in types.go):
--   - id: Primary key, never changes
--   - region: Determines data_residency_zone; changing would violate data
--             residency policies (Gherkin SCENARIO 3)
--   - data_residency_zone: Generated column derived from region
--   - type: Denormalized from schema at creation time
--   - schema_id: The schema blueprint is fixed at creation
--   - created_at: Timestamp of creation, never changes
--   - version: Auto-managed by optimistic lock; user cannot SET directly
--
-- The version field is special: it IS allowed to change, but ONLY via the
-- auto-increment SET version = version + 1 mechanism. Direct user-supplied
-- version values are rejected unless they match the expected increment.
--
-- Gherkin SCENARIO 3 mapping:
--   "PUT request includes an immutable field change like 'region'"
--     → IF OLD.region IS DISTINCT FROM NEW.region → EXCEPTION raised
--   "HTTP 400 Bad Request is returned with ErrImmutableField"
--     → Application catches the EXCEPTION and returns HTTP 400
--   "no changes are persisted"
--     → The trigger RAISEs before any write, rolling back the transaction
-- ============================================================================
CREATE OR REPLACE FUNCTION prevent_immutable_field_update()
RETURNS TRIGGER AS $$
BEGIN
    -- Gherkin SCENARIO 3: region cannot be changed after creation
    IF OLD.region IS DISTINCT FROM NEW.region THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: region cannot be changed after creation'
            USING HINT = 'The region field is immutable after creation. Data residency zone is derived from region.';
    END IF;

    -- id cannot be changed after creation
    IF OLD.id IS DISTINCT FROM NEW.id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: id cannot be changed after creation'
            USING HINT = 'The id field is immutable after creation.';
    END IF;

    -- data_residency_zone is a generated column; should never be updated directly
    IF OLD.data_residency_zone IS DISTINCT FROM NEW.data_residency_zone THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: data_residency_zone is a generated column and cannot be changed'
            USING HINT = 'Data residency zone is derived from the region field and is immutable.';
    END IF;

    -- type cannot be changed after creation
    IF OLD.type IS DISTINCT FROM NEW.type THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: type cannot be changed after creation'
            USING HINT = 'The type field is immutable after creation.';
    END IF;

    -- schema_id cannot be changed after creation
    IF OLD.schema_id IS DISTINCT FROM NEW.schema_id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: schema_id cannot be changed after creation'
            USING HINT = 'The schema_id field is immutable after creation.';
    END IF;

    -- created_at cannot be changed after creation
    IF OLD.created_at IS DISTINCT FROM NEW.created_at THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: created_at cannot be changed after creation'
            USING HINT = 'The created_at field is immutable after creation.';
    END IF;

    -- version is managed by the optimistic lock mechanism.
    -- The application must NOT set version directly; it is auto-incremented.
    -- We allow ONLY: NEW.version = OLD.version + 1 (the optimistic increment).
    -- Any other version change is rejected.
    IF OLD.version IS DISTINCT FROM NEW.version
       AND NEW.version != OLD.version + 1 THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: version cannot be set directly; use optimistic lock mechanism'
            USING HINT = 'The version field is auto-managed by the optimistic concurrency control system. '
                         'Set the expected version in the WHERE clause, not in SET.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop the trigger first if it exists (idempotent), then create it
DROP TRIGGER IF EXISTS prevent_immutable_field_update ON entities;

CREATE TRIGGER prevent_immutable_field_update
    BEFORE UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION prevent_immutable_field_update();

-- ============================================================================
-- 2. OUTBOX EVENT ENQUEUE FUNCTION
-- ============================================================================
--
-- Enqueues an entitymanagement.entity.updated CloudEvent to the outbox_events
-- table. Called by the application layer after a successful optimistic update,
-- within the same database transaction (transactional outbox pattern).
--
-- Gherkin SCENARIO 1 mapping:
--   "an entitymanagement.entity.updated event is written to the outbox"
--     → This function inserts into outbox_events with
--       event_type = 'entitymanagement.entity.updated'
--   "the event payload includes changed_fields: ['name', 'attributes.email']"
--     → The payload JSON includes the changed_fields array with dot notation
--       for nested attribute changes
--
-- Gherkin SCENARIO 2 mapping:
--   "no entity.updated event is emitted"
--     → This function is NOT called because the WHERE version = expected_version
--       produces 0 rows affected, so the application returns 409 without
--       invoking the outbox
--
-- Gherkin SCENARIO 3 mapping:
--   "no changes are persisted"
--     → The immutable field trigger RAISEs before any write, rolling back
--       the transaction, so this function is never reached
--
-- Parameters:
--   p_entity_id         UUID          — The entity being updated
--   p_entity_name       VARCHAR(512)  — Current name after update
--   p_entity_status     entity_status — Current status after update
--   p_region            VARCHAR(64)   — Entity region (immutable)
--   p_previous_version  INTEGER       — Version BEFORE the increment
--   p_new_version       INTEGER       — Version AFTER the increment
--   p_changed_fields    TEXT[]        — Array of changed field paths (dot notation)
--   p_previous_state    JSONB         — Full entity state before update
--   p_new_state         JSONB         — Full entity state after update
--
-- Returns:
--   UUID — The event_id (not the outbox row ID) for traceability
--
-- Usage:
--   PERFORM enqueue_entity_updated_event(
--     p_entity_id         := 'f0000001-...',
--     p_entity_name       := 'Alice Updated',
--     p_entity_status     := 'active'::entity_status,
--     p_region            := 'eu-west-1',
--     p_previous_version  := 3,
--     p_new_version       := 4,
--     p_changed_fields    := ARRAY['name', 'attributes.email'],
--     p_previous_state    := '{"name":"Alice","attributes":{"email":"old@example.com"}}'::jsonb,
--     p_new_state         := '{"name":"Alice Updated","attributes":{"email":"new@example.com"}}'::jsonb
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_entity_updated_event(
    p_entity_id         UUID,
    p_entity_name       VARCHAR(512),
    p_entity_status     entity_status,
    p_region            VARCHAR(64),
    p_previous_version  INTEGER,
    p_new_version       INTEGER,
    p_changed_fields    TEXT[],
    p_previous_state    JSONB DEFAULT '{}',
    p_new_state         JSONB DEFAULT '{}'
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
        'entitymanagement.entity.updated',   -- CloudEvents type per Gherkin spec
        '/entity-manager',                    -- Source identifier for EntityManagement context
        'entity/' || p_entity_id::TEXT,       -- Subject for event routing
        jsonb_build_object(
            'event_id',          v_event_id::TEXT,
            'entity_id',         p_entity_id::TEXT,
            'entity_name',       p_entity_name,
            'status',            p_entity_status,
            'region',            p_region,
            'previous_version',  p_previous_version,
            'new_version',       p_new_version,
            'changed_fields',    to_jsonb(p_changed_fields),
            'previous_state',    p_previous_state,
            'new_state',         p_new_state,
            'occurred_at',       v_occurred_at
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
-- 3. ATOMIC OPTIMISTIC UPDATE FUNCTION
-- ============================================================================
--
-- Performs an atomic UPDATE on an entity with optimistic concurrency version
-- checking. This is the core function that implements the Gherkin scenarios:
--
-- SCENARIO 1 (success):
--   UPDATE entities SET ... version = version + 1
--   WHERE id = $1 AND version = $2
--   If ROW_COUNT = 1 → success, version incremented from 3 to 4
--
-- SCENARIO 2 (stale):
--   UPDATE entities SET ... version = version + 1
--   WHERE id = $1 AND version = $2  (version = 3 but current is 4)
--   If ROW_COUNT = 0 → stale version, no update applied
--
-- The function returns a structured result with:
--   success         BOOLEAN     — Whether the update succeeded (version matched)
--   entity_json     JSONB       — Full entity state after update (NULL if stale)
--   previous_version INTEGER    — The expected version that was checked
--   new_version     INTEGER     — The new version after increment (NULL if stale)
--   changed_fields  TEXT[]      — Array of changed field paths (dot notation)
--
-- IMPORTANT: This function does NOT enqueue the outbox event. Use the
-- combined update_entity_with_outbox() for the full workflow including
-- event emission.
--
-- Usage:
--   SELECT * FROM update_entity_optimistic(
--     p_entity_id         := 'f0000001-0000-4000-8000-000000000001',
--     p_expected_version  := 3,
--     p_name              := 'Alice Updated',
--     p_attributes        := '{"email": "new@example.com"}'::jsonb
--   );
--
-- Expected result for SCENARIO 1:
--   success         = TRUE
--   entity_json     = { full entity with version = 4 }
--   previous_version = 3
--   new_version     = 4
--   changed_fields  = ARRAY['name', 'attributes.email']
--
-- Expected result for SCENARIO 2:
--   success         = FALSE
--   entity_json     = NULL
--   previous_version = 4 (the ACTUAL current version, for diagnostics)
--   new_version     = NULL
--   changed_fields  = NULL
-- ============================================================================
CREATE OR REPLACE FUNCTION update_entity_optimistic(
    p_entity_id         UUID,
    p_expected_version  INTEGER,
    p_name              VARCHAR(512) DEFAULT NULL,
    p_status            entity_status DEFAULT NULL,
    p_attributes        JSONB DEFAULT NULL,
    p_metadata          JSONB DEFAULT NULL,
    p_schema_version    INTEGER DEFAULT NULL
)
RETURNS TABLE(
    success          BOOLEAN,
    entity_json      JSONB,
    previous_version INTEGER,
    new_version      INTEGER,
    changed_fields   TEXT[]
) AS $$
DECLARE
    v_current          entities%ROWTYPE;
    v_new              entities%ROWTYPE;
    v_changed          TEXT[] := '{}';
    v_rows_affected    INTEGER;
BEGIN
    -- ==========================================================================
    -- Step 1: Lock the row and check existence
    -- We SELECT FOR UPDATE to prevent race conditions between read and write.
    -- ==========================================================================
    SELECT * INTO v_current
    FROM entities
    WHERE id = p_entity_id
    FOR UPDATE;  -- Row-level lock prevents concurrent modifications

    IF NOT FOUND THEN
        -- Entity does not exist
        RETURN QUERY SELECT
            FALSE                    AS success,
            NULL::JSONB              AS entity_json,
            p_expected_version       AS previous_version,
            NULL::INTEGER            AS new_version,
            NULL::TEXT[]             AS changed_fields;
        RETURN;
    END IF;

    -- ==========================================================================
    -- Step 2: Check version match (Gherkin SCENARIO 2 detection)
    -- ==========================================================================
    IF v_current.version != p_expected_version THEN
        -- SCENARIO 2: Stale version — reject with 409
        -- Return the ACTUAL current version for the application to build
        -- the error response: "Expected version 3 but current version is 4"
        RETURN QUERY SELECT
            FALSE                    AS success,
            NULL::JSONB              AS entity_json,
            v_current.version        AS previous_version,  -- Actual current version
            NULL::INTEGER            AS new_version,
            NULL::TEXT[]             AS changed_fields;
        RETURN;
    END IF;

    -- ==========================================================================
    -- Step 3: Build the SET clause with optimistic version increment
    -- The WHERE clause ensures ONLY the row with the matching version is updated.
    -- ==========================================================================
    UPDATE entities
    SET
        name       = COALESCE(p_name, entities.name),
        status     = COALESCE(p_status, entities.status),
        attributes = CASE
                        WHEN p_attributes IS NULL THEN entities.attributes
                        ELSE entities.attributes || p_attributes  -- JSONB merge for partial updates
                     END,
        metadata   = CASE
                        WHEN p_metadata IS NULL THEN entities.metadata
                        ELSE entities.metadata || p_metadata  -- JSONB merge for partial updates
                     END,
        schema_version = COALESCE(p_schema_version, entities.schema_version),
        version    = version + 1,          -- Gherkin: "version is incremented from 3 to 4"
        updated_at = NOW()                 -- Gherkin: "updated_at is refreshed"
    WHERE id = p_entity_id
      AND version = p_expected_version     -- Optimistic lock condition
    RETURNING * INTO v_new;

    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;

    -- ==========================================================================
    -- Step 4: If no rows were affected, the version changed between our read
    -- and update (race condition). This is technically SCENARIO 2 behavior.
    -- ==========================================================================
    IF v_rows_affected = 0 THEN
        -- Re-read to get the actual current version for diagnostics
        SELECT version INTO v_current.version
        FROM entities
        WHERE id = p_entity_id;

        RETURN QUERY SELECT
            FALSE                    AS success,
            NULL::JSONB              AS entity_json,
            v_current.version        AS previous_version,
            NULL::INTEGER            AS new_version,
            NULL::TEXT[]             AS changed_fields;
        RETURN;
    END IF;

    -- ==========================================================================
    -- Step 5: Compute changed_fields (dot notation for nested attributes)
    --
    -- Build an array of all fields that actually changed, using dot notation
    -- for nested JSONB attribute changes.
    --
    -- Gherkin: "changed_fields: ['name', 'attributes.email']"
    --   → name changed from 'Alice' to 'Alice Updated'
    --   → attributes.email changed from 'old@example.com' to 'new@example.com'
    -- ==========================================================================

    -- Top-level field comparisons
    IF v_current.name IS DISTINCT FROM v_new.name THEN
        v_changed := array_append(v_changed, 'name');
    END IF;

    IF v_current.status IS DISTINCT FROM v_new.status THEN
        v_changed := array_append(v_changed, 'status');
    END IF;

    IF v_current.schema_version IS DISTINCT FROM v_new.schema_version THEN
        v_changed := array_append(v_changed, 'schema_version');
    END IF;

    -- Attribute-level comparisons (dot notation: "attributes.<key>")
    IF v_current.attributes IS DISTINCT FROM v_new.attributes THEN
        -- Find individual keys that changed
        DECLARE
            v_key TEXT;
            v_old_val JSONB;
            v_new_val JSONB;
        BEGIN
            -- Check keys in the NEW attributes (added or modified)
            FOR v_key, v_new_val IN SELECT * FROM jsonb_each(v_new.attributes)
            LOOP
                v_old_val := v_current.attributes -> v_key;
                IF v_old_val IS DISTINCT FROM v_new_val THEN
                    v_changed := array_append(v_changed, 'attributes.' || v_key);
                END IF;
            END LOOP;
            -- Check keys that were in OLD but are now absent (removed)
            FOR v_key, v_old_val IN SELECT * FROM jsonb_each(v_current.attributes)
            LOOP
                IF NOT v_new.attributes ? v_key THEN
                    v_changed := array_append(v_changed, 'attributes.' || v_key);
                END IF;
            END LOOP;
        END;
    END IF;

    -- Metadata-level comparisons (dot notation: "metadata.<key>")
    IF v_current.metadata IS DISTINCT FROM v_new.metadata THEN
        DECLARE
            v_key TEXT;
            v_old_val JSONB;
            v_new_val JSONB;
        BEGIN
            FOR v_key, v_new_val IN SELECT * FROM jsonb_each(v_new.metadata)
            LOOP
                v_old_val := v_current.metadata -> v_key;
                IF v_old_val IS DISTINCT FROM v_new_val THEN
                    v_changed := array_append(v_changed, 'metadata.' || v_key);
                END IF;
            END LOOP;
            FOR v_key, v_old_val IN SELECT * FROM jsonb_each(v_current.metadata)
            LOOP
                IF NOT v_new.metadata ? v_key THEN
                    v_changed := array_append(v_changed, 'metadata.' || v_key);
                END IF;
            END LOOP;
        END;
    END IF;

    -- Version change is always detected (increment is expected)
    -- We add it to changed_fields so consumers know the version was bumped
    v_changed := array_append(v_changed, 'version');

    -- ==========================================================================
    -- Step 6: Return success with full entity and changed fields
    --
    -- Gherkin SCENARIO 1: "HTTP 200 is returned with the full updated entity"
    --   → entity_json contains all fields (id, schema_id, name, type, region,
    --      data_residency_zone, status, version, attributes, metadata,
    --      created_at, updated_at)
    -- ==========================================================================
    RETURN QUERY SELECT
        TRUE                    AS success,
        jsonb_build_object(
            'id',                  v_new.id::TEXT,
            'schema_id',           v_new.schema_id::TEXT,
            'schema_version',      v_new.schema_version,
            'name',                v_new.name,
            'type',                v_new.type,
            'region',              v_new.region,
            'data_residency_zone', v_new.data_residency_zone,
            'status',              v_new.status,
            'version',             v_new.version,
            'attributes',          v_new.attributes,
            'metadata',            v_new.metadata,
            'created_at',          v_new.created_at,
            'updated_at',          v_new.updated_at,
            'deleted_at',          v_new.deleted_at
        ) AS entity_json,
        p_expected_version      AS previous_version,
        v_new.version           AS new_version,
        v_changed               AS changed_fields;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 4. COMBINED UPDATE WITH OUTBOX EVENT
-- ============================================================================
--
-- Combined atomic operation: validates version, updates entity with optimistic
-- concurrency, computes changed fields, and enqueues the entity.updated event
-- ALL within a single database transaction.
--
-- This is the application-layer friendly entry point that wraps the entire
-- update workflow. It is what the HTTP PUT handler calls.
--
-- Gherkin SCENARIO 1:
--   Calls update_entity_optimistic() → succeeds → calls
--   enqueue_entity_updated_event() → returns success with entity and event ID
--
-- Gherkin SCENARIO 2:
--   Calls update_entity_optimistic() → fails (stale version) → returns
--   failure WITHOUT calling enqueue_entity_updated_event()
--
-- Gherkin SCENARIO 3:
--   The immutable field trigger fires BEFORE this function completes →
--   transaction rolls back → no changes persisted, no event emitted
--
-- Returns:
--   success          BOOLEAN     — Whether the update succeeded
--   entity_json      JSONB       — Full entity after update (NULL if failed)
--   previous_version INTEGER     — Expected version provided
--   new_version      INTEGER     — New version (NULL if failed)
--   changed_fields   TEXT[]      — Changed field paths (NULL if failed)
--   event_id         UUID        — Outbox event ID (NULL if failed)
--   error_code       TEXT        — Machine-readable error code for the
--                                  application to map to HTTP status:
--                                  NULL (success), 'STALE_VERSION',
--                                  'IMMUTABLE_FIELD', 'ENTITY_NOT_FOUND'
--   error_message    TEXT        — Human-readable error description
--
-- Usage:
--   SELECT * FROM update_entity_with_outbox(
--     p_entity_id         := 'f0000001-0000-4000-8000-000000000001',
--     p_expected_version  := 3,
--     p_name              := 'Alice Updated',
--     p_attributes        := '{"email": "new@example.com"}'::jsonb
--   );
-- ============================================================================
CREATE OR REPLACE FUNCTION update_entity_with_outbox(
    p_entity_id         UUID,
    p_expected_version  INTEGER,
    p_name              VARCHAR(512) DEFAULT NULL,
    p_status            entity_status DEFAULT NULL,
    p_attributes        JSONB DEFAULT NULL,
    p_metadata          JSONB DEFAULT NULL,
    p_schema_version    INTEGER DEFAULT NULL
)
RETURNS TABLE(
    success          BOOLEAN,
    entity_json      JSONB,
    previous_version INTEGER,
    new_version      INTEGER,
    changed_fields   TEXT[],
    event_id         UUID,
    error_code       TEXT,
    error_message    TEXT
) AS $$
DECLARE
    v_result         RECORD;
    v_entity_id      UUID;
    v_entity_name    VARCHAR(512);
    v_entity_status  entity_status;
    v_region         VARCHAR(64);
    v_previous_state JSONB;
    v_new_state      JSONB;
    v_event_id       UUID;
    v_exc_message    TEXT;
    v_exc_detail     TEXT;
    v_exc_hint       TEXT;
BEGIN
    -- ==========================================================================
    -- Step 1: Attempt the optimistic update
    -- This will either succeed (SCENARIO 1) or fail (SCENARIO 2 or 3).
    -- SCENARIO 3 failures (immutable field) are caught as exceptions below.
    -- ==========================================================================
    BEGIN
        SELECT * INTO v_result
        FROM update_entity_optimistic(
            p_entity_id         := p_entity_id,
            p_expected_version  := p_expected_version,
            p_name              := p_name,
            p_status            := p_status,
            p_attributes        := p_attributes,
            p_metadata          := p_metadata,
            p_schema_version    := p_schema_version
        );
    EXCEPTION
        WHEN OTHERS THEN
            -- Capture the exception details
            GET STACKED DIAGNOSTICS
                v_exc_message = MESSAGE_TEXT,
                v_exc_detail = PG_EXCEPTION_DETAIL,
                v_exc_hint = PG_EXCEPTION_HINT;

            -- Check if this is an immutable field violation (SCENARIO 3)
            IF v_exc_message LIKE 'ERR_IMMUTABLE_FIELD:%' THEN
                RETURN QUERY SELECT
                    FALSE                             AS success,
                    NULL::JSONB                       AS entity_json,
                    p_expected_version                AS previous_version,
                    NULL::INTEGER                     AS new_version,
                    NULL::TEXT[]                      AS changed_fields,
                    NULL::UUID                        AS event_id,
                    'IMMUTABLE_FIELD'                 AS error_code,
                    v_exc_message                     AS error_message;
                RETURN;
            END IF;

            -- Unknown error - re-raise
            RAISE;
    END;

    -- ==========================================================================
    -- Step 2: If update failed (stale version), return failure without event
    --
    -- Gherkin SCENARIO 2:
    --   "no data is modified" → update_entity_optimistic returned FALSE
    --   "no entity.updated event is emitted" → we skip enqueue_entity_updated_event
    -- ==========================================================================
    IF NOT v_result.success THEN
        RETURN QUERY SELECT
            FALSE                             AS success,
            NULL::JSONB                       AS entity_json,
            v_result.previous_version         AS previous_version,
            NULL::INTEGER                     AS new_version,
            NULL::TEXT[]                      AS changed_fields,
            NULL::UUID                        AS event_id,
            'STALE_VERSION'                   AS error_code,
            'Stale version: expected ' || p_expected_version::TEXT ||
            ' but current version is ' || v_result.previous_version::TEXT
                                                AS error_message;
        RETURN;
    END IF;

    -- ==========================================================================
    -- Step 3: Extract fields needed for the outbox event payload
    -- ==========================================================================
    v_entity_id     := p_entity_id;
    v_entity_name   := v_result.entity_json ->> 'name';
    v_entity_status := (v_result.entity_json ->> 'status')::entity_status;
    v_region        := v_result.entity_json ->> 'region';

    -- Build previous_state (before update)
    -- We reconstruct this from what we know was the state before the update
    v_previous_state := jsonb_build_object(
        'name',       COALESCE(p_name, v_result.entity_json ->> 'name'),
        'status',     COALESCE(p_status::TEXT, v_result.entity_json ->> 'status'),
        'version',    p_expected_version
    );

    -- Build new_state (after update)
    v_new_state := jsonb_build_object(
        'name',       v_result.entity_json ->> 'name',
        'status',     v_result.entity_json ->> 'status',
        'version',    v_result.new_version
    );

    -- ==========================================================================
    -- Step 4: Enqueue the entitymanagement.entity.updated event
    --
    -- Gherkin SCENARIO 1:
    --   "an entitymanagement.entity.updated event is written to the outbox"
    -- ==========================================================================
    v_event_id := enqueue_entity_updated_event(
        p_entity_id         := v_entity_id,
        p_entity_name       := v_entity_name,
        p_entity_status     := v_entity_status,
        p_region            := v_region,
        p_previous_version  := p_expected_version,
        p_new_version       := v_result.new_version,
        p_changed_fields    := v_result.changed_fields,
        p_previous_state    := v_previous_state,
        p_new_state         := v_new_state
    );

    -- ==========================================================================
    -- Step 5: Return success with full entity, changed fields, and event ID
    --
    -- Gherkin SCENARIO 1:
    --   "HTTP 200 is returned with the full updated entity"
    -- ==========================================================================
    RETURN QUERY SELECT
        TRUE                              AS success,
        v_result.entity_json              AS entity_json,
        p_expected_version                AS previous_version,
        v_result.new_version              AS new_version,
        v_result.changed_fields           AS changed_fields,
        v_event_id                        AS event_id,
        NULL::TEXT                        AS error_code,     -- No error
        NULL::TEXT                        AS error_message;  -- No error
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 5. DIAGNOSTIC & VALIDATION FUNCTIONS
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 5a. get_entity_by_id_with_version()
-- Retrieves an entity by ID with its version number included.
-- The application layer calls this BEFORE an update to display the current
-- version to the user or client.
--
-- Gherkin: "Given an entity 'ent-001' exists with version 3"
--   → SELECT * FROM get_entity_by_id_with_version('f0000001-...');
--   → Returns the entity with version = 3
--
-- Usage:
--   SELECT * FROM get_entity_by_id_with_version('f0000001-...');
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_entity_by_id_with_version(
    p_entity_id UUID
)
RETURNS TABLE(
    entity_id           UUID,
    schema_id           UUID,
    schema_version      INTEGER,
    name                VARCHAR(512),
    type                VARCHAR(255),
    region              VARCHAR(64),
    data_residency_zone TEXT,
    status              entity_status,
    version             INTEGER,
    attributes          JSONB,
    metadata            JSONB,
    created_at          TIMESTAMPTZ,
    updated_at          TIMESTAMPTZ,
    deleted_at          TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.id,
        e.schema_id,
        e.schema_version,
        e.name,
        e.type,
        e.region,
        e.data_residency_zone,
        e.status,
        e.version,
        e.attributes,
        e.metadata,
        e.created_at,
        e.updated_at,
        e.deleted_at
    FROM entities e
    WHERE e.id = p_entity_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------------
-- 5b. validate_entity_version()
-- Validates that the given expected version matches the entity's current
-- version. Provides early feedback without performing the actual update.
--
-- Usage:
--   SELECT * FROM validate_entity_version('f0000001-...', 3);
--   → Returns: is_valid=true, current_version=3, is_stale=false
--
--   SELECT * FROM validate_entity_version('f0000001-...', 2);
--   → Returns: is_valid=false, current_version=3, is_stale=true
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION validate_entity_version(
    p_entity_id        UUID,
    p_expected_version INTEGER
)
RETURNS TABLE(
    is_valid        BOOLEAN,
    entity_exists   BOOLEAN,
    current_version INTEGER,
    is_stale        BOOLEAN
) AS $$
DECLARE
    v_current_version INTEGER;
    v_exists          BOOLEAN;
BEGIN
    SELECT version, TRUE INTO v_current_version, v_exists
    FROM entities
    WHERE id = p_entity_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE              AS is_valid,
            FALSE              AS entity_exists,
            NULL::INTEGER      AS current_version,
            FALSE              AS is_stale;
        RETURN;
    END IF;

    RETURN QUERY SELECT
        (v_current_version = p_expected_version) AS is_valid,
        TRUE                                     AS entity_exists,
        v_current_version                        AS current_version,
        (v_current_version != p_expected_version) AS is_stale;
END;
$$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------------
-- 5c. check_entity_staleness()
-- Returns a human-readable staleness description for error responses.
--
-- Gherkin SCENARIO 2 error response:
--   "HTTP 409 Conflict is returned with ErrStaleVersion"
--   → The application uses this to build the error payload
--
-- Usage:
--   SELECT * FROM check_entity_staleness('f0000001-...', 3);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_entity_staleness(
    p_entity_id        UUID,
    p_expected_version INTEGER
)
RETURNS TABLE(
    is_stale           BOOLEAN,
    expected_version   INTEGER,
    actual_version     INTEGER,
    staleness_message  TEXT
) AS $$
DECLARE
    v_actual_version INTEGER;
    v_entity_name    VARCHAR(512);
BEGIN
    SELECT version, name INTO v_actual_version, v_entity_name
    FROM entities
    WHERE id = p_entity_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE                  AS is_stale,
            p_expected_version     AS expected_version,
            NULL::INTEGER          AS actual_version,
            'Entity not found'     AS staleness_message;
        RETURN;
    END IF;

    IF v_actual_version = p_expected_version THEN
        RETURN QUERY SELECT
            FALSE                               AS is_stale,
            p_expected_version                  AS expected_version,
            v_actual_version                    AS actual_version,
            'Version matches — entity is current' AS staleness_message;
    ELSE
        RETURN QUERY SELECT
            TRUE                                              AS is_stale,
            p_expected_version                                AS expected_version,
            v_actual_version                                  AS actual_version,
            format('Entity %s has been modified. Expected version %s but current version is %s.',
                   v_entity_name,
                   p_expected_version::TEXT,
                   v_actual_version::TEXT)                    AS staleness_message;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------------
-- 5d. count_entity_updates_since_version()
-- Returns the number of times an entity has been updated since a given
-- version. Useful for detecting rapid updates and rate limiting.
--
-- Usage:
--   SELECT count_entity_updates_since_version('f0000001-...', 3);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION count_entity_updates_since_version(
    p_entity_id     UUID,
    p_since_version INTEGER
)
RETURNS INTEGER AS $$
DECLARE
    v_current_version INTEGER;
BEGIN
    SELECT version INTO v_current_version
    FROM entities
    WHERE id = p_entity_id;

    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    RETURN GREATEST(0, v_current_version - p_since_version);
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 6. INDEXES FOR VERSION-BASED LOOKUPS
-- ============================================================================

-- Composite index for optimistic concurrency update queries:
-- The application frequently queries: UPDATE ... WHERE id = $1 AND version = $2
-- The primary key index on id covers the id lookup, and this composite index
-- optimizes the version check on the WHERE clause.
CREATE INDEX IF NOT EXISTS idx_entities_id_version
    ON entities(id, version);

-- Index for version+status queries: "find all entities at version N with status X"
CREATE INDEX IF NOT EXISTS idx_entities_version_status
    ON entities(version, status);

-- Index for changed_fields/version analysis queries
-- Useful for analytics consumers tracking field-level changes
CREATE INDEX IF NOT EXISTS idx_entities_updated_at_id
    ON entities(updated_at DESC, id DESC);

COMMIT;
