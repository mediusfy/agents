-- Migration: 008_cluster_02_unified_resource_view.up.sql
-- Description: CLUSTER-02: Unified Cross-Cluster Resource View
-- Bounded Context: Cluster Management (Read Model)
--
-- This migration creates the read-optimized schema for aggregating Kubernetes
-- resources across all connected clusters. It provides:
--   - Normalized resource catalog (Pods, Deployments, Services, Nodes, etc.)
--   - Labels and annotations with GIN-indexed JSONB for cross-cluster search
--   - Status conditions tracking
--   - Owner references (parent-child resource relationships)
--   - Resource metrics (CPU, memory, network)
--   - Full-text search via tsvector
--   - Materialized view for aggregated cross-cluster statistics
--   - Time-based partitioning for resource snapshots (via pg_partman)

-- ============================================================================
-- ENUM TYPES
-- ============================================================================

CREATE TYPE cluster_resource_health AS ENUM (
    'healthy',
    'degraded',
    'unhealthy',
    'unknown',
    'pending'
);

CREATE TYPE resource_sync_status AS ENUM (
    'synced',
    'syncing',
    'sync_failed',
    'orphaned',
    'stale'
);

CREATE TYPE resource_phase AS ENUM (
    'running',
    'pending',
    'succeeded',
    'failed',
    'unknown',
    'terminating',
    'available',
    'unavailable',
    'bound',
    'released'
);

CREATE TYPE view_visibility AS ENUM (
    'private',
    'team',
    'organization'
);

-- ============================================================================
-- LOOKUP TABLES
-- ============================================================================

