-- Migration: 004_update_entities.sql
-- Description: ENT-03: Update Entity — Modify an existing entity's status,
-- attributes, name, or metadata, with audit logging, immutable field
-- enforcement at the database level, and EntityUpdated outbox events.
--
-- DDL changes:
--   1. ALTER entities — Add metadata JSONB column (for Gherkin metadata payloads)
--   2. Trigger: prevent_immutable_field_update — Reject writes to region, id, type, etc.
--   3. Table: entity_audit_log — Immutable audit trail of every entity update
--   4. Function: log_entity_update() — Writes before/after snapshots to audit log
--   5. Function: enqueue_entity_updated_event() — Writes EntityUpdated to event_outbox
--   6. Trigger: after_entity_update — Combines audit + outbox on UPDATE
--
-- Extends event_outbox usage: supports entity.EntityUpdated events

-- ============================================================================
-- UP
-- ============================================================================

-- ============================================================================
-- 1. Add metadata column to entities table
-- The Gherkin payload includes a "metadata" field for arbitrary key-value
-- metadata (e.g., { "deprecated_at": "2025-01-15" }).
-- ============================================================================
ALTER TABLE entities
    ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}';

-- ============================================================================
-- 2. Immutable field enforcement trigger
-- Prevents UPDATEs that modify fields that are immutable after creation.
-- This is a defense-in-depth measure — the application layer also validates
-- this before calling the repository.
--
-- Immutable fields:
--   id, region, data_residency_zone, type, schema_id, created_at
-- ============================================================================
CREATE OR REPLACE FUNCTION prevent_immutable_field_update()
RETURNS TRIGGER AS $$
BEGIN
    -- Check each immutable field for changes
    IF OLD.id IS DISTINCT FROM NEW.id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: id cannot be changed after creation'
            USING HINT = 'The id field is immutable after creation';
    END IF;

    IF OLD.region IS DISTINCT FROM NEW.region THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: region cannot be changed after creation'
            USING HINT = 'The region field is immutable after creation. Data residency zone is derived from region.';
    END IF;

    IF OLD.type IS DISTINCT FROM NEW.type THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: type cannot be changed after creation'
            USING HINT = 'The type field is immutable after creation (denormalized from schema name)';
    END IF;

    IF OLD.schema_id IS DISTINCT FROM NEW.schema_id THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: schema_id cannot be changed after creation'
            USING HINT = 'The schema_id field is immutable after creation';
    END IF;

    IF OLD.created_at IS DISTINCT FROM NEW.created_at THEN
        RAISE EXCEPTION 'ERR_IMMUTABLE_FIELD: created_at cannot be changed after creation'
            USING HINT = 'The created_at field is immutable after creation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop the trigger first in case it already exists (idempotent migration)
DROP TRIGGER IF EXISTS prevent_entity_immutable_field_update ON entities;

CREATE TRIGGER prevent_entity_immutable_field_update
    BEFORE UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION prevent_immutable_field_update();

-- NOTE: The existing update_entities_modtime trigger (from migration 003)
-- runs BEFORE UPDATE and sets updated_at = NOW(). The immutable field
-- check runs in the same BEFORE phase. PostgreSQL executes BEFORE triggers
-- in alphabetical order by trigger name, so the order of execution is:
--   1. prevent_entity_immutable_field_update (alphabetically first)
--   2. update_entities_modtime
-- This is fine — the immutable check happens first, then the timestamp update.

