-- Migration: ENTITYMGMT-08_000_status_lifecycle.up.sql
-- Story: ENTITYMGMT-08 — System enforces entity status lifecycle:
--                        active ↔ inactive → deleted (terminal)
-- Bounded Context: Entity Management
--
-- Prerequisites:
--   - ENTITYMGMT-05_000_soft_delete_restore.up.sql
--     (soft-delete/restore trigger exemptions, soft_delete_entity, restore_entity)
--   - ENTITYMGMT-04_000_entity_update_optimistic.up.sql
--     (update_entity_optimistic, enqueue_entity_updated_event,
--      update_entity_with_outbox, prevent_immutable_field_update trigger)
--   - ENTITYMGMT-02_000_create_entities.up.sql
--     (entities table, entity_status ENUM: active, inactive, deleted)
--
-- ============================================================================
-- Gherkin Scenarios
-- ============================================================================
--
-- SCENARIO 1: active → inactive transition
--   Given an entity exists with status "active"
--   When a user updates the entity setting status="inactive"
--   Then the transition succeeds
--     And an entitymanagement.entity.updated event is emitted
--       with changed_fields including "status"
--
-- SCENARIO 2: inactive → active transition
--   Given an entity exists with status "inactive"
--   When a user updates the entity setting status="active"
--   Then the transition succeeds
--
-- SCENARIO 3: active → deleted (soft-delete via DELETE endpoint)
--   Given an entity exists with status "active"
--   When a soft-delete is performed (via DELETE endpoint)
--   Then the entity status transitions to "deleted" (terminal state)
--     (covered by ENTITYMGMT-05, verified here)
--
-- SCENARIO 4: deleted → active (via regular update) — REJECTED
--   Given an entity exists with status "deleted" (after soft-delete)
--   When a user attempts a status-only update setting status="active"
--   Then ErrInvalidStatusTransition is returned
--     And the only way to exit "deleted" is via the restore endpoint
--
-- SCENARIO 5: invalid status value "unknown" — REJECTED
--   Given an entity exists with status "inactive"
--   When a user attempts to set status to an invalid value "unknown"
--   Then ErrInvalidStatusTransition is returned
--     And no data is modified
--
-- ============================================================================
-- Domain Events (extending entitymanagement.entity.updated)
-- ============================================================================
--
-- entitymanagement.entity.updated — Status transition variant
--   Published when entity status transitions between non-terminal states
--   (active ↔ inactive). The changed_fields includes 'status'.
--
--   ENHANCED PAYLOAD (this migration):
--     Adds: previous_status, new_status
--
--   Enhanced payload:
--   {
--     "event_id": "<uuid>",
--     "entity_id": "<uuid>",
--     "entity_name": "Alice",
--     "status": "inactive",
--     "region": "eu-west-1",
--     "previous_version": 3,
--     "new_version": 4,
--     "previous_status": "active",
--     "new_status": "inactive",
--     "changed_fields": ["status"],
--     "previous_state": {...},
--     "new_state": {...},
--     "occurred_at": "<timestamp>"
--   }
--
--   Consumers:
--     WorkflowEngine — Trigger workflows on status transitions
--     AuditLog       — Record status change audit trail
--     NotificationService — Notify subscribers of status changes
--
-- ============================================================================
-- DDL changes in this migration:
--   1. validate_status_transition() — Core lifecycle validation function
--   2. Updated prevent_immutable_field_update trigger — Now allows
--      active ↔ inactive transitions (previously blocked ALL status changes
--      except soft-delete/restore)
--   3. Updated enqueue_entity_updated_event() — Now includes
--      previous_status and new_status in the outbox payload
--   4. Updated update_entity_optimistic() — Returns previous_status
--      for inclusion in outbox event
--   5. Updated update_entity_with_outbox() — Passes previous_status
--      and new_status to the enqueue function
--   6. New: update_entity_status_with_outbox() — Dedicated function
--      for status-only updates with lifecycle validation
--   7. New: verify_status_lifecycle() — Diagnostic function
--   8. Indexes for status transition queries
--
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. FUNCTION: validate_status_transition()
--
-- Core lifecycle validation function that enforces:
--   active ↔ inactive → deleted (terminal)
--
-- Lifecycle rules:
--   active    → inactive    ✅ (SCENARIO 1)
--   active    → deleted     ✅ (soft-delete via DELETE endpoint, SCENARIO 3)
--   inactive  → active      ✅ (SCENARIO 2)
--   inactive  → deleted     ✅ (soft-delete via DELETE endpoint)
--   deleted   → active      ❌ (ErrInvalidStatusTransition via regular update)
--                             ✅ ONLY via restore endpoint (ENTITYMGMT-05/07)
--   deleted   → inactive    ❌ (ErrInvalidStatusTransition)
--   any       → <invalid>   ❌ (ErrInvalidStatusTransition, SCENARIO 5)
--   active    → active      ✅ (no-op, no transition)
--   inactive  → inactive    ✅ (no-op, no transition)
--
-- Parameters:
--   p_current_status  entity_status  — The entity's current status
--   p_new_status      entity_status  — The desired new status
--   p_via_restore     BOOLEAN        — Whether this is called from the
--                                      restore endpoint (default FALSE).
--                                      When TRUE, deleted → active is allowed.
--
-- Returns:
--   is_valid         BOOLEAN     — Whether the transition is valid
--   error_code       TEXT        — NULL if valid, 'ERR_INVALID_STATUS_TRANSITION'
--                                   if invalid
--   error_message    TEXT        — Human-readable explanation
--   is_terminal      BOOLEAN     — Whether the current status is terminal (deleted)
--   is_noop          BOOLEAN     — Whether current and new status are the same
--
-- Usage:
--   SELECT * FROM validate_status_transition('active'::entity_status, 'inactive'::entity_status);
--   → is_valid=true, error_code=NULL
--
--   SELECT * FROM validate_status_transition('deleted'::entity_status, 'active'::entity_status);
--   → is_valid=false, error_code='ERR_INVALID_STATUS_TRANSITION'
--
--   SELECT * FROM validate_status_transition('deleted'::entity_status, 'active'::entity_status, TRUE);
--   → is_valid=true (via restore endpoint)
-- ============================================================================
CREATE OR REPLACE FUNCTION validate_status_transition(
    p_current_status  entity_status,
    p_new_status      entity_status,
    p_via_restore     BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    is_valid         BOOLEAN,
    error_code       TEXT,
    error_message    TEXT,
    is_terminal      BOOLEAN,
    is_noop          BOOLEAN
) AS $$
BEGIN
    -- ======================================================================
    -- Rule 0: No-op check — same status, no transition needed
    -- ======================================================================
    IF p_current_status = p_new_status THEN
        RETURN QUERY SELECT
            TRUE                    AS is_valid,
            NULL::TEXT              AS error_code,
            NULL::TEXT              AS error_message,
            (p_current_status = 'deleted'::entity_status) AS is_terminal,
            TRUE                    AS is_noop;
        RETURN;
    END IF;

    -- ======================================================================
    -- Rule 1: Terminal state check — 'deleted' is terminal
    -- The only way to exit 'deleted' is via the restore endpoint.
    --
    -- Gherkin SCENARIO 4:
    --   "Given an entity exists with status 'deleted' (after soft-delete)
    --    When a user attempts a status-only update setting status='active'
    --    Then ErrInvalidStatusTransition is returned
    --      And the only way to exit 'deleted' is via the restore endpoint"
    -- ======================================================================
    IF p_current_status = 'deleted'::entity_status THEN
        IF p_via_restore THEN
            -- Restore endpoint is the ONLY way to exit 'deleted'
            IF p_new_status = 'active'::entity_status THEN
                RETURN QUERY SELECT
                    TRUE                    AS is_valid,
                    NULL::TEXT              AS error_code,
                    NULL::TEXT              AS error_message,
                    TRUE                    AS is_terminal,
                    FALSE                   AS is_noop;
                RETURN;
            ELSE
                -- Even via restore, only 'active' is a valid target
                RETURN QUERY SELECT
                    FALSE                               AS is_valid,
                    'ERR_INVALID_STATUS_TRANSITION'     AS error_code,
                    format('Invalid status transition from %s to %s. '
                           || 'Via restore, only transition to active is allowed.',
                           p_current_status, p_new_status) AS error_message,
                    TRUE                                AS is_terminal,
                    FALSE                               AS is_noop;
                RETURN;
            END IF;
        END IF;

        -- Regular update on deleted entity: always rejected
        -- Gherkin: "ErrInvalidStatusTransition is returned"
        --          "the only way to exit 'deleted' is via the restore endpoint"
        RETURN QUERY SELECT
            FALSE                               AS is_valid,
            'ERR_INVALID_STATUS_TRANSITION'     AS error_code,
            format('Cannot transition from terminal status %s to %s via regular update. '
                   || 'The only way to exit ''deleted'' is via the restore endpoint '
                   || '(POST /api/v1/entities/{id}/restore).',
                   p_current_status, p_new_status) AS error_message,
            TRUE                                AS is_terminal,
            FALSE                               AS is_noop;
        RETURN;
    END IF;

    -- ======================================================================
    -- Rule 2: Valid non-terminal transitions
    --
    -- Gherkin SCENARIO 1: active → inactive  ✅
    -- Gherkin SCENARIO 2: inactive → active  ✅
    -- Gherkin SCENARIO 3: active → deleted   ✅ (via DELETE endpoint/soft-delete)
    -- Also: inactive → deleted               ✅ (via DELETE endpoint/soft-delete)
    --
    -- The domain.ValidTransitions() defines:
    --   active   → [inactive, deleted]
    --   inactive → [active, deleted]
    -- ======================================================================
    IF (p_current_status = 'active'::entity_status
        AND p_new_status IN ('inactive'::entity_status, 'deleted'::entity_status))
       OR
       (p_current_status = 'inactive'::entity_status
        AND p_new_status IN ('active'::entity_status, 'deleted'::entity_status))
    THEN
        RETURN QUERY SELECT
            TRUE                    AS is_valid,
            NULL::TEXT              AS error_code,
            NULL::TEXT              AS error_message,
            FALSE                   AS is_terminal,
            FALSE                   AS is_noop;
        RETURN;
    END IF;

    -- ======================================================================
    -- Rule 3: All other transitions are invalid
    --
    -- Gherkin SCENARIO 5:
    --   "Given an entity exists with status 'inactive'
    --    When a user attempts to set status to an invalid value 'unknown'
    --    Then ErrInvalidStatusTransition is returned
    --      And no data is modified"
    --
    -- This also catches any status value that is not in the entity_status
    -- ENUM (invalid values are rejected by PostgreSQL at the type level).
    -- ======================================================================
    RETURN QUERY SELECT
        FALSE                               AS is_valid,
        'ERR_INVALID_STATUS_TRANSITION'     AS error_code,
        format('Invalid status transition from %s to %s. '
               || 'Valid transitions: active ↔ inactive, '
               || 'active/inactive → deleted (soft-delete). '
               || 'To exit ''deleted'', use the restore endpoint.',
               p_current_status, p_new_status) AS error_message,
        (p_current_status = 'deleted'::entity_status) AS is_terminal,
        FALSE                               AS is_noop;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 2. UPDATED TRIGGER: prevent_immutable_field_update()