-- Resource categories for logical grouping (Workload, Network, Storage, etc.)
CREATE TABLE IF NOT EXISTS cluster_resource_categories (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(64)  NOT NULL UNIQUE,
    slug        VARCHAR(64)  NOT NULL UNIQUE,
    description TEXT,
    icon        VARCHAR(64),
    sort_order  INT          NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TRIGGER update_cluster_resource_categories_modtime
    BEFORE UPDATE ON cluster_resource_categories
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- Kubernetes resource type registry (Pod, Deployment, Service, Node, etc.)
CREATE TABLE IF NOT EXISTS cluster_resource_types (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id     UUID REFERENCES cluster_resource_categories(id) ON DELETE SET NULL,
    api_group       VARCHAR(128),       -- e.g., "apps", "" (core), "networking.k8s.io"
    api_version     VARCHAR(64),        -- e.g., "v1", "v1beta1"
    resource_kind   VARCHAR(128) NOT NULL,  -- e.g., "Pod", "Deployment", "Service"
    resource_name_plural VARCHAR(128),  -- e.g., "pods", "deployments", "services"
    short_name      VARCHAR(16),         -- e.g., "po", "deploy", "svc"
    namespaced      BOOLEAN      NOT NULL DEFAULT TRUE,
    scope           VARCHAR(32)  NOT NULL DEFAULT 'Namespaced'
                    CHECK (scope IN ('Namespaced', 'Cluster', 'Namespaced+Cluster')),
    description     TEXT,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (api_group, api_version, resource_kind)
);

CREATE TRIGGER update_cluster_resource_types_modtime
    BEFORE UPDATE ON cluster_resource_types
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX idx_resource_types_category ON cluster_resource_types(category_id);
CREATE INDEX idx_resource_types_scope   ON cluster_resource_types(scope);
CREATE INDEX idx_resource_types_active  ON cluster_resource_types(is_active) WHERE is_active = TRUE;

-- ============================================================================
-- CORE RESOURCE TABLES
-- ============================================================================

-- Normalized namespace catalog across all clusters
CREATE TABLE IF NOT EXISTS cluster_namespaces (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id      UUID         NOT NULL,  -- FK to cluster_connections.id
    name            VARCHAR(253) NOT NULL,  -- DNS label max 253 chars
    uid             VARCHAR(128),           -- K8s UID
    resource_version VARCHAR(128),          -- K8s resource version for change tracking
    status_phase    VARCHAR(32)  NOT NULL DEFAULT 'Active',
    labels          JSONB        DEFAULT '{}',
    annotations     JSONB        DEFAULT '{}',
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    first_seen_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    last_seen_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (cluster_id, name)
);

CREATE TRIGGER update_cluster_namespaces_modtime
    BEFORE UPDATE ON cluster_namespaces
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX idx_namespaces_cluster     ON cluster_namespaces(cluster_id);
CREATE INDEX idx_namespaces_phase       ON cluster_namespaces(status_phase);
CREATE INDEX idx_namespaces_labels      ON cluster_namespaces USING GIN (labels);
CREATE INDEX idx_namespaces_annotations ON cluster_namespaces USING GIN (annotations);
CREATE INDEX idx_namespaces_active      ON cluster_namespaces(is_active) WHERE is_active = TRUE;
CREATE INDEX idx_namespaces_last_seen   ON cluster_namespaces(last_seen_at);

-- Main resource catalog: normalized view of every K8s resource across clusters
CREATE TABLE IF NOT EXISTS cluster_resources (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id          UUID             NOT NULL,  -- FK to cluster_connections.id
    namespace_id        UUID             REFERENCES cluster_namespaces(id) ON DELETE SET NULL,
    resource_type_id    UUID             NOT NULL REFERENCES cluster_resource_types(id),
    resource_uid        VARCHAR(128),               -- K8s resource UID (unique per cluster)
    name                VARCHAR(253)     NOT NULL,
    api_group           VARCHAR(128),
    api_version         VARCHAR(64),
    resource_kind       VARCHAR(128)     NOT NULL,
    -- Resource metadata
    resource_version    VARCHAR(128),               -- For change tracking / optimistic concurrency
    generation          BIGINT,                     -- K8s generation counter
    -- Status
    phase               resource_phase,
    health              cluster_resource_health NOT NULL DEFAULT 'unknown',
    sync_status         resource_sync_status  NOT NULL DEFAULT 'syncing',
    -- Rich metadata
    labels              JSONB            DEFAULT '{}',
    annotations         JSONB            DEFAULT '{}',
    spec                JSONB,                      -- Selective spec fields for search
    status              JSONB,                      -- Selective status fields for display
    -- Ownership
    owner_references    JSONB            DEFAULT '[]',  -- Array of owner references
    -- Timestamps
    creation_timestamp  TIMESTAMPTZ,                -- K8s resource creation time
    deletion_timestamp  TIMESTAMPTZ,                -- If set, resource is being deleted
    first_seen_at       TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    last_seen_at        TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    last_synced_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    -- Soft delete for resource lifecycle tracking
    deleted_at          TIMESTAMPTZ,
    -- Unique constraint: each resource from a cluster must be unique by UID or name+type
    UNIQUE (cluster_id, resource_uid),
    UNIQUE (cluster_id, namespace_id, resource_type_id, name)
);

CREATE TRIGGER update_cluster_resources_modtime
    BEFORE UPDATE ON cluster_resources
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- INDEXES FOR cluster_resources
-- ============================================================================

-- Cluster and namespace lookups
CREATE INDEX idx_resources_cluster      ON cluster_resources(cluster_id);
CREATE INDEX idx_resources_namespace    ON cluster_resources(namespace_id);
CREATE INDEX idx_resources_type         ON cluster_resources(resource_type_id);

-- Search and filter indexes
CREATE INDEX idx_resources_name         ON cluster_resources(name);
CREATE INDEX idx_resources_phase        ON cluster_resources(phase);
CREATE INDEX idx_resources_health       ON cluster_resources(health);
CREATE INDEX idx_resources_sync_status  ON cluster_resources(sync_status);
CREATE INDEX idx_resources_kind         ON cluster_resources(resource_kind);

-- GIN indexes for JSONB querying
CREATE INDEX idx_resources_labels       ON cluster_resources USING GIN (labels);
CREATE INDEX idx_resources_annotations  ON cluster_resources USING GIN (annotations);
CREATE INDEX idx_resources_spec         ON cluster_resources USING GIN (spec);
CREATE INDEX idx_resources_status       ON cluster_resources USING GIN (status);
CREATE INDEX idx_resources_owners       ON cluster_resources USING GIN (owner_references);

-- Composite indexes for common query patterns
CREATE INDEX idx_resources_cluster_kind    ON cluster_resources(cluster_id, resource_kind);
CREATE INDEX idx_resources_cluster_phase   ON cluster_resources(cluster_id, phase);
CREATE INDEX idx_resources_cluster_health  ON cluster_resources(cluster_id, health);
CREATE INDEX idx_resources_ns_kind         ON cluster_resources(namespace_id, resource_kind);
CREATE INDEX idx_resources_cluster_ns_kind ON cluster_resources(cluster_id, namespace_id, resource_kind);

-- Active resources only (excludes soft-deleted)
CREATE INDEX idx_resources_active       ON cluster_resources(cluster_id) WHERE deleted_at IS NULL;

-- Time-based indexes for freshness queries
CREATE INDEX idx_resources_last_seen    ON cluster_resources(last_seen_at);
CREATE INDEX idx_resources_last_synced  ON cluster_resources(last_synced_at);
CREATE INDEX idx_resources_created      ON cluster_resources(created_at);

-- Full-text search support
CREATE INDEX idx_resources_name_trgm    ON cluster_resources USING GIN (name gin_trgm_ops);

-- Resource creation/deletion timestamps for time-range queries
CREATE INDEX idx_resources_creation_ts  ON cluster_resources(creation_timestamp);
CREATE INDEX idx_resources_deleted      ON cluster_resources(deleted_at) WHERE deleted_at IS NOT NULL;

-- ============================================================================
-- RESOURCE LABELS (normalized for efficient key-based queries)
-- ============================================================================

CREATE TABLE IF NOT EXISTS cluster_resource_labels (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_id     UUID NOT NULL REFERENCES cluster_resources(id) ON DELETE CASCADE,
    key             VARCHAR(253) NOT NULL,
    value           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (resource_id, key)
);

CREATE INDEX idx_resource_labels_key     ON cluster_resource_labels(key);
CREATE INDEX idx_resource_labels_value   ON cluster_resource_labels(value);
CREATE INDEX idx_resource_labels_kv      ON cluster_resource_labels(key, value);
CREATE INDEX idx_resource_labels_resource ON cluster_resource_labels(resource_id);

-- ============================================================================
-- RESOURCE CONDITIONS (e.g., Pod Ready, Deployment Available)
-- ============================================================================

CREATE TABLE IF NOT EXISTS cluster_resource_conditions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_id     UUID NOT NULL REFERENCES cluster_resources(id) ON DELETE CASCADE,
    type            VARCHAR(128) NOT NULL,   -- e.g., "Ready", "Available", "Progressing"
    status          VARCHAR(32)  NOT NULL,   -- "True", "False", "Unknown"
    reason          VARCHAR(256),
    message         TEXT,
    last_transition_time TIMESTAMPTZ,
    observed_generation  BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (resource_id, type)
);