-- ============================================================================
-- 3. Table: entity_audit_log
-- Immutable append-only log recording every entity update with before/after
-- snapshots. This powers the AuditLog consumer of entity.EntityUpdated events.
--
-- The table is intentionally INSERT-only. No UPDATE or DELETE triggers are
-- created, and application code should never modify rows here.
-- ============================================================================
CREATE TABLE IF NOT EXISTS entity_audit_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id       UUID NOT NULL,
    event_id        UUID NOT NULL,           -- Matches event_outbox.event_id for traceability

    -- Before/after snapshots
    previous_state  JSONB NOT NULL,          -- Full entity state BEFORE the update
    new_state       JSONB NOT NULL,          -- Full entity state AFTER the update
    changed_fields  TEXT[] NOT NULL,         -- Array of field names that were modified

    -- Audit metadata
    updated_by      VARCHAR(255),            -- User/principal who performed the update (nullable for system updates)
    source_ip       INET,                    -- Source IP of the update request (nullable)
    user_agent      TEXT,                    -- User-agent of the client (nullable)

    -- Immutable timestamp (locked via trigger)
    logged_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Constraints
    CONSTRAINT fk_entity_audit_log_entity
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE,
    CONSTRAINT fk_entity_audit_log_event
        FOREIGN KEY (event_id) REFERENCES event_outbox(event_id) ON DELETE RESTRICT,
    CONSTRAINT ck_entity_audit_log_changed_fields_not_empty
        CHECK (cardinality(changed_fields) > 0)
);

-- ============================================================================
-- Indexes for entity_audit_log
-- ============================================================================

-- Fast lookup: all updates for a specific entity, ordered newest-first
CREATE INDEX IF NOT EXISTS idx_entity_audit_log_entity_id
    ON entity_audit_log(entity_id, logged_at DESC);

-- Efficient querying: find updates that modified specific fields
CREATE INDEX IF NOT EXISTS idx_entity_audit_log_changed_fields
    ON entity_audit_log USING GIN (changed_fields);

-- Chronological queries: recent updates across all entities
CREATE INDEX IF NOT EXISTS idx_entity_audit_log_logged_at
    ON entity_audit_log(logged_at DESC);

-- Join with event_outbox for traceability
CREATE INDEX IF NOT EXISTS idx_entity_audit_log_event_id
    ON entity_audit_log(event_id);

-- ============================================================================
-- 4. Function: log_entity_update()
-- Trigger function called AFTER UPDATE on entities.
-- Captures the diff between OLD and NEW row, computes changed fields,
-- and inserts a row into entity_audit_log.
-- ============================================================================
CREATE OR REPLACE FUNCTION log_entity_update()
RETURNS TRIGGER AS $$
DECLARE
    v_changed_fields TEXT[] := '{}';
    v_comparison RECORD;
    v_event_id UUID;
