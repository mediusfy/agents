

-- Migration: 010_clusterconnect_01_cluster_connections.sql
-- Description: CLUSTERCONNECT-01 — Multi-cloud Kubernetes cluster connection management.
-- Creates 7 tables for storing cloud provider references, cluster connections (with encrypted
-- kubeconfig), tagging, grouping, health history, and connection audit logging.
-- 
-- Depends on: pgcrypto extension

-- ============================================================
-- UP
-- ============================================================

-- 0. Extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1. Enum: connection status
DO $$ BEGIN
    CREATE TYPE cluster_connection_status AS ENUM (
        'connecting',
        'connected',
        'disconnected',
        'error',
        'unknown'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- 2. Enum: audit action
DO $$ BEGIN
    CREATE TYPE cluster_audit_action AS ENUM (
        'cluster_created',
        'cluster_updated',
        'cluster_deleted',
        'credentials_rotated',
        'connection_tested',
        'cluster_tagged',
        'cluster_untagged',
        'cluster_grouped',
        'cluster_ungrouped'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- 3. Updated-at trigger function (idempotent)
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Table: cloud_providers (reference data)
-- ============================================================
CREATE TABLE IF NOT EXISTS cloud_providers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(64)  NOT NULL UNIQUE,          -- e.g. 'gke', 'eks', 'aks', 'self-managed'
    display_name    VARCHAR(128) NOT NULL,                  -- e.g. 'Google Kubernetes Engine'
    description     TEXT,
    logo_url        VARCHAR(512),
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TRIGGER update_cloud_providers_modtime
    BEFORE UPDATE ON cloud_providers
    FOR EACH ROW EXECUTE FUNCTION update_modified_column();

COMMENT ON TABLE  cloud_providers IS 'Reference table for supported Kubernetes cloud providers.';
COMMENT ON COLUMN cloud_providers.name IS 'Unique machine-readable identifier (e.g. gke, eks, aks).';

-- ============================================================
-- Table: cluster_connections (core)
-- ============================================================
CREATE TABLE IF NOT EXISTS cluster_connections (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                   UUID           NOT NULL,
    name                        VARCHAR(255)   NOT NULL,        -- Human-readable cluster name
    description                 TEXT,
    api_endpoint                VARCHAR(512)   NOT NULL,        -- K8s API server URL
    kubeconfig_encrypted        TEXT,                           -- pgcrypto-encrypted kubeconfig YAML
    kubeconfig_encryption_key_id VARCHAR(128),                  -- KMS key identifier (external)
    has_valid_credentials       BOOLEAN        NOT NULL DEFAULT FALSE,
    connection_status           cluster_connection_status NOT NULL DEFAULT 'unknown',
    cloud_provider_id           UUID           REFERENCES cloud_providers(id) ON DELETE SET NULL,
    cluster_version             VARCHAR(32),                    -- e.g. 1.28.5-gke.xxxx
    region                      VARCHAR(128),                   -- e.g. us-central1, eu-west-1
    environment                 VARCHAR(32),                    -- e.g. production, staging, development
    is_active                   BOOLEAN        NOT NULL DEFAULT TRUE,
    last_connected_at           TIMESTAMPTZ,
    metadata                    JSONB          DEFAULT '{}',    -- Flexible provider-specific metadata
    created_at                  TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

-- Core indexes
CREATE INDEX IF NOT EXISTS idx_cluster_connections_tenant
    ON cluster_connections(tenant_id);
CREATE INDEX IF NOT EXISTS idx_cluster_connections_provider
    ON cluster_connections(cloud_provider_id);
CREATE INDEX IF NOT EXISTS idx_cluster_connections_status
    ON cluster_connections(connection_status) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_cluster_connections_env
    ON cluster_connections(environment);
CREATE INDEX IF NOT EXISTS idx_cluster_connections_created_at
    ON cluster_connections(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cluster_connections_metadata
    ON cluster_connections USING GIN (metadata);

CREATE TRIGGER update_cluster_connections_modtime
    BEFORE UPDATE ON cluster_connections
    FOR EACH ROW EXECUTE FUNCTION update_modified_column();

COMMENT ON TABLE  cluster_connections IS 'Core table for multi-cloud Kubernetes cluster connections.';
COMMENT ON COLUMN cluster_connections.tenant_id IS 'Multi-tenant isolation key.';
COMMENT ON COLUMN cluster_connections.api_endpoint IS 'Full URL of the Kubernetes API server.';
COMMENT ON COLUMN cluster_connections.kubeconfig_encrypted IS 'kubeconfig YAML encrypted using pgcrypto (pgp_sym_encrypt). NULL if using external auth provider.';
COMMENT ON COLUMN cluster_connections.kubeconfig_encryption_key_id IS 'Reference to the KMS key used for encryption (e.g., alias/rufkis-kubeconfig). Not stored in DB.';
COMMENT ON COLUMN cluster_connections.has_valid_credentials IS 'Set to TRUE after successful credential validation. Allows quick filtering without decrypting.';
COMMENT ON COLUMN cluster_connections.connection_status IS 'Current connectivity status, updated by health checks and connection operations.';
COMMENT ON COLUMN cluster_connections.metadata IS 'Flexible JSONB for provider-specific fields (e.g., GCP project, AWS account ID, Azure subscription).';

-- ============================================================
-- Table: cluster_tags (tagging)
-- ============================================================
CREATE TABLE IF NOT EXISTS cluster_tags (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id  UUID         NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    tag_key     VARCHAR(128) NOT NULL,
    tag_value   VARCHAR(256) NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE(cluster_id, tag_key)
);

CREATE INDEX IF NOT EXISTS idx_cluster_tags_cluster_id
    ON cluster_tags(cluster_id);
CREATE INDEX IF NOT EXISTS idx_cluster_tags_key_value
    ON cluster_tags(tag_key, tag_value);

COMMENT ON TABLE  cluster_tags IS 'Key/value tags for organizing and filtering clusters.';
COMMENT ON COLUMN cluster_tags.tag_key IS 'Tag key (e.g., team, cost-center, environment).';
COMMENT ON COLUMN cluster_tags.tag_value IS 'Tag value (e.g., platform-eng, cc-1234, staging).';

-- ============================================================
-- Table: cluster_groups (grouping)
-- ============================================================
CREATE TABLE IF NOT EXISTS cluster_groups (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID         NOT NULL,
    name        VARCHAR(255) NOT NULL,
    description TEXT,
    color       VARCHAR(7),                           -- Hex color for UI (e.g., #FF5733)
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE(tenant_id, name)
);

CREATE INDEX IF NOT EXISTS idx_cluster_groups_tenant
    ON cluster_groups(tenant_id);

CREATE TRIGGER update_cluster_groups_modtime
    BEFORE UPDATE ON cluster_groups
    FOR EACH ROW EXECUTE FUNCTION update_modified_column();

COMMENT ON TABLE cluster_groups IS 'Logical groupings of clusters (e.g., "Production Fleet", "Development Clusters").';

-- ============================================================
-- Table: cluster_group_members (many-to-many)
-- ============================================================
CREATE TABLE IF NOT EXISTS cluster_group_members (
    cluster_id UUID NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    group_id   UUID NOT NULL REFERENCES cluster_groups(id)     ON DELETE CASCADE,
    joined_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (cluster_id, group_id)
);

CREATE INDEX IF NOT EXISTS idx_cluster_group_members_group
    ON cluster_group_members(group_id);

COMMENT ON TABLE cluster_group_members IS 'Many-to-many relationship between clusters and groups.';

-- ============================================================
-- Table: cluster_health_history
-- ============================================================
CREATE TABLE IF NOT EXISTS cluster_health_history (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id      UUID              NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    connection_status cluster_connection_status NOT NULL,
    latency_ms      INTEGER,                              -- API server response time in ms
    error_message   TEXT,
    checked_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cluster_health_history_lookup
    ON cluster_health_history(cluster_id, checked_at DESC);
CREATE INDEX IF NOT EXISTS idx_cluster_health_history_checked_at
    ON cluster_health_history(checked_at);

COMMENT ON TABLE cluster_health_history IS 'Append-only time-series log of connectivity health checks.';
COMMENT ON COLUMN cluster_health_history.latency_ms IS 'API server response latency in milliseconds. NULL if unreachable.';
COMMENT ON COLUMN cluster_health_history.error_message IS 'Error detail if connection_status is "error" or "disconnected".';

-- ============================================================
-- Table: cluster_connection_audit_log
-- ============================================================
CREATE TABLE IF NOT EXISTS cluster_connection_audit_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id      UUID                  REFERENCES cluster_connections(id) ON DELETE SET NULL,
    tenant_id       UUID              NOT NULL,
    action          cluster_audit_action  NOT NULL,
    actor_id        UUID              NOT NULL,             -- User or service account who performed the action
    actor_type      VARCHAR(32)       NOT NULL DEFAULT 'user',  -- 'user', 'service_account', 'system'
    changes         JSONB             DEFAULT '{}',         -- Snapshot of changed fields
    ip_address      INET,
    occurred_at     TIMESTAMPTZ       NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_cluster_id
    ON cluster_connection_audit_log(cluster_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_tenant
    ON cluster_connection_audit_log(tenant_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_actor
    ON cluster_connection_audit_log(actor_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_timestamp
    ON cluster_connection_audit_log(occurred_at DESC);

COMMENT ON TABLE cluster_connection_audit_log IS 'Immutable audit trail for all cluster connection lifecycle events.';
COMMENT ON COLUMN cluster_connection_audit_log.action IS 'The type of operation performed.';
COMMENT ON COLUMN cluster_connection_audit_log.actor_id IS 'UUID of the user or service that performed the action.';
COMMENT ON COLUMN cluster_connection_audit_log.changes IS 'JSONB diff of before/after for tracking changes. NULL for simple actions.';
COMMENT ON COLUMN cluster_connection_audit_log.ip_address IS 'Source IP of the request.';

-- ============================================================
-- DOWN
-- ============================================================
-- DROP TABLE IF EXISTS cluster_connection_audit_log;
-- DROP TABLE IF EXISTS cluster_health_history;
-- DROP TABLE IF EXISTS cluster_group_members;
-- DROP TABLE IF EXISTS cluster_tags;
-- DROP TABLE IF EXISTS cluster_groups;
-- DROP TABLE IF EXISTS cluster_connections;
-- DROP TABLE IF EXISTS cloud_providers;
-- DROP TYPE IF EXISTS cluster_audit_action;
-- DROP TYPE IF EXISTS cluster_connection_status;
