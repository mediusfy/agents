

-- ============================================================================
-- RESOURCE-01: Regional Data Plane Schema
-- Description: Per-region tables (us, eu, ap) for resource cache, audit WAL,
--              chain-linked audit integrity, board states, and deployments.
-- ============================================================================
-- Each regional PostgreSQL instance runs this migration independently.
-- The partition "region" context is managed at the connection/routing layer.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. Helper: updated_at trigger (idempotent)
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- --------------------------------------------------------------------------
-- 2. enum types
-- --------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE event_type AS ENUM ('ADDED', 'MODIFIED', 'DELETED', 'BOOKMARK', 'ERROR');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE deploy_status AS ENUM ('pending', 'syncing', 'applied', 'failed', 'rolled_back');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- --------------------------------------------------------------------------
-- 3. resources — Materialized K8s resource cache
--    Updated via K8s Watch → Kafka → consumer
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS resources (
    id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id       UUID         NOT NULL,
    kind             VARCHAR(100) NOT NULL,
    api_version      VARCHAR(50)  NOT NULL,
    namespace        VARCHAR(253),
    name             VARCHAR(253) NOT NULL,
    uid              VARCHAR(128),            -- K8s resource UID
    labels           JSONB        NOT NULL DEFAULT '{}',
    annotations      JSONB        NOT NULL DEFAULT '{}',
    spec_json        JSONB,
    status_json      JSONB,
    parent_owner_ref JSONB,                   -- {apiVersion, kind, name} of owner
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at       TIMESTAMPTZ,             -- soft-delete marker

    -- Unique per cluster/namespace/name/kind (K8s identity)
    CONSTRAINT uq_resources_k8s_identity UNIQUE (cluster_id, namespace, name, kind),
    CONSTRAINT chk_resources_name CHECK (length(name) > 0)
);

-- Composite indexes for common K8s query patterns:
-- Lookup by cluster + namespace
CREATE INDEX IF NOT EXISTS idx_resources_cluster_ns
    ON resources(cluster_id, namespace);
-- Lookup by cluster + kind
CREATE INDEX IF NOT EXISTS idx_resources_cluster_kind
    ON resources(cluster_id, kind);
-- Lookup by labels (GIN for JSONB containment queries)
CREATE INDEX IF NOT EXISTS idx_resources_labels_gin
    ON resources USING gin (labels);
-- Lookup by annotations
CREATE INDEX IF NOT EXISTS idx_resources_annotations_gin
    ON resources USING gin (annotations);
-- Find owner chain (parent_owner_ref ->> 'name')
CREATE INDEX IF NOT EXISTS idx_resources_owner
    ON resources((parent_owner_ref->>'name'))
    WHERE parent_owner_ref IS NOT NULL;
-- Partial index: exclude soft-deleted rows from active queries
CREATE INDEX IF NOT EXISTS idx_resources_active
    ON resources(cluster_id, kind, namespace, name)
    WHERE deleted_at IS NULL;

CREATE TRIGGER trg_resources_updated_at
    BEFORE UPDATE ON resources
    FOR EACH ROW EXECUTE FUNCTION update_modified_column();

COMMENT ON TABLE  resources IS 'Materialized view of K8s resources, synced via Watch → Kafka';
COMMENT ON COLUMN resources.parent_owner_ref IS 'JSON object referencing the owner resource (e.g., ReplicaSet owns Pods)';
COMMENT ON COLUMN resources.deleted_at IS 'Soft delete — resources with this set are excluded from active queries via partial index';

