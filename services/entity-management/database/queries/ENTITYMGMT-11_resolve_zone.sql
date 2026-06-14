-- Query: ENTITYMGMT-11_resolve_zone.sql
-- Story: ENTITYMGMT-11 — System enforces multi-region data residency (us-east-1, eu-west-1)
-- Bounded Context: Entity Management
--
-- Gherkin SCENARIO 1: Resolves an entity's data residency zone from its region.
-- Gherkin SCENARIO 2: Maps known regions one-to-one; unknown regions pass through.
-- Gherkin SCENARIO 3: data_residency_zone is immutable (generated column).
--
-- This query provides the application layer with zone resolution capabilities
-- for entity creation, routing decisions, and observability span enrichment.
-- ============================================================================

-- ============================================================================
-- Query 1: resolve-entity-zone
-- Resolves the data residency zone for a given entity ID.
-- Returns the entity's region, computed zone, and routing decision.
--
-- Gherkin SCENARIO 1:
--   "When an entity is created with region='eu-west-1'
--    Then the entity's DataResidencyZone is resolved to 'eu-west-1'"
--
-- Gherkin SCENARIO 2:
--   "Unknown regions pass through as-is (default behavior)"
--
-- Usage:
--   SELECT * FROM resolve_entity_zone('e1100001-0000-4000-8000-000000000001');
-- ============================================================================

-- :name resolve-entity-zone
-- :command :query
-- :result :one
SELECT * FROM resolve_entity_zone($1::UUID);

-- ============================================================================
-- Query 2: resolve-zone-from-region
-- Resolves a region string to its data residency zone using the database
-- function. This is the SQL equivalent of the domain's ResolveZone().
--
-- Gherkin SCENARIO 2:
--   "When the ResolveZone function is called
--    Then it correctly maps known regions to their residency zones"
--
-- Usage:
--   SELECT compute_data_residency_zone('eu-west-1');  -- returns 'eu-west-1'
--   SELECT compute_data_residency_zone('us-east-1');  -- returns 'us-east-1'
--   SELECT compute_data_residency_zone('unknown');    -- returns 'unknown'
-- ============================================================================

-- :name resolve-zone-from-region
-- :command :query
-- :result :one
SELECT compute_data_residency_zone($1::TEXT) AS data_residency_zone;

-- ============================================================================
-- Query 3: list-entities-by-zone
-- Lists all entities in a given data residency zone with optional status filter.
--
-- Gherkin: "find all active entities in eu-west-1 zone"
--
-- Usage:
--   SELECT * FROM list_entities_by_zone('eu-west-1', 'active', 50, 0);
-- ============================================================================

-- :name list-entities-by-zone
-- :command :query
-- :result :many
SELECT * FROM list_entities_by_zone(
    p_data_residency_zone := $1::TEXT,
    p_status              := $2::entity_status,
    p_limit               := $3::INTEGER,
    p_offset              := $4::INTEGER,
    p_include_deleted     := $5::BOOLEAN
);

-- ============================================================================
-- Query 4: count-entities-by-zone
-- Returns entity counts grouped by data residency zone.
-- Used by ObservabilityContext for latency tracking and capacity planning.
--
-- Gherkin: "observability spans include the region attribute for latency tracking"
-- ============================================================================

-- :name count-entities-by-zone
-- :command :query
-- :result :many
SELECT * FROM count_entities_by_zone();

-- ============================================================================
-- Query 5: insert-region-routed-event
-- Enqueues an entitymanagement.residency.region_routed event into the outbox.
-- Called by the application layer when an entity is routed to a specific zone.
--
-- Gherkin SCENARIO 1:
--   "observability spans include the region attribute for latency tracking"
--     → This event is consumed by ObservabilityContext to enrich spans.
--
-- Usage:
--   SELECT enqueue_region_routed_event(
--     'e1100001-0000-4000-8000-000000000001',  -- entity_id
--     'eu-west-1',                                -- region
--     'eu-west-1',                                -- data_residency_zone
--     'direct_map'                                -- routing_decision
--   );
-- ============================================================================

-- :name insert-region-routed-event
-- :command :query
-- :result :one
SELECT enqueue_region_routed_event(
    p_entity_id           := $1::UUID,
    p_region              := $2::TEXT,
    p_data_residency_zone := $3::TEXT,
    p_routing_decision    := $4::TEXT
) AS event_id;

-- ============================================================================
-- Query 6: get-entities-for-region-routing
-- Retrieves entities that need routing updates for a specific region.
-- Used by RoutingContext to update regional routing tables.
--
-- Gherkin: "RoutingContext — update regional routing table"
-- ============================================================================

-- :name get-entities-for-region-routing
-- :command :query
-- :result :many
SELECT
    e.id,
    e.name,
    e.type,
    e.region,
    e.data_residency_zone,
    e.status,
    e.version,
    e.updated_at,
    e.region_updated_at
FROM entities e
WHERE e.region = $1::VARCHAR(64)
  AND e.deleted_at IS NULL
ORDER BY e.updated_at DESC;

-- ============================================================================
-- Query 7: get-entity-zone-tracking
-- Returns zone tracking information for observability span enrichment.
-- Includes latency tracking data since region_updated_at.
--
-- Gherkin: "observability spans include the region attribute for latency tracking"
-- ============================================================================

-- :name get-entity-zone-tracking
-- :command :query
-- :result :one
SELECT
    e.id              AS entity_id,
    e.name            AS entity_name,
    e.region,
    e.data_residency_zone,
    e.region_updated_at,
    e.created_at,
    EXTRACT(EPOCH FROM (e.updated_at - e.region_updated_at))::BIGINT AS ms_since_region_update,
    CASE
        WHEN e.region = e.data_residency_zone THEN 'direct_map'
        ELSE 'pass_through'
    END               AS routing_decision
FROM entities e
WHERE e.id = $1::UUID
  AND e.deleted_at IS NULL;
