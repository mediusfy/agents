-- Query: ENTITYMGMT-09_list_entities_cursor.sql
-- Story: ENTITYMGMT-09 — User lists entities with cursor-based pagination
--                         and multi-field filtering
-- Bounded Context: Entity Management
--
-- Lists entities for a given schema using cursor-based pagination with
-- multi-field filtering support. This is the primary read query for the
-- GET /api/v1/entities endpoint.
--
-- Gherkin SCENARIO 1: Simple paginated listing
--   GET /api/v1/entities?schema_id=sch-customer&limit=20
--
-- Gherkin SCENARIO 2: Next page via cursor
--   GET /api/v1/entities?schema_id=sch-customer&limit=20&cursor=<token>
--
-- Gherkin SCENARIO 3: Multi-field filtering
--   GET /api/v1/entities?schema_id=sch-customer&filter=status==active&filter=region~eu
--
-- Gherkin SCENARIO 4-5: Limit clamping (min 1, max 100)
--   limit=0 → 1, limit=200 → 100
--
-- Gherkin SCENARIO 7: Include soft-deleted
--   GET /api/v1/entities?schema_id=sch-customer&include_deleted=true
--
-- The application layer (ListEntitiesUseCase) handles:
--   - Limit clamping
--   - Cursor validation (decode + error handling)
--   - Filter parsing
--   - limit+1 fetch logic for next page detection
--   - next_cursor generation
--   - Event publishing (entities.queried)
--
-- This SQL function is the database-level building block that the application
-- layer delegates to via EntityRepository.ListEntities().
--
-- Usage:
--   SELECT * FROM list_entities_cursor(
--     p_schema_id       := 'c0000001-0000-4000-8000-000000000001',  -- Required: schema UUID
--     p_limit           := 20,                                        -- Clamped to [1, 100]
--     p_cursor          := NULL,                                      -- Opaque token or NULL
--     p_filters         := ARRAY['status==active', 'region~eu'],     -- Filter expressions
--     p_include_deleted := FALSE                                       -- Include soft-deleted
--   );
--
-- Returns:
--   Columns from entities table + next_cursor (opaque token) + total_count
-- ============================================================================

-- :name list-entities-cursor
-- :command :query
-- :result :many
SELECT * FROM list_entities_cursor_with_meta(
    p_schema_id       := $1::TEXT,
    p_limit           := $2::INTEGER,
    p_cursor          := $3::TEXT,
    p_filters         := $4::TEXT[],
    p_include_deleted := $5::BOOLEAN
);

-- ============================================================================
-- Supporting Queries
-- ============================================================================

-- :name encode-cursor-token
-- :command :query
-- :result :one
SELECT encode_cursor_token($1::TIMESTAMPTZ, $2::UUID) AS cursor_token;

-- :name decode-cursor-token
-- :command :query
-- :result :one
SELECT * FROM decode_cursor_token($1::TEXT);

-- :name count-entities-by-schema
-- :command :query
-- :result :one
SELECT COUNT(*) AS total_count
FROM entities
WHERE schema_id = $1::UUID
  AND ($2::BOOLEAN OR deleted_at IS NULL);

-- :name enqueue-entities-queried-event
-- :command :query
-- :result :one
SELECT enqueue_entities_queried_event(
    p_schema_id       := $1::TEXT,
    p_limit           := $2::INTEGER,
    p_filters_applied := $3::TEXT[],
    p_has_cursor      := $4::BOOLEAN,
    p_has_next_page   := $5::BOOLEAN,
    p_total_count     := $6::BIGINT,
    p_duration_ms     := $7::INTEGER
) AS event_id;

-- :name enqueue-invalid-cursor-event
-- :command :query
-- :result :one
SELECT enqueue_invalid_cursor_event(
    p_provided_cursor := $1::TEXT,
    p_schema_id       := $2::TEXT,
    p_error_detail    := $3::TEXT,
    p_request_origin  := $4::TEXT
) AS event_id;

-- :name verify-cursor-pagination
-- :command :query
-- :result :many
SELECT * FROM verify_cursor_pagination();