CREATE TRIGGER update_resource_conditions_modtime
    BEFORE UPDATE ON cluster_resource_conditions
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX idx_resource_conditions_type   ON cluster_resource_conditions(type);
CREATE INDEX idx_resource_conditions_status ON cluster_resource_conditions(status);
CREATE INDEX idx_resource_conditions_type_status ON cluster_resource_conditions(type, status);

-- ============================================================================
-- RESOURCE OWNER REFERENCES (parent-child relationships)
-- ============================================================================

CREATE TABLE IF NOT EXISTS cluster_resource_owners (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    child_resource_id  UUID NOT NULL REFERENCES cluster_resources(id) ON DELETE CASCADE,
    parent_resource_id UUID REFERENCES cluster_resources(id) ON DELETE CASCADE,
    owner_uid         VARCHAR(128),             -- K8s UID of owner (used when parent not yet ingested)
    owner_kind        VARCHAR(128) NOT NULL,    -- e.g., "ReplicaSet", "Deployment"
    owner_name        VARCHAR(253) NOT NULL,
    controller        BOOLEAN NOT NULL DEFAULT FALSE,
    block_owner_deletion BOOLEAN NOT NULL DEFAULT FALSE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (child_resource_id, owner_uid, owner_kind)
);

CREATE INDEX idx_resource_owners_child  ON cluster_resource_owners(child_resource_id);
CREATE INDEX idx_resource_owners_parent ON cluster_resource_owners(parent_resource_id);
CREATE INDEX idx_resource_owners_uid    ON cluster_resource_owners(owner_uid);
CREATE INDEX idx_resource_owners_kind   ON cluster_resource_owners(owner_kind);
CREATE INDEX idx_resource_owners_ctrl   ON cluster_resource_owners(controller) WHERE controller = TRUE;