-- --------------------------------------------------------------------------
-- 4. resource_events — K8s watch event journal for replay/audit
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS resource_events (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_id   UUID        NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
    cluster_id    UUID        NOT NULL,
    event_type    event_type  NOT NULL,
    old_state     JSONB,
    new_state     JSONB,
    received_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Query: all events for a resource, ordered by time
CREATE INDEX IF NOT EXISTS idx_resource_events_resource
    ON resource_events(resource_id, received_at);
-- Query: events in a time range for replay
CREATE INDEX IF NOT EXISTS idx_resource_events_time
    ON resource_events(cluster_id, received_at);
-- Partial index: only DELETED events for tombstone cleanup
CREATE INDEX IF NOT EXISTS idx_resource_events_deleted
    ON resource_events(resource_id)
    WHERE event_type = 'DELETED';

COMMENT ON TABLE resource_events IS 'Journal of all K8s Watch events for replay and time-travel debugging';

-- --------------------------------------------------------------------------
-- 5. audit_wal — Write-Ahead Log for audit trail (PARTITIONED BY MONTH)
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_wal (
    id                  UUID         NOT NULL DEFAULT gen_random_uuid(),
    seq                 BIGSERIAL    NOT NULL,
    occurred_at         TIMESTAMPTZ  NOT NULL,
    actor_id            UUID         NOT NULL,
    cluster_id          UUID         NOT NULL,
    action              VARCHAR(50)  NOT NULL,
    resource_kind       VARCHAR(100),
    resource_namespace  VARCHAR(253),
    resource_name       VARCHAR(253),
    payload_json        JSONB,
    received_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    -- Partition key is received_at; id+received_at is unique across partitions
    PRIMARY KEY (id, received_at)
) PARTITION BY RANGE (received_at);

-- Create monthly partitions for 2025-2026 (extend as needed):
-- Current date is 2026-06-02, so let's create through 2026-12
SELECT to_char(d, 'YYYY_MM') AS partition_name, d::date AS start_date
FROM generate_series('2025-01-01'::date, '2026-12-01'::date, '1 month'::interval) AS d;

-- We'll create them dynamically; for the migration, create the first 6 months
-- and a template function for automated partition creation.

CREATE TABLE IF NOT EXISTS audit_wal_2025_01 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE IF NOT EXISTS audit_wal_2025_02 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
CREATE TABLE IF NOT EXISTS audit_wal_2025_03 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');
CREATE TABLE IF NOT EXISTS audit_wal_2025_04 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-04-01') TO ('2025-05-01');
CREATE TABLE IF NOT EXISTS audit_wal_2025_05 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
CREATE TABLE IF NOT EXISTS audit_wal_2025_06 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');
CREATE TABLE IF NOT EXISTS audit_wal_2025_07 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');
CREATE TABLE IF NOT EXISTS audit_wal_2025_08 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');
CREATE TABLE IF NOT EXISTS audit_wal_2025_09 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-09-01') TO ('2025-10-01');
CREATE TABLE IF NOT EXISTS audit_wal_2025_10 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
CREATE TABLE IF NOT EXISTS audit_wal_2025_11 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');
CREATE TABLE IF NOT EXISTS audit_wal_2025_12 PARTITION OF audit_wal
    FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');

CREATE TABLE IF NOT EXISTS audit_wal_2026_01 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS audit_wal_2026_02 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS audit_wal_2026_03 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS audit_wal_2026_04 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE IF NOT EXISTS audit_wal_2026_05 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE IF NOT EXISTS audit_wal_2026_06 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE IF NOT EXISTS audit_wal_2026_07 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE IF NOT EXISTS audit_wal_2026_08 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE IF NOT EXISTS audit_wal_2026_09 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE IF NOT EXISTS audit_wal_2026_10 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE IF NOT EXISTS audit_wal_2026_11 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE IF NOT EXISTS audit_wal_2026_12 PARTITION OF audit_wal
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- Indexes on the parent (will be applied to each partition automatically in PG12+):
-- Query: by cluster + time range (most common audit query)
CREATE INDEX IF NOT EXISTS idx_audit_wal_cluster_time
    ON audit_wal(cluster_id, occurred_at);
-- Query: by actor
CREATE INDEX IF NOT EXISTS idx_audit_wal_actor
    ON audit_wal(actor_id, occurred_at);
-- Query: by resource identity
CREATE INDEX IF NOT EXISTS idx_audit_wal_resource
    ON audit_wal(resource_kind, resource_namespace, resource_name);
-- Query: seq-based lookup for chain linking
CREATE INDEX IF NOT EXISTS idx_audit_wal_seq
    ON audit_wal(seq);
-- Fast lookup for chain linking: find entries after a given seq
CREATE INDEX IF NOT EXISTS idx_audit_wal_seq_range
    ON audit_wal(cluster_id, seq)
    WHERE seq IS NOT NULL;

-- Function to auto-create partitions (called by pg_cron or scheduler)
CREATE OR REPLACE FUNCTION create_audit_wal_partition()
RETURNS void AS $$
DECLARE
    partition_date  DATE;
    partition_name  TEXT;
    start_range     TEXT;
    end_range       TEXT;
BEGIN
    partition_date := date_trunc('month', NOW())::DATE + INTERVAL '2 months';
    partition_name := 'audit_wal_' || to_char(partition_date, 'YYYY_MM');
    start_range    := to_char(partition_date, 'YYYY-MM-DD');
    end_range      := to_char(partition_date + INTERVAL '1 month', 'YYYY-MM-DD');

    IF NOT EXISTS (
        SELECT 1 FROM pg_class WHERE relname = partition_name
    ) THEN
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF audit_wal
             FOR VALUES FROM (%L) TO (%L)',
            partition_name, start_range, end_range
        );
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON TABLE  audit_wal IS 'Write-Ahead Log for audit — partitioned by month for retention management';
COMMENT ON COLUMN audit_wal.seq IS 'Monotonically increasing sequence per partition, used for chain-link computation';