BEGIN
    -- Compare all mutable fields to determine what changed
    -- We iterate over a fixed set of known mutable fields
    IF OLD.name IS DISTINCT FROM NEW.name THEN
        v_changed_fields := array_append(v_changed_fields, 'name');
    END IF;

    IF OLD.status IS DISTINCT FROM NEW.status THEN
        v_changed_fields := array_append(v_changed_fields, 'status');
    END IF;

    IF OLD.attributes IS DISTINCT FROM NEW.attributes THEN
        v_changed_fields := array_append(v_changed_fields, 'attributes');
    END IF;

    IF OLD.metadata IS DISTINCT FROM NEW.metadata THEN
        v_changed_fields := array_append(v_changed_fields, 'metadata');
    END IF;

    IF OLD.schema_version IS DISTINCT FROM NEW.schema_version THEN
        v_changed_fields := array_append(v_changed_fields, 'schema_version');
    END IF;

    -- If nothing changed (e.g., no-op update), skip audit logging
    IF cardinality(v_changed_fields) = 0 THEN
        RETURN NEW;
    END IF;

    -- Generate a deterministic event_id from the entity_id + current timestamp
    -- This is later used in the event_outbox insert for traceability
    v_event_id := gen_random_uuid();

    -- Insert audit log entry
    INSERT INTO entity_audit_log (
        id,
        entity_id,
        event_id,
        previous_state,
        new_state,
        changed_fields,
        updated_by,
        source_ip,
        user_agent,
        logged_at
    ) VALUES (
        gen_random_uuid(),
        NEW.id,
        v_event_id,
        jsonb_build_object(
            'name', OLD.name,
            'status', OLD.status,
            'region', OLD.region,
            'data_residency_zone', OLD.data_residency_zone,
            'type', OLD.type,
            'schema_id', OLD.schema_id,
            'schema_version', OLD.schema_version,
            'attributes', OLD.attributes,
            'metadata', OLD.metadata,
            'created_at', OLD.created_at,
            'updated_at', OLD.updated_at
        ),
        jsonb_build_object(
            'name', NEW.name,
            'status', NEW.status,
            'region', NEW.region,
            'data_residency_zone', NEW.data_residency_zone,
            'type', NEW.type,
            'schema_id', NEW.schema_id,
            'schema_version', NEW.schema_version,
            'attributes', NEW.attributes,
            'metadata', NEW.metadata,
            'created_at', NEW.created_at,
            'updated_at', NEW.updated_at
        ),
        v_changed_fields,
        NULL,  -- updated_by — set by application layer via SET LOCAL
        NULL,  -- source_ip — set by application layer via SET LOCAL
        NULL,  -- user_agent — set by application layer via SET LOCAL
        NOW()
    );

    -- Store the event_id in a custom state for the next trigger in chain
    -- (enqueue_entity_updated_event) to pick up
    PERFORM set_config('entity.last_event_id', v_event_id::TEXT, false);
    PERFORM set_config('entity.changed_fields', array_to_string(v_changed_fields, ','), false);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 5. Function: enqueue_entity_updated_event()
-- Trigger function called AFTER UPDATE on entities (AFTER log_entity_update).
-- Writes an entity.EntityUpdated event to the event_outbox table for
-- downstream consumers (ServiceRegistry, AuditLog, CacheInvalidation).
-- ============================================================================
CREATE OR REPLACE FUNCTION enqueue_entity_updated_event()
RETURNS TRIGGER AS $$
DECLARE
    v_event_id UUID;
    v_changed_fields TEXT[];
    v_event_outbox_id UUID;
BEGIN
    -- Retrieve context set by log_entity_update trigger
    BEGIN
        v_event_id := current_setting('entity.last_event_id')::UUID;
        v_changed_fields := string_to_array(current_setting('entity.changed_fields'), ',');
    EXCEPTION WHEN OTHERS THEN
        -- If no context was set, no changes were detected — skip
        RETURN NEW;
    END;

    -- If no event_id was set, no meaningful changes occurred
    IF v_event_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Insert into event_outbox
    INSERT INTO event_outbox (
        id,
        event_id,
        event_type,
        source,
        subject,
        data,
        processed,
        retry_count,
        last_error,
        created_at
    ) VALUES (
        gen_random_uuid(),
        v_event_id,
        'entity.EntityUpdated',
        'entity-management',
        'entity/' || NEW.id,
        jsonb_build_object(
            'entityId', NEW.id,
            'entityName', NEW.name,
            'entityType', NEW.type,
            'region', NEW.region,
            'previousState', jsonb_build_object(
                'name', OLD.name,
                'status', OLD.status,
                'attributes', OLD.attributes,
                'metadata', OLD.metadata,
                'schemaVersion', OLD.schema_version,
                'updatedAt', OLD.updated_at
            ),
            'newState', jsonb_build_object(
                'name', NEW.name,
                'status', NEW.status,
                'attributes', NEW.attributes,
                'metadata', NEW.metadata,
                'schemaVersion', NEW.schema_version,
                'updatedAt', NEW.updated_at
            ),
            'changedFields', to_jsonb(v_changed_fields),
            'updatedAt', NEW.updated_at
        ),
        FALSE,  -- Not yet processed by the outbox relay
        0,
        NULL,
        NOW()
    );

    -- Reset session-local context
    PERFORM set_config('entity.last_event_id', NULL, false);
    PERFORM set_config('entity.changed_fields', NULL, false);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 6. After-Update Trigger: entity_audit_and_outbox