-- ============================================================================
-- RESOURCE METRICS (CPU, memory, network, storage)
-- ============================================================================

CREATE TABLE IF NOT EXISTS cluster_resource_metrics (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_id     UUID NOT NULL REFERENCES cluster_resources(id) ON DELETE CASCADE,
    metric_name     VARCHAR(128) NOT NULL,     -- e.g., "cpu_usage", "memory_usage", "network_rx_bytes"
    metric_value    DOUBLE PRECISION NOT NULL,
    metric_unit     VARCHAR(32)  NOT NULL,     -- e.g., "cores", "bytes", "millicores", "MiB"
    recorded_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (resource_id, metric_name, recorded_at)
);

CREATE INDEX idx_resource_metrics_name     ON cluster_resource_metrics(metric_name);
CREATE INDEX idx_resource_metrics_resource ON cluster_resource_metrics(resource_id);
CREATE INDEX idx_resource_metrics_time     ON cluster_resource_metrics(recorded_at);
CREATE INDEX idx_resource_metrics_name_time ON cluster_resource_metrics(metric_name, recorded_at);

-- Latest metric values per resource (partial index for dashboard queries)
CREATE UNIQUE INDEX idx_resource_metrics_latest
    ON cluster_resource_metrics(resource_id, metric_name)
    WHERE recorded_at = (SELECT MAX(recorded_at) FROM cluster_resource_metrics m2
                          WHERE m2.resource_id = cluster_resource_metrics.resource_id
                            AND m2.metric_name = cluster_resource_metrics.metric_name);

-- ============================================================================
-- RESOURCE SNAPSHOTS (historical point-in-time captures for audit/timeline)
-- ============================================================================