--
-- ENHANCEMENT from ENTITYMGMT-05:
--   Previously, the trigger ONLY allowed:
--     1. Soft-delete: active/inactive → deleted (with deleted_at NULL→timestamp)
--     2. Restore:     deleted → active          (with deleted_at timestamp→NULL)
--   All other status changes were BLOCKED.
--
--   Now adds exemption for:
--     3. Transition:  active ↔ inactive (no deleted_at change)
--
--   This completes the lifecycle enforcement:
--     active ↔ inactive → deleted (terminal)
--
--   The trigger continues to reject:
--     - deleted → anything via regular update (must use restore endpoint)
--     - Any status change that violates the lifecycle rules
--     - Invalid/unknown status values (caught by PG ENUM type + validation)
-- ============================================================================

-- First, drop the existing trigger and function
DROP TRIGGER IF EXISTS prevent_immutable_field_update ON entities;

CREATE OR REPLACE FUNCTION prevent_immutable_field_update()
RETURNS TRIGGER AS $$
DECLARE
    v_transition RECORD;
BEGIN
    -- ======================================================================
    -- EXEMPTION 1: Soft-delete — ALLOWED
    -- Status: active/inactive → deleted
    -- deleted_at: NULL → timestamp
    --
    -- Gherkin SCENARIO 3: active → deleted (soft-delete via DELETE endpoint)
    -- ======================================================================
    IF OLD.status IN ('active'::entity_status, 'inactive'::entity_status)
       AND NEW.status = 'deleted'::entity_status
       AND OLD.deleted_at IS NULL
       AND NEW.deleted_at IS NOT NULL THEN
        RETURN NEW;  -- Allow soft-delete transition
    END IF;

    -- ======================================================================
    -- EXEMPTION 2: Restore — ALLOWED
    -- Status: deleted → active
    -- deleted_at: timestamp → NULL
    --
    -- This is ONLY triggered by the restore endpoint.
    -- ======================================================================
    IF OLD.status = 'deleted'::entity_status
       AND NEW.status = 'active'::entity_status
       AND OLD.deleted_at IS NOT NULL
       AND NEW.deleted_at IS NULL THEN
        RETURN NEW;  -- Allow restore transition
    END IF;

    -- ======================================================================
    -- EXEMPTION 3: Active ↔ Inactive transitions — ALLOWED (NEW)
    -- Status: active → inactive OR inactive → active
    -- deleted_at: unchanged (both NULL)
    --
    -- Gherkin SCENARIO 1: active → inactive
    -- Gherkin SCENARIO 2: inactive → active
    --
    -- These are REGULAR status transitions (NOT soft-delete or restore).
    -- The deleted_at field must remain NULL (no deletion involved).
    -- ======================================================================
    IF (OLD.status = 'active'::entity_status AND NEW.status = 'inactive'::entity_status)
       OR (OLD.status = 'inactive'::entity_status AND NEW.status = 'active'::entity_status) THEN
        -- Verify deleted_at is unchanged (must remain NULL for non-delete transitions)
        IF OLD.deleted_at IS DISTINCT FROM NEW.deleted_at THEN
            RAISE EXCEPTION 'ERR_INVALID_STATUS_TRANSITION: Cannot change deleted_at during status transition % → %',
                OLD.status, NEW.status
                USING HINT = 'Use soft-delete (DELETE endpoint) to set deleted_at, '
                             'or use restore (POST .../restore) to clear it.';
        END IF;
        RETURN NEW;  -- Allow active ↔ inactive transition
    END IF;

    -- ======================================================================
    -- BLOCKED: All other status changes
    --
    -- This catches:
    --   - deleted → inactive (must use restore → active, then → inactive if needed)
    --   - deleted → deleted (no-op, but should not be attempted)
    --   - Any other unexpected transition
    --
    -- Gherkin SCENARIO 4:
    --   "When a user attempts a status-only update setting status='active'
    --    on a deleted entity → ErrInvalidStatusTransition"
    -- ======================================================================
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        -- Use the validation function for a descriptive error message
        SELECT * INTO v_transition
        FROM validate_status_transition(
            OLD.status,
            NEW.status,
            FALSE  -- Not via restore
        );

        IF NOT v_transition.is_valid THEN
            RAISE EXCEPTION 'ERR_INVALID_STATUS_TRANSITION: %', v_transition.error_message;
        END IF;

        -- Fallback (shouldn't reach here, but defensive)
        RAISE EXCEPTION 'ERR_INVALID_STATUS_TRANSITION: Status transition from % to % is not allowed',
            OLD.status, NEW.status
            USING HINT = format('Valid transitions: active ↔ inactive, '
                                'active/inactive → deleted (soft-delete). '
                                'To exit ''deleted'', use POST .../restore.');
    END IF;

    -- ======================================================================
    -- Immutable field checks (unchanged from ENTITYMGMT-05)
    -- ======================================================================

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

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Recreate the trigger with the updated function
CREATE TRIGGER prevent_immutable_field_update
    BEFORE UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION prevent_immutable_field_update();

-- ============================================================================
-- 3. UPDATED FUNCTION: enqueue_entity_updated_event()
--
-- ENHANCEMENT from ENTITYMGMT-04:
--   Added p_previous_status and p_new_status parameters.
--   The payload now includes previous_status and new_status fields.
--
-- This allows downstream consumers (WorkflowEngine, AuditLog,
-- NotificationService) to react specifically to status transitions.
-- ============================================================================

-- Drop the existing function first (signature changed)
DROP FUNCTION IF EXISTS enqueue_entity_updated_event(
    UUID, VARCHAR(512), entity_status, VARCHAR(64),
    INTEGER, INTEGER, TEXT[], JSONB, JSONB
);

CREATE OR REPLACE FUNCTION enqueue_entity_updated_event(
    p_entity_id         UUID,
    p_entity_name       VARCHAR(512),
    p_entity_status     entity_status,       -- Status AFTER the update (new_status)
    p_region            VARCHAR(64),
    p_previous_version  INTEGER,
    p_new_version       INTEGER,
    p_changed_fields    TEXT[],
    p_previous_status   entity_status DEFAULT NULL,  -- Status BEFORE the update
    p_previous_state    JSONB DEFAULT '{}',
    p_new_state         JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_event_id    UUID;
    v_occurred_at TIMESTAMPTZ;
    v_has_status_change BOOLEAN;
    v_previous_status_text TEXT;
    v_new_status_text TEXT;
BEGIN
    v_event_id    := gen_random_uuid();
    v_occurred_at := NOW();

    -- Detect whether this event involves a status transition
    v_has_status_change := p_changed_fields @> ARRAY['status'];

    -- Determine previous_status and new_status for the payload
    v_previous_status_text := COALESCE(p_previous_status::TEXT, p_entity_status::TEXT);
    v_new_status_text      := p_entity_status::TEXT;

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
            'status',            p_entity_status,           -- New status after update
            'region',            p_region,
            'previous_version',  p_previous_version,
            'new_version',       p_new_version,
            'changed_fields',    to_jsonb(p_changed_fields),
            -- ENHANCED: previous_status and new_status fields
            'previous_status',   v_previous_status_text,
            'new_status',        v_new_status_text,
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
-- 4. UPDATED FUNCTION: update_entity_optimistic()
--
-- ENHANCEMENT from ENTITYMGMT-04:
--   Now returns previous_status alongside other fields.
--   This allows the calling function (update_entity_with_outbox) to pass
--   previous_status to enqueue_entity_updated_event().
--
-- The return type is extended to include:
--   previous_status  entity_status — The status BEFORE the update
--   new_status       entity_status — The status AFTER the update
-- ============================================================================

-- Drop the existing function first (return type changed)
DROP FUNCTION IF EXISTS update_entity_optimistic(
    UUID, INTEGER, VARCHAR(512), entity_status, JSONB, JSONB, INTEGER
);

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
    changed_fields   TEXT[],
    previous_status  entity_status,    -- NEW: status before update
    new_status       entity_status     -- NEW: status after update
) AS $$
DECLARE
    v_current          entities%ROWTYPE;
    v_new              entities%ROWTYPE;
    v_changed          TEXT[] := '{}';
    v_rows_affected    INTEGER;
    v_prev_status      entity_status;
    v_new_status       entity_status;
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
            NULL::TEXT[]             AS changed_fields,
            NULL::entity_status      AS previous_status,
            NULL::entity_status      AS new_status;
        RETURN;
    END IF;

    -- ==========================================================================
    -- Step 2: Check version match (Gherkin SCENARIO 2 detection)
    -- ==========================================================================
    IF v_current.version != p_expected_version THEN
        -- SCENARIO 2: Stale version — reject with 409
        RETURN QUERY SELECT
            FALSE                    AS success,
            NULL::JSONB              AS entity_json,
            v_current.version        AS previous_version,  -- Actual current version
            NULL::INTEGER            AS new_version,
            NULL::TEXT[]             AS changed_fields,
            v_current.status         AS previous_status,
            NULL::entity_status      AS new_status;
        RETURN;
    END IF;

    -- ==========================================================================
    -- Step 2b: Capture previous status BEFORE any changes
    -- ==========================================================================
    v_prev_status := v_current.status;

    -- ==========================================================================
    -- Step 2c: Validate status transition if a new status is provided
    --
    -- Gherkin SCENARIO 1 & 2: active ↔ inactive — valid transitions
    -- Gherkin SCENARIO 4: deleted → active — INVALID via regular update
    -- Gherkin SCENARIO 5: invalid status value — caught by ENUM type
    -- ==========================================================================
    IF p_status IS NOT NULL AND p_status != v_prev_status THEN
        -- Check the transition is valid (not via restore)
        IF NOT EXISTS (
            SELECT 1 FROM validate_status_transition(v_prev_status, p_status, FALSE)
            WHERE is_valid
        ) THEN
            -- Invalid transition — return error
            RETURN QUERY SELECT
                FALSE                    AS success,
                NULL::JSONB              AS entity_json,
                p_expected_version       AS previous_version,
                NULL::INTEGER            AS new_version,
                NULL::TEXT[]             AS changed_fields,
                v_prev_status            AS previous_status,
                NULL::entity_status      AS new_status;
            RETURN;
        END IF;
    END IF;

    -- ==========================================================================
    -- Step 3: Build the SET clause with optimistic version increment
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
        version    = version + 1,          -- Gherkin: "version is incremented"
        updated_at = NOW()                 -- Gherkin: "updated_at is refreshed"
    WHERE id = p_entity_id
      AND version = p_expected_version     -- Optimistic lock condition
    RETURNING * INTO v_new;

    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;

    -- ==========================================================================
    -- Step 4: If no rows were affected, handle race condition
    -- ==========================================================================
    IF v_rows_affected = 0 THEN
        SELECT version INTO v_current.version
        FROM entities WHERE id = p_entity_id;

        RETURN QUERY SELECT
            FALSE                    AS success,
            NULL::JSONB              AS entity_json,
            v_current.version        AS previous_version,
            NULL::INTEGER            AS new_version,
            NULL::TEXT[]             AS changed_fields,
            v_prev_status            AS previous_status,
            NULL::entity_status      AS new_status;
        RETURN;
    END IF;

    -- ==========================================================================
    -- Step 5: Capture new status and compute changed_fields
    -- ==========================================================================
    v_new_status := v_new.status;

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
        DECLARE
            v_key TEXT;
            v_old_val JSONB;
            v_new_val JSONB;
        BEGIN
            FOR v_key, v_new_val IN SELECT * FROM jsonb_each(v_new.attributes)
            LOOP
                v_old_val := v_current.attributes -> v_key;
                IF v_old_val IS DISTINCT FROM v_new_val THEN
                    v_changed := array_append(v_changed, 'attributes.' || v_key);
                END IF;
            END LOOP;
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

    -- Version change is always detected
    v_changed := array_append(v_changed, 'version');

    -- ==========================================================================
    -- Step 6: Return success with entity data, changed fields, and status info
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
        v_changed               AS changed_fields,
        v_prev_status           AS previous_status,   -- NEW
        v_new_status            AS new_status;        -- NEW
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 5. UPDATED FUNCTION: update_entity_with_outbox()
--
-- ENHANCEMENT from ENTITYMGMT-04:
--   Now passes previous_status and new_status from the update result into
--   enqueue_entity_updated_event(), so the outbox payload includes
--   previous_status and new_status for downstream consumers.
-- ============================================================================

-- Drop the existing function first (signature changed internally)
DROP FUNCTION IF EXISTS update_entity_with_outbox(
    UUID, INTEGER, VARCHAR(512), entity_status, JSONB, JSONB, INTEGER
);

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
    v_prev_status    entity_status;
    v_new_status     entity_status;
BEGIN
    -- ==========================================================================
    -- Step 1: Attempt the optimistic update
    -- This will either succeed (SCENARIO 1/2) or fail.
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
            GET STACKED DIAGNOSTICS
                v_exc_message = MESSAGE_TEXT,
                v_exc_detail = PG_EXCEPTION_DETAIL,
                v_exc_hint = PG_EXCEPTION_HINT;

            -- Check if this is an immutable field violation
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

            -- Check if this is an invalid status transition
            IF v_exc_message LIKE 'ERR_INVALID_STATUS_TRANSITION:%' THEN
                RETURN QUERY SELECT
                    FALSE                             AS success,
                    NULL::JSONB                       AS entity_json,
                    p_expected_version                AS previous_version,
                    NULL::INTEGER                     AS new_version,
                    NULL::TEXT[]                      AS changed_fields,
                    NULL::UUID                        AS event_id,
                    'INVALID_STATUS_TRANSITION'       AS error_code,
                    v_exc_message                     AS error_message;
                RETURN;
            END IF;

            -- Unknown error - re-raise
            RAISE;
    END;

    -- ==========================================================================
    -- Step 2: If update failed (stale version), return failure without event
    -- ==========================================================================
    IF NOT v_result.success THEN
        -- Determine the specific error code
        DECLARE
            v_err_code TEXT;
        BEGIN
            IF v_result.new_version IS NULL AND v_result.entity_json IS NULL THEN
                -- Check if this was a status transition error
                IF v_result.previous_status IS NOT NULL THEN
                    v_err_code := 'INVALID_STATUS_TRANSITION';
                ELSE
                    v_err_code := 'STALE_VERSION';
                END IF;
            ELSE
                v_err_code := 'STALE_VERSION';
            END IF;

            RETURN QUERY SELECT
                FALSE                             AS success,
                NULL::JSONB                       AS entity_json,
                v_result.previous_version         AS previous_version,
                NULL::INTEGER                     AS new_version,
                NULL::TEXT[]                      AS changed_fields,
                NULL::UUID                        AS event_id,
                v_err_code                        AS error_code,
                CASE
                    WHEN v_err_code = 'INVALID_STATUS_TRANSITION' THEN
                        format('Invalid status transition from %s to %s',
                               v_result.previous_status, p_status)
                    ELSE
                        'Stale version: expected ' || p_expected_version::TEXT ||
                        ' but current version is ' || v_result.previous_version::TEXT
                END                               AS error_message;
            RETURN;
        END;
    END IF;

    -- ==========================================================================
    -- Step 3: Extract fields needed for the outbox event payload
    -- ==========================================================================
    v_entity_id     := p_entity_id;
    v_entity_name   := v_result.entity_json ->> 'name';
    v_entity_status := (v_result.entity_json ->> 'status')::entity_status;
    v_region        := v_result.entity_json ->> 'region';
    v_prev_status   := v_result.previous_status;
    v_new_status    := v_result.new_status;

    -- Build previous_state (before update)
    v_previous_state := jsonb_build_object(
        'name',       COALESCE(p_name, v_result.entity_json ->> 'name'),
        'status',     COALESCE(v_prev_status::TEXT, v_result.entity_json ->> 'status'),
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
    -- ENHANCED: Now passes previous_status and new_status to the enqueue
    -- function, which includes them in the outbox payload.
    -- ==========================================================================
    v_event_id := enqueue_entity_updated_event(
        p_entity_id         := v_entity_id,
        p_entity_name       := v_entity_name,
        p_entity_status     := v_entity_status,
        p_region            := v_region,
        p_previous_version  := p_expected_version,
        p_new_version       := v_result.new_version,
        p_changed_fields    := v_result.changed_fields,
        p_previous_status   := v_prev_status,     -- NEW: previous status
        p_previous_state    := v_previous_state,
        p_new_state         := v_new_state
    );

    -- ==========================================================================
    -- Step 5: Return success
    -- ==========================================================================
    RETURN QUERY SELECT
        TRUE                              AS success,
        v_result.entity_json              AS entity_json,
        p_expected_version                AS previous_version,
        v_result.new_version              AS new_version,
        v_result.changed_fields           AS changed_fields,
        v_event_id                        AS event_id,
        NULL::TEXT                        AS error_code,
        NULL::TEXT                        AS error_message;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 6. NEW FUNCTION: update_entity_status_with_outbox()
--
-- Dedicated function for status-only updates on an entity.
-- Provides a simpler interface than the general update_entity_with_outbox()
-- when only the status field is changing.
--
-- Gherkin SCENARIO 1:
--   "When a user updates the entity setting status='inactive'"
--   → Calls update_entity_status_with_outbox(entity_id, expected_version, 'inactive')
--
-- Gherkin SCENARIO 4:
--   "When a user attempts a status-only update setting status='active'
--    on a deleted entity → ErrInvalidStatusTransition"
--   → Function returns error without modifying data
--
-- Gherkin SCENARIO 5:
--   "When a user attempts to set status to an invalid value 'unknown'"
--   → The entity_status ENUM type rejects the value BEFORE this function
--     is called. If somehow reached, validate_status_transition() catches it.
--
-- Validates the status transition via validate_status_transition() before
-- applying the update. If the transition is invalid, returns an error
-- WITHOUT modifying any data.
--
-- Parameters:
--   p_entity_id         UUID          — The entity to update
--   p_expected_version  INTEGER       — Optimistic concurrency version
--   p_new_status        entity_status — The desired new status
--
-- Returns:
--   Same return type as update_entity_with_outbox()
--
-- Usage:
--   SELECT * FROM update_entity_status_with_outbox(
--     p_entity_id         := 'e0000001-0000-4000-8000-000000000001',
--     p_expected_version  := 3,
--     p_new_status        := 'inactive'::entity_status
--   );
--
-- Expected result for SCENARIO 1 (active → inactive):
--   success          = TRUE
--   changed_fields   = ARRAY['status', 'version']
--   error_code       = NULL
--
-- Expected result for SCENARIO 4 (deleted → active via update):
--   success          = FALSE
--   error_code       = 'INVALID_STATUS_TRANSITION'
--   entity_json      = NULL
--   event_id         = NULL  (NO event emitted)
-- ============================================================================
CREATE OR REPLACE FUNCTION update_entity_status_with_outbox(
    p_entity_id         UUID,
    p_expected_version  INTEGER,
    p_new_status        entity_status
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
    v_current        entities%ROWTYPE;
    v_transition     RECORD;
    v_result         RECORD;
BEGIN
    -- ==========================================================================
    -- Step 1: Lock and fetch the current entity state
    -- ==========================================================================
    SELECT * INTO v_current
    FROM entities
    WHERE id = p_entity_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT
            FALSE                             AS success,
            NULL::JSONB                       AS entity_json,
            NULL::INTEGER                     AS previous_version,
            NULL::INTEGER                     AS new_version,
            NULL::TEXT[]                      AS changed_fields,
            NULL::UUID                        AS event_id,
            'ENTITY_NOT_FOUND'                AS error_code,
            format('Entity with ID %s not found', p_entity_id::TEXT) AS error_message;
        RETURN;
    END IF;

    -- ==========================================================================
    -- Step 2: Check version match
    -- ==========================================================================
    IF v_current.version != p_expected_version THEN
        RETURN QUERY SELECT
            FALSE                             AS success,
            NULL::JSONB                       AS entity_json,
            v_current.version                 AS previous_version,
            NULL::INTEGER                     AS new_version,
            NULL::TEXT[]                      AS changed_fields,
            NULL::UUID                        AS event_id,
            'STALE_VERSION'                   AS error_code,
            format('Stale version: expected %s but current version is %s',
                   p_expected_version, v_current.version) AS error_message;
        RETURN;
    END IF;

    -- ==========================================================================
    -- Step 3: Validate the status transition (NOT via restore)
    --
    -- Gherkin SCENARIO 1: active → inactive  → valid
    -- Gherkin SCENARIO 2: inactive → active  → valid
    -- Gherkin SCENARIO 4: deleted → active   → INVALID (must use restore)
    -- Gherkin SCENARIO 5: any → 'unknown'    → INVALID (invalid ENUM value,
    --                                                caught by PG type system)
    -- ==========================================================================
    SELECT * INTO v_transition
    FROM validate_status_transition(
        p_current_status := v_current.status,
        p_new_status     := p_new_status,
        p_via_restore    := FALSE   -- Regular update, NOT restore
    );

    IF NOT v_transition.is_valid THEN
        -- Gherkin SCENARIO 4 or 5: Invalid transition
        -- No data is modified (we haven't performed any UPDATE yet)
        -- No event is emitted (event_id = NULL)
        RETURN QUERY SELECT
            FALSE                             AS success,
            NULL::JSONB                       AS entity_json,
            p_expected_version                AS previous_version,
            NULL::INTEGER                     AS new_version,
            NULL::TEXT[]                      AS changed_fields,
            NULL::UUID                        AS event_id,
            'INVALID_STATUS_TRANSITION'       AS error_code,
            v_transition.error_message        AS error_message;
        RETURN;
    END IF;

    -- ==========================================================================
    -- Step 4: If it's a no-op (same status), return success without event
    -- ==========================================================================
    IF v_transition.is_noop THEN
        RETURN QUERY SELECT
            TRUE                              AS success,
            row_to_entity_json(p_entity_id)   AS entity_json,
            p_expected_version                AS previous_version,
            v_current.version                 AS new_version,
            ARRAY[]::TEXT[]                   AS changed_fields,
            NULL::UUID                        AS event_id,   -- No event for no-op
            NULL::TEXT                        AS error_code,
            NULL::TEXT                        AS error_message;
        RETURN;
    END IF;

    -- ==========================================================================
    -- Step 5: Apply the status update (delegate to update_entity_with_outbox)
    -- ==========================================================================
    SELECT * INTO v_result
    FROM update_entity_with_outbox(
        p_entity_id         := p_entity_id,
        p_expected_version  := p_expected_version,
        p_status            := p_new_status
    );

    RETURN QUERY SELECT
        v_result.success,
        v_result.entity_json,
        v_result.previous_version,
        v_result.new_version,
        v_result.changed_fields,
        v_result.event_id,
        v_result.error_code,
        v_result.error_message;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 7. NEW FUNCTION: verify_status_lifecycle()
--
-- Diagnostic function that validates all Gherkin scenarios programmatically.
-- Can be used in seed scripts and integration tests to verify the status
-- lifecycle enforcement is working correctly.
--
-- Checks:
--   1. All valid transitions produce is_valid = TRUE
--   2. All invalid transitions produce is_valid = FALSE
--   3. Error codes match expected values
--   4. Terminal state detection works
--   5. No-op detection works
--
-- Usage:
--   SELECT * FROM verify_status_lifecycle();
-- ============================================================================
CREATE OR REPLACE FUNCTION verify_status_lifecycle()
RETURNS TABLE(
    check_name      TEXT,
    passed          BOOLEAN,
    expected        TEXT,
    actual          TEXT
) AS $$
DECLARE
    v_rec RECORD;
BEGIN
    -- ======================================================================
    -- Check 1: active → inactive (SCENARIO 1 — should succeed)
    -- ======================================================================
    SELECT is_valid, error_code INTO v_rec
    FROM validate_status_transition('active'::entity_status, 'inactive'::entity_status, FALSE);

    RETURN QUERY SELECT
        'SCENARIO 1: active → inactive' AS check_name,
        v_rec.is_valid AS passed,
        'is_valid = true' AS expected,
        format('is_valid = %s, error_code = %s', v_rec.is_valid, COALESCE(v_rec.error_code, 'NULL')) AS actual;

    -- ======================================================================
    -- Check 2: inactive → active (SCENARIO 2 — should succeed)
    -- ======================================================================
    SELECT is_valid, error_code INTO v_rec
    FROM validate_status_transition('inactive'::entity_status, 'active'::entity_status, FALSE);

    RETURN QUERY SELECT
        'SCENARIO 2: inactive → active' AS check_name,
        v_rec.is_valid AS passed,
        'is_valid = true' AS expected,
        format('is_valid = %s, error_code = %s', v_rec.is_valid, COALESCE(v_rec.error_code, 'NULL')) AS actual;

    -- ======================================================================
    -- Check 3: active → deleted (SCENARIO 3 — soft-delete)
    -- ======================================================================
    SELECT is_valid, error_code INTO v_rec
    FROM validate_status_transition('active'::entity_status, 'deleted'::entity_status, FALSE);

    RETURN QUERY SELECT
        'SCENARIO 3: active → deleted (soft-delete)' AS check_name,
        v_rec.is_valid AS passed,
        'is_valid = true' AS expected,
        format('is_valid = %s, error_code = %s', v_rec.is_valid, COALESCE(v_rec.error_code, 'NULL')) AS actual;

    -- ======================================================================
    -- Check 4: inactive → deleted (soft-delete)
    -- ======================================================================
    SELECT is_valid, error_code INTO v_rec
    FROM validate_status_transition('inactive'::entity_status, 'deleted'::entity_status, FALSE);

    RETURN QUERY SELECT
        'inactive → deleted (soft-delete)' AS check_name,
        v_rec.is_valid AS passed,
        'is_valid = true' AS expected,
        format('is_valid = %s, error_code = %s', v_rec.is_valid, COALESCE(v_rec.error_code, 'NULL')) AS actual;

    -- ======================================================================
    -- Check 5: deleted → active via regular update (SCENARIO 4 — should fail)
    -- ======================================================================
    SELECT is_valid, error_code INTO v_rec
    FROM validate_status_transition('deleted'::entity_status, 'active'::entity_status, FALSE);

    RETURN QUERY SELECT
        'SCENARIO 4: deleted → active (via regular update — REJECTED)' AS check_name,
        NOT v_rec.is_valid AS passed,
        'is_valid = false, error_code = ERR_INVALID_STATUS_TRANSITION' AS expected,
        format('is_valid = %s, error_code = %s', v_rec.is_valid, COALESCE(v_rec.error_code, 'NULL')) AS actual;

    -- ======================================================================
    -- Check 6: deleted → active via restore (should succeed)
    -- ======================================================================
    SELECT is_valid, error_code INTO v_rec
    FROM validate_status_transition('deleted'::entity_status, 'active'::entity_status, TRUE);

    RETURN QUERY SELECT
        'deleted → active (via restore — ALLOWED)' AS check_name,
        v_rec.is_valid AS passed,
        'is_valid = true' AS expected,
        format('is_valid = %s, error_code = %s', v_rec.is_valid, COALESCE(v_rec.error_code, 'NULL')) AS actual;

    -- ======================================================================
    -- Check 7: deleted → inactive (via restore with invalid target — should fail)
    -- ======================================================================
    SELECT is_valid, error_code INTO v_rec
    FROM validate_status_transition('deleted'::entity_status, 'inactive'::entity_status, TRUE);

    RETURN QUERY SELECT
        'deleted → inactive (via restore — REJECTED, must go to active)' AS check_name,
        NOT v_rec.is_valid AS passed,
        'is_valid = false' AS expected,
        format('is_valid = %s, error_code = %s', v_rec.is_valid, COALESCE(v_rec.error_code, 'NULL')) AS actual;

    -- ======================================================================
    -- Check 8: Terminal detection for 'deleted'
    -- ======================================================================
    SELECT is_terminal INTO v_rec
    FROM validate_status_transition('deleted'::entity_status, 'active'::entity_status, FALSE);

    RETURN QUERY SELECT
        'Terminal detection: deleted is terminal' AS check_name,
        v_rec.is_terminal AS passed,
        'is_terminal = true' AS expected,
        format('is_terminal = %s', v_rec.is_terminal) AS actual;

    -- ======================================================================
    -- Check 9: No-op detection (active → active)
    -- ======================================================================
    SELECT is_noop INTO v_rec
    FROM validate_status_transition('active'::entity_status, 'active'::entity_status, FALSE);

    RETURN QUERY SELECT
        'No-op detection: active → active' AS check_name,
        v_rec.is_noop AS passed,
        'is_noop = true' AS expected,
        format('is_noop = %s', v_rec.is_noop) AS actual;

    -- ======================================================================
    -- Check 10: No-op detection (inactive → inactive)
    -- ======================================================================
    SELECT is_noop INTO v_rec
    FROM validate_status_transition('inactive'::entity_status, 'inactive'::entity_status, FALSE);

    RETURN QUERY SELECT
        'No-op detection: inactive → inactive' AS check_name,
        v_rec.is_noop AS passed,
        'is_noop = true' AS expected,
        format('is_noop = %s', v_rec.is_noop) AS actual;

    -- ======================================================================
    -- Check 11: Invalid status within ENUM but invalid transition (deleted → deleted)
    -- Note: 'deleted' → 'deleted' is technically a no-op
    -- ======================================================================
    SELECT is_valid, is_noop INTO v_rec
    FROM validate_status_transition('deleted'::entity_status, 'deleted'::entity_status, FALSE);

    RETURN QUERY SELECT
        'deleted → deleted (no-op)' AS check_name,
        v_rec.is_valid AS passed,
        'is_valid = true, is_noop = true' AS expected,
        format('is_valid = %s, is_noop = %s', v_rec.is_valid, v_rec.is_noop) AS actual;

    -- ======================================================================
    -- Check 12: active → provisioning (valid ENUM value, invalid transition)
    -- Note: 'provisioning' exists in the ENUM but is not part of the
    -- active lifecycle per the domain model.
    -- ======================================================================
    SELECT is_valid, error_code INTO v_rec
    FROM validate_status_transition('active'::entity_status, 'provisioning'::entity_status, FALSE);

    RETURN QUERY SELECT
        'active → provisioning (valid ENUM, invalid transition)' AS check_name,
        NOT v_rec.is_valid AS passed,
        'is_valid = false, error_code = ERR_INVALID_STATUS_TRANSITION' AS expected,
        format('is_valid = %s, error_code = %s', v_rec.is_valid, COALESCE(v_rec.error_code, 'NULL')) AS actual;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 8. INDEXES for status transition query patterns
-- ============================================================================

-- Index for "find entities by current status" (most common filter)
CREATE INDEX IF NOT EXISTS idx_entities_status_transition
    ON entities(status, updated_at DESC);

-- Composite index: schema_id + status + version for optimistic update
-- with status change (the most common status transition query pattern)
CREATE INDEX IF NOT EXISTS idx_entities_schema_status_version
    ON entities(schema_id, status, version);

-- Index for "find entities that recently changed status"
-- Used by the WorkflowEngine consumer to detect status transitions
CREATE INDEX IF NOT EXISTS idx_entities_status_updated
    ON entities(status, updated_at DESC);

-- Partial index: active entities (for active → inactive queries)
CREATE INDEX IF NOT EXISTS idx_entities_active_only
    ON entities(schema_id, name)
    WHERE status = 'active'::entity_status;

-- Partial index: inactive entities (for inactive → active queries)
CREATE INDEX IF NOT EXISTS idx_entities_inactive_only
    ON entities(schema_id, name)
    WHERE status = 'inactive'::entity_status;

-- ============================================================================
-- 9. Bootstrap: Return migration summary
-- ============================================================================
DO $$
BEGIN
    RAISE NOTICE 'ENTITYMGMT-08 migration applied successfully.';
    RAISE NOTICE '  - New: validate_status_transition() — Core lifecycle validation';
    RAISE NOTICE '  - Updated: prevent_immutable_field_update trigger — Now allows active↔inactive';
    RAISE NOTICE '  - Updated: enqueue_entity_updated_event() — Now includes previous_status/new_status';
    RAISE NOTICE '  - Updated: update_entity_optimistic() — Returns previous_status/new_status';
    RAISE NOTICE '  - Updated: update_entity_with_outbox() — Passes status to event';
    RAISE NOTICE '  - New: update_entity_status_with_outbox() — Dedicated status-only update';
    RAISE NOTICE '  - New: verify_status_lifecycle() — Diagnostic/validation function';
    RAISE NOTICE '  - New indexes: status_transition, schema_status_version, status_updated';
    RAISE NOTICE '  - Partial indexes: active_only, inactive_only';
    RAISE NOTICE '';
    RAISE NOTICE 'Lifecycle enforcement: active ↔ inactive → deleted (terminal)';
    RAISE NOTICE '  - The only way to exit ''deleted'' is via the restore endpoint';
    RAISE NOTICE '';
    RAISE NOTICE 'Gherkin coverage:';
    RAISE NOTICE '  SCENARIO 1 (active → inactive):      ✅ update_entity_status_with_outbox()';
    RAISE NOTICE '  SCENARIO 2 (inactive → active):      ✅ update_entity_status_with_outbox()';
    RAISE NOTICE '  SCENARIO 3 (active → deleted):        ✅ soft_delete_entity_with_outbox() (ENTITYMGMT-05)';
    RAISE NOTICE '  SCENARIO 4 (deleted → active reject): ✅ validate_status_transition() → ERR_INVALID_STATUS_TRANSITION';
    RAISE NOTICE '  SCENARIO 5 (invalid status reject):   ✅ entity_status ENUM + validate_status_transition()';
    RAISE NOTICE '';
    RAISE NOTICE 'Event payload enhancement:';
    RAISE NOTICE '  entitymanagement.entity.updated now includes:';
    RAISE NOTICE '    previous_status, new_status (for status transition variant)';
    RAISE NOTICE '  Consumers: WorkflowEngine, AuditLog, NotificationService';
END;
$$;

COMMIT;