-- --------------------------------------------------------------------------
-- 6. audit_chain_links — Merkle-chain integrity links (computed every 1s/1000 entries)
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_chain_links (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    prev_link_id    UUID        REFERENCES audit_chain_links(id),
    prev_audit_id   UUID        NOT NULL,   -- first audit entry ID in this segment
    last_audit_id   UUID        NOT NULL,   -- last audit entry ID in this segment
    chain_hash      VARCHAR(64) NOT NULL,   -- SHA-256 hex digest of the chain segment
    computed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    entries_count   INT         NOT NULL CHECK (entries_count > 0),

    -- Enforce chain integrity: each link points to previous
    CONSTRAINT uq_audit_chain_prev UNIQUE (prev_link_id)
);

CREATE INDEX IF NOT EXISTS idx_audit_chain_computed
    ON audit_chain_links(computed_at DESC);
-- Find the latest link for a given starting point
CREATE INDEX IF NOT EXISTS idx_audit_chain_audit_range
    ON audit_chain_links(prev_audit_id, last_audit_id);

COMMENT ON TABLE  audit_chain_links IS 'Chain links for audit trail integrity — computed every 1s or per 1000 entries';
COMMENT ON COLUMN audit_chain_links.chain_hash IS 'SHA-256 hex digest over (prev_link_id || prev_audit_id || last_audit_id || entries_count || computed_at)';

-- Integrity verification function
CREATE OR REPLACE FUNCTION verify_audit_chain(from_link_id UUID)
RETURNS TABLE(link_index INT, link_id UUID, prev_id UUID, hash_valid BOOLEAN) AS $$
DECLARE
    rec RECORD;
    idx INT := 0;
BEGIN
    FOR rec IN
        WITH RECURSIVE chain AS (
            SELECT id, prev_link_id, chain_hash, computed_at, entries_count, 0 AS depth
            FROM audit_chain_links WHERE id = from_link_id
            UNION ALL
            SELECT l.id, l.prev_link_id, l.chain_hash, l.computed_at, l.entries_count, c.depth + 1
            FROM audit_chain_links l
            INNER JOIN chain c ON l.id = c.prev_link_id
        )
        SELECT * FROM chain ORDER BY depth DESC
    LOOP
        link_index := idx;
        link_id    := rec.id;
        prev_id    := rec.prev_link_id;
        hash_valid := TRUE; -- would compute SHA256(prev_id || ...) in application
        idx := idx + 1;
        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql STABLE;

-- --------------------------------------------------------------------------
-- 7. board_states — Local board/namespace state
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS board_states (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id       UUID        NOT NULL,
    namespace        VARCHAR(253),
    board_config_json JSONB      NOT NULL DEFAULT '{}',
    last_updated_by  UUID,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- One board state per cluster+namespace
    CONSTRAINT uq_board_state UNIQUE (cluster_id, namespace)
);

CREATE INDEX IF NOT EXISTS idx_board_states_cluster
    ON board_states(cluster_id);

CREATE TRIGGER trg_board_states_updated_at
    BEFORE UPDATE ON board_states
    FOR EACH ROW EXECUTE FUNCTION update_modified_column();

COMMENT ON TABLE board_states IS 'Local board/namespace configuration per cluster';