-- Uses pg_partman for monthly partitioning on snapshot_date
CREATE TABLE IF NOT EXISTS cluster_resource_snapshots (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id          UUID         NOT NULL,
    namespace_id        UUID,
    resource_type_id    UUID         NOT NULL,
    resource_uid        VARCHAR(128),
    name                VARCHAR(253) NOT NULL,
    resource_kind       VARCHAR(128) NOT NULL,
    -- Snapshot of key fields
    phase               resource_phase,
    health              cluster_resource_health,
    labels              JSONB DEFAULT '{}',
    status              JSONB DEFAULT '{}',
    -- Ownership at snapshot time
    owner_kind          VARCHAR(128),
    owner_name          VARCHAR(253),
    -- Snapshot metadata
    snapshot_date       DATE         NOT NULL,
    snapshot_reason     VARCHAR(64)  NOT NULL DEFAULT 'scheduled'
                        CHECK (snapshot_reason IN ('scheduled', 'event', 'manual', 'change_detected')),
    changes_since_last  JSONB DEFAULT '{}',  -- Diff of changes
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (snapshot_date);

CREATE INDEX idx_snapshots_cluster     ON cluster_resource_snapshots(cluster_id);
CREATE INDEX idx_snapshots_type        ON cluster_resource_snapshots(resource_type_id);
CREATE INDEX idx_snapshots_date        ON cluster_resource_snapshots(snapshot_date);
CREATE INDEX idx_snapshots_kind        ON cluster_resource_snapshots(resource_kind);
CREATE INDEX idx_snapshots_reason      ON cluster_resource_snapshots(snapshot_reason);
CREATE INDEX idx_snapshots_health      ON cluster_resource_snapshots(health);

-- ============================================================================
-- SAVED VIEWS (user-configurable cross-cluster resource views)
-- ============================================================================

CREATE TABLE IF NOT EXISTS saved_resource_views (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id        UUID         NOT NULL,  -- FK to user accounts
    name            VARCHAR(256) NOT NULL,
    description     TEXT,
    visibility      view_visibility NOT NULL DEFAULT 'private',
    -- Filter configuration (stored as JSON for flexibility)
    filters         JSONB        NOT NULL DEFAULT '{}',
    -- Supported filter fields:
    -- {
    --   "cluster_ids": ["uuid1", "uuid2"],
    --   "namespace_ids": ["uuid1"],
    --   "resource_kinds": ["Pod", "Deployment"],
    --   "health": ["healthy", "degraded"],
    --   "phases": ["running"],
    --   "label_selector": {"key": "app", "operator": "In", "values": ["nginx"]},
    --   "search_text": "search term",
    --   "owner_kind": "Deployment"
    -- }
    columns_config  JSONB        NOT NULL DEFAULT '[]',  -- Visible columns config
    sort_config     JSONB        DEFAULT '{}',            -- Default sort configuration
    is_default      BOOLEAN      NOT NULL DEFAULT FALSE,
    is_shared       BOOLEAN      NOT NULL DEFAULT FALSE,
    last_used_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (owner_id, name)
);

CREATE TRIGGER update_saved_views_modtime
    BEFORE UPDATE ON saved_resource_views
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

CREATE INDEX idx_saved_views_owner    ON saved_resource_views(owner_id);
CREATE INDEX idx_saved_views_default  ON saved_resource_views(owner_id, is_default) WHERE is_default = TRUE;
CREATE INDEX idx_saved_views_shared   ON saved_resource_views(visibility) WHERE visibility != 'private';

-- ============================================================================
-- MATERIALIZED VIEW: Cross-Cluster Resource Summary
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS cross_cluster_resource_summary AS
SELECT
    cr.cluster_id,
    cr.resource_kind,
    crt.category_id,
    crc.name AS category_name,
    COUNT(*)                                              AS total_resources,
    COUNT(*) FILTER (WHERE cr.deleted_at IS NULL)         AS active_resources,
    COUNT(*) FILTER (WHERE cr.deleted_at IS NOT NULL)     AS deleted_resources,
    COUNT(*) FILTER (WHERE cr.health = 'healthy')         AS healthy_count,
    COUNT(*) FILTER (WHERE cr.health = 'degraded')        AS degraded_count,
    COUNT(*) FILTER (WHERE cr.health = 'unhealthy')       AS unhealthy_count,
    COUNT(*) FILTER (WHERE cr.health = 'unknown')         AS unknown_health_count,
    COUNT(*) FILTER (WHERE cr.sync_status = 'synced')     AS synced_count,
    COUNT(*) FILTER (WHERE cr.sync_status = 'sync_failed') AS failed_sync_count,
    COUNT(*) FILTER (WHERE cr.phase = 'running'
                      OR cr.phase = 'available')          AS active_phase_count,
    COUNT(*) FILTER (WHERE cr.phase = 'failed'
                      OR cr.phase = 'unavailable')        AS failed_phase_count,
    crc.sort_order                                         AS category_sort_order,
    NOW()                                                  AS refreshed_at
FROM cluster_resources cr
JOIN cluster_resource_types crt ON cr.resource_type_id = crt.id
LEFT JOIN cluster_resource_categories crc ON crt.category_id = crc.id
GROUP BY cr.cluster_id, cr.resource_kind, crt.category_id, crc.name, crc.sort_order
ORDER BY cr.cluster_id, crc.sort_order, cr.resource_kind;

CREATE UNIQUE INDEX idx_matview_summary_unique
    ON cross_cluster_resource_summary (cluster_id, resource_kind);

CREATE INDEX idx_matview_summary_cluster   ON cross_cluster_resource_summary(cluster_id);
CREATE INDEX idx_matview_summary_category  ON cross_cluster_resource_summary(category_id);
CREATE INDEX idx_matview_summary_health    ON cross_cluster_resource_summary(healthy_count, degraded_count, unhealthy_count);

-- ============================================================================
-- MATERIALIZED VIEW: Cluster Namespace Summary
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS cluster_namespace_summary AS
SELECT
    ns.cluster_id,
    ns.name AS namespace_name,
    ns.status_phase,
    ns.labels,
    COUNT(cr.id)                                                     AS total_resources,
    COUNT(cr.id) FILTER (WHERE cr.health = 'healthy')                AS healthy_resources,
    COUNT(cr.id) FILTER (WHERE cr.health IN ('degraded', 'unhealthy')) AS unhealthy_resources,
    COUNT(cr.id) FILTER (WHERE cr.deleted_at IS NULL)                AS active_resources,
    jsonb_object_agg(
        cr.resource_kind,
        COUNT(*)
    ) FILTER (WHERE cr.deleted_at IS NULL)                           AS resources_by_kind,
    MAX(cr.last_seen_at)                                             AS latest_activity,
    NOW()                                                            AS refreshed_at
FROM cluster_namespaces ns
LEFT JOIN cluster_resources cr ON cr.namespace_id = ns.id AND cr.deleted_at IS NULL
GROUP BY ns.cluster_id, ns.name, ns.status_phase, ns.labels;

CREATE UNIQUE INDEX idx_matview_ns_summary_unique
    ON cluster_namespace_summary (cluster_id, namespace_name);

CREATE INDEX idx_matview_ns_summary_phase ON cluster_namespace_summary(status_phase);

-- ============================================================================
-- FUNCTION: Refresh materialized views
-- ============================================================================

CREATE OR REPLACE FUNCTION refresh_cluster_resource_matviews()
RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY cross_cluster_resource_summary;
    REFRESH MATERIALIZED VIEW CONCURRENTLY cluster_namespace_summary;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTION: Search resources by label selector (returns matching resource IDs)
-- ============================================================================

CREATE OR REPLACE FUNCTION search_resources_by_label(
    p_label_key   TEXT,
    p_operator    TEXT,   -- 'Equals', 'NotEquals', 'Exists', 'DoesNotExist', 'In', 'NotIn'
    p_label_value TEXT DEFAULT NULL,
    p_values      TEXT[] DEFAULT NULL
)
RETURNS TABLE(resource_id UUID) AS $$
BEGIN
    RETURN QUERY
    SELECT cr.id
    FROM cluster_resources cr
    WHERE
        CASE p_operator
            WHEN 'Equals' THEN
                cr.labels @> jsonb_build_object(p_label_key, p_label_value)
            WHEN 'NotEquals' THEN
                NOT (cr.labels @> jsonb_build_object(p_label_key, p_label_value))
                OR NOT cr.labels ? p_label_key
            WHEN 'Exists' THEN
                cr.labels ? p_label_key
            WHEN 'DoesNotExist' THEN
                NOT (cr.labels ? p_label_key)
            WHEN 'In' THEN
                cr.labels @> jsonb_build_object(p_label_key, p_label_value)
                AND cr.labels->>p_label_key = ANY(p_values)
            WHEN 'NotIn' THEN
                cr.labels ? p_label_key
                AND NOT (cr.labels->>p_label_key = ANY(p_values))
            ELSE FALSE
        END
        AND cr.deleted_at IS NULL;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- TRIGGER: Auto-refresh materialized views on resource changes
-- Note: In production, use pg_cron or application-level scheduled refresh.
-- This trigger provides near-real-time updates for small deployments.
-- ============================================================================

CREATE OR REPLACE FUNCTION trigger_refresh_resource_matviews()
RETURNS TRIGGER AS $$
BEGIN
    -- Notify a background worker to refresh matviews (avoids blocking DML)
    PERFORM pg_notify('refresh_resource_matviews', '');
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_refresh_matviews_on_resource_change
    AFTER INSERT OR UPDATE OR DELETE ON cluster_resources
    FOR EACH STATEMENT
    EXECUTE FUNCTION trigger_refresh_resource_matviews();

-- ============================================================================
-- Event triggers for audit logging (integration with CLUSTER-01 audit log)
-- ============================================================================

CREATE OR REPLACE FUNCTION log_resource_change()
RETURNS TRIGGER AS $$
BEGIN
    -- Insert into cluster_connection_audit_log when available
    -- This is a placeholder for cross-context event integration
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- EXTENSION REQUIREMENTS
-- ============================================================================

-- Ensure required extensions exist
-- CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- For trigram fuzzy search indexes
-- CREATE EXTENSION IF NOT EXISTS pg_partman; -- For snapshot partitioning (if using auto-management)

-- Note: pg_partman configuration for snapshot partitioning should be done via:
-- SELECT partman.create_parent(
--     p_parent_table := 'public.cluster_resource_snapshots',
--     p_control := 'snapshot_date',
--     p_type := 'native',
--     p_interval := '1 month',
--     p_start_partition := (CURRENT_DATE - INTERVAL '3 months')::TEXT
-- );