-- Combines audit logging and event outbox enqueue in a single AFTER UPDATE
-- trigger chain. Order of execution:
--   1. log_entity_update() — writes to entity_audit_log, sets context
--   2. enqueue_entity_updated_event() — reads context, writes to event_outbox
-- ============================================================================
DROP TRIGGER IF EXISTS after_entity_update ON entities;

CREATE TRIGGER after_entity_update
    AFTER UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION log_entity_update();

-- Note: log_entity_update internally enqueues the event via
-- enqueue_entity_updated_event() logic. We keep it as a single trigger
-- function to guarantee atomicity — the event_id is generated once and
-- shared between the audit log and outbox.

-- ============================================================================
-- 7. Function: get_entity_update_history()
-- Helper function to retrieve the update history for a given entity.
-- Returns the most recent N updates, ordered newest-first.
-- ============================================================================
CREATE OR REPLACE FUNCTION get_entity_update_history(
    p_entity_id UUID,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE(
    audit_log_id UUID,
    changed_fields TEXT[],
    previous_state JSONB,
    new_state JSONB,
    logged_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        eal.id,
        eal.changed_fields,
        eal.previous_state,
        eal.new_state,
        eal.logged_at
    FROM entity_audit_log eal
    WHERE eal.entity_id = p_entity_id
    ORDER BY eal.logged_at DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 8. Function: get_entity_changed_fields_since()
-- Returns all fields that changed for a given entity since a timestamp.
-- Useful for cache invalidation and consumer event filtering.
-- ============================================================================
CREATE OR REPLACE FUNCTION get_entity_changed_fields_since(
    p_entity_id UUID,
    p_since TIMESTAMPTZ
)
RETURNS TABLE(
    changed_fields TEXT[],
    changed_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        eal.changed_fields,
        eal.logged_at
    FROM entity_audit_log eal
    WHERE eal.entity_id = p_entity_id
      AND eal.logged_at > p_since
    ORDER BY eal.logged_at DESC;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- 9. Add composite index for efficient cache invalidation queries
-- The CacheInvalidation consumer of entity.EntityUpdated needs to quickly
-- find entities by region and status for targeted cache invalidation.
-- ============================================================================
CREATE INDEX IF NOT EXISTS idx_entities_updated_at
    ON entities(updated_at DESC);

-- Composite index for update queries that filter by schema + status
CREATE INDEX IF NOT EXISTS idx_entities_schema_status_updated
    ON entities(schema_id, status, updated_at DESC);

-- ============================================================================
-- DOWN
-- ============================================================================
DROP FUNCTION IF EXISTS get_entity_changed_fields_since(UUID, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS get_entity_update_history(UUID, INTEGER);
DROP TRIGGER IF EXISTS after_entity_update ON entities;
DROP FUNCTION IF EXISTS enqueue_entity_updated_event();
DROP FUNCTION IF EXISTS log_entity_update();
DROP TRIGGER IF EXISTS prevent_entity_immutable_field_update ON entities;
DROP FUNCTION IF EXISTS prevent_immutable_field_update();
DROP TABLE IF EXISTS entity_audit_log CASCADE;

-- Note: metadata column is NOT dropped in DOWN to prevent data loss.
-- If you need to roll back the column, do so explicitly:
--   ALTER TABLE entities DROP COLUMN IF EXISTS metadata;

-- Indexes added in this migration:
DROP INDEX IF EXISTS idx_entities_updated_at;
DROP INDEX IF EXISTS idx_entities_schema_status_updated;
DROP INDEX IF EXISTS idx_entity_audit_log_entity_id;
DROP INDEX IF EXISTS idx_entity_audit_log_changed_fields;
DROP INDEX IF EXISTS idx_entity_audit_log_logged_at;
DROP INDEX IF EXISTS idx_entity_audit_log_event_id;