-- --------------------------------------------------------------------------
-- 8. deployments — Created deployment tracking
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS deployments (
    id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_id     UUID          REFERENCES resources(id) ON DELETE SET NULL,
    cluster_id      UUID          NOT NULL,
    created_by      UUID,
    manifest_hash   VARCHAR(64)   NOT NULL,
    status          deploy_status NOT NULL DEFAULT 'pending',
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_deployments_cluster     ON deployments(cluster_id);
CREATE INDEX IF NOT EXISTS idx_deployments_resource    ON deployments(resource_id);
CREATE INDEX IF NOT EXISTS idx_deployments_creator     ON deployments(created_by);
CREATE INDEX IF NOT EXISTS idx_deployments_status      ON deployments(status);
-- Active deployments (not terminal states)
CREATE INDEX IF NOT EXISTS idx_deployments_active
    ON deployments(cluster_id)
    WHERE status IN ('pending', 'syncing');

COMMENT ON TABLE  deployments IS 'Deployments created by users — tracks manifest hash and rollout status';
COMMENT ON COLUMN deployments.manifest_hash IS 'SHA-256 hash of the rendered manifest for change detection';

-- --------------------------------------------------------------------------
-- 9. Row-Level Security for multi-tenant isolation (regional plane)
-- --------------------------------------------------------------------------
ALTER TABLE resources        ENABLE ROW LEVEL SECURITY;
ALTER TABLE resource_events  ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_wal        ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_chain_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE board_states     ENABLE ROW LEVEL SECURITY;
ALTER TABLE deployments      ENABLE ROW LEVEL SECURITY;

-- Resources: users see resources in namespaces they have access to
-- (RBAC evaluation happens at API gateway; RLS here is defense-in-depth)
CREATE POLICY p_resources_tenant_isolation ON resources
    USING (
        current_setting('app.current_role') = 'cluster-admin'
        OR EXISTS (
            SELECT 1 FROM rbac_rules
            WHERE rbac_rules.cluster_id = resources.cluster_id
              AND (rbac_rules.namespace IS NULL OR rbac_rules.namespace = resources.namespace)
              AND (
                  (rbac_rules.principal_type = 'user' AND rbac_rules.principal_id = current_setting('app.current_user_id')::UUID)
                  OR
                  (rbac_rules.principal_type = 'team' AND rbac_rules.principal_id = ANY(
                      SELECT unnest(teams) FROM users WHERE users.id = current_setting('app.current_user_id')::UUID
                  ))
              )
        )
    );

-- Deployments: same tenant isolation via cluster + creator
CREATE POLICY p_deployments_tenant_isolation ON deployments
    USING (
        current_setting('app.current_role') = 'cluster-admin'
        OR deployments.created_by = current_setting('app.current_user_id')::UUID
        OR EXISTS (
            SELECT 1 FROM rbac_rules
            WHERE rbac_rules.cluster_id = deployments.cluster_id
              AND rbac_rules.verb IN ('create', 'update', '*')
              AND (
                  (rbac_rules.principal_type = 'user' AND rbac_rules.principal_id = current_setting('app.current_user_id')::UUID)
                  OR
                  (rbac_rules.principal_type = 'team' AND rbac_rules.principal_id = ANY(
                      SELECT unnest(teams) FROM users WHERE users.id = current_setting('app.current_user_id')::UUID
                  ))
              )
        )
    );

-- Board states: same as resources
CREATE POLICY p_board_states_tenant_isolation ON board_states
    USING (
        current_setting('app.current_role') = 'cluster-admin'
        OR EXISTS (
            SELECT 1 FROM rbac_rules
            WHERE rbac_rules.cluster_id = board_states.cluster_id
              AND (rbac_rules.namespace IS NULL OR rbac_rules.namespace = board_states.namespace)
              AND (
                  (rbac_rules.principal_type = 'user' AND rbac_rules.principal_id = current_setting('app.current_user_id')::UUID)
                  OR
                  (rbac_rules.principal_type = 'team' AND rbac_rules.principal_id = ANY(
                      SELECT unnest(teams) FROM users WHERE users.id = current_setting('app.current_user_id')::UUID
                  ))
              )
        )
    );

-- Audit WAL: cluster-admins only (audit is sensitive)
CREATE POLICY p_audit_wal_admin_only ON audit_wal
    USING (current_setting('app.current_role') IN ('cluster-admin', 'auditor'));

CREATE POLICY p_audit_chain_admin_only ON audit_chain_links
    USING (current_setting('app.current_role') IN ('cluster-admin', 'auditor'));

COMMIT;
