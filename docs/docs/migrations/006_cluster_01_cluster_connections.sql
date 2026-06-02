

-- =============================================================================
-- Migration 006: CLUSTER-01 — Cluster Connection Management
-- Bounded Context: ClusterConnect
-- Description: Creates the foundational schema for registering and managing
--   multi-cloud Kubernetes cluster connections from a single SRE board.
-- =============================================================================

-- =============================================================================
-- UP
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Ensure extensions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ---------------------------------------------------------------------------
-- Auto-updated_at trigger function (idempotent)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE 'plpgsql';

-- ---------------------------------------------------------------------------
-- ENUM types
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE cluster_connection_status AS ENUM (
        'connected',
        'disconnected',
        'error',
        'unknown'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE cluster_credential_type AS ENUM (
        'kubeconfig',
        'service_account',
        'oidc',
        'aws_eks',
        'gcp_gke',
        'azure_aks'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE cluster_health_status AS ENUM (
        'healthy',
        'degraded',
        'unreachable',
        'unknown'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 1. cloud_providers — Reference table of supported cloud providers
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cloud_providers (
    id              SMALLSERIAL PRIMARY KEY,
    name            VARCHAR(32)  NOT NULL UNIQUE,
    display_name    VARCHAR(64)  NOT NULL,
    logo_url        TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- 2. cluster_connections — Aggregate root for cluster registration
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cluster_connections (
    id                  UUID                     PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_name        VARCHAR(128)             NOT NULL,
    display_name        VARCHAR(256),
    cloud_provider_id   SMALLINT                 NOT NULL REFERENCES cloud_providers(id),
    region              VARCHAR(64)              NOT NULL,
    api_server_endpoint TEXT                     NOT NULL,
    kubernetes_version  VARCHAR(32),
    connection_status   cluster_connection_status NOT NULL DEFAULT 'unknown',
    last_connected_at   TIMESTAMPTZ,
    notes               TEXT,
    metadata            JSONB                    DEFAULT '{}'::jsonb,
    created_by          UUID,        -- FK to users table (future bounded context)
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ, -- soft delete

    -- A cluster name must be unique per cloud provider
    CONSTRAINT uq_cluster_connections_provider_name UNIQUE (cloud_provider_id, cluster_name)
);

-- Full-text search support for cluster names/descriptions
CREATE INDEX IF NOT EXISTS idx_cluster_connections_name_trgm
    ON cluster_connections USING GIN (cluster_name gin_trgm_ops);

-- Provider + region composite index for admin filtering
CREATE INDEX IF NOT EXISTS idx_cluster_connections_provider_region
    ON cluster_connections (cloud_provider_id, region);

-- Active-only partial index for fast listing of non-deleted clusters
CREATE INDEX IF NOT EXISTS idx_cluster_connections_active
    ON cluster_connections (cloud_provider_id, region)
    WHERE deleted_at IS NULL;

-- Connection status index for monitoring dashboards
CREATE INDEX IF NOT EXISTS idx_cluster_connections_status
    ON cluster_connections (connection_status)
    WHERE deleted_at IS NULL;

-- Trigger for auto-updating updated_at
CREATE TRIGGER update_cluster_connections_modtime
    BEFORE UPDATE ON cluster_connections
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ---------------------------------------------------------------------------
-- 3. cluster_credentials — 1:1 encrypted credential storage
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cluster_credentials (
    id                      UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id              UUID                    NOT NULL UNIQUE REFERENCES cluster_connections(id) ON DELETE CASCADE,
    credential_type         cluster_credential_type NOT NULL,
    encrypted_kubeconfig    BYTEA,                   -- AES-256-GCM encrypted kubeconfig
    encryption_key_id       VARCHAR(128),            -- KMS key reference (e.g., 'projects/p/locations/global/keyRings/r/cryptoKeys/k')
    service_account_token   BYTEA,                   -- encrypted service account token (alternative to kubeconfig)
    certificate_authority   BYTEA,                   -- encrypted CA certificate data
    expires_at              TIMESTAMPTZ,
    last_rotated_at         TIMESTAMPTZ,
    rotated_by              UUID,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at              TIMESTAMPTZ              -- soft delete

    -- NOTE: credential validation (non-null of at least one auth method)
    -- is enforced at the application layer since BYTEA columns can't
    -- participate in CHECK constraints reliably across all PG versions.
);

-- Index for expiry monitoring
CREATE INDEX IF NOT EXISTS idx_cluster_credentials_expires_at
    ON cluster_credentials (expires_at)
    WHERE deleted_at IS NULL AND expires_at IS NOT NULL;

CREATE TRIGGER update_cluster_credentials_modtime
    BEFORE UPDATE ON cluster_credentials
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ---------------------------------------------------------------------------
-- 4. cluster_tags — Flexible key-value tagging for clusters
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cluster_tags (
    id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id  UUID         NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    key         VARCHAR(128) NOT NULL,
    value       VARCHAR(512) NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_cluster_tag UNIQUE (cluster_id, key)
);

-- GIN index for tag-based searches
CREATE INDEX IF NOT EXISTS idx_cluster_tags_key_value
    ON cluster_tags (key, value);

CREATE INDEX IF NOT EXISTS idx_cluster_tags_cluster
    ON cluster_tags (cluster_id);

-- ---------------------------------------------------------------------------
-- 5. cluster_groups — Logical groupings (e.g., production, staging, eu-west)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cluster_groups (
    id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(128) NOT NULL UNIQUE,
    description TEXT,
    color       VARCHAR(7),  -- hex color code for UI (e.g., '#FF5733')
    region      VARCHAR(64), -- optional region constraint for data residency
    created_by  UUID,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ  -- soft delete
);

CREATE INDEX IF NOT EXISTS idx_cluster_groups_name
    ON cluster_groups (name)
    WHERE deleted_at IS NULL;

CREATE TRIGGER update_cluster_groups_modtime
    BEFORE UPDATE ON cluster_groups
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ---------------------------------------------------------------------------
-- 6. cluster_group_members — M2M: clusters <-> groups
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cluster_group_members (
    cluster_id  UUID         NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    group_id    UUID         NOT NULL REFERENCES cluster_groups(id)      ON DELETE CASCADE,
    added_by    UUID,
    added_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    PRIMARY KEY (cluster_id, group_id)
);

CREATE INDEX IF NOT EXISTS idx_cluster_group_members_group
    ON cluster_group_members (group_id);

-- ---------------------------------------------------------------------------
-- 7. cluster_health_history — Time-series connectivity health records
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS cluster_health_history (
    id                UUID                  PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id        UUID                  NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    status            cluster_health_status NOT NULL,
    response_time_ms  INTEGER,              -- API response time in milliseconds
    error_message     TEXT,
    checked_at        TIMESTAMPTZ           NOT NULL DEFAULT NOW(),
    details           JSONB                 DEFAULT '{}'::jsonb
);

-- Partition by month using cluster_id + checked_at for efficient time-range queries
CREATE INDEX IF NOT EXISTS idx_cluster_health_history_lookup
    ON cluster_health_history (cluster_id, checked_at DESC);

CREATE INDEX IF NOT EXISTS idx_cluster_health_history_checked_at
    ON cluster_health_history (checked_at DESC);

-- ---------------------------------------------------------------------------
-- 8. connection_audit_log — Immutable audit trail
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS connection_audit_log (
    id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id        UUID         NOT NULL REFERENCES cluster_connections(id) ON DELETE CASCADE,
    event_type        VARCHAR(64)  NOT NULL,
    previous_status   VARCHAR(32),
    new_status        VARCHAR(32),
    performed_by      UUID,
    occurred_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    details           JSONB        DEFAULT '{}'::jsonb,
    ip_address        INET
);

CREATE INDEX IF NOT EXISTS idx_connection_audit_log_cluster
    ON connection_audit_log (cluster_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_connection_audit_log_event_type
    ON connection_audit_log (event_type, occurred_at DESC);

-- ---------------------------------------------------------------------------
-- Seed cloud_providers reference data
-- ---------------------------------------------------------------------------
INSERT INTO cloud_providers (name, display_name, logo_url) VALUES
    ('AWS',       'Amazon Web Services',  NULL),
    ('GCP',       'Google Cloud Platform', NULL),
    ('Azure',     'Microsoft Azure',      NULL),
    ('On-Prem',   'On-Premises / Self-Managed', NULL),
    ('Other',     'Other Provider',       NULL)
ON CONFLICT (name) DO NOTHING;

COMMIT;

-- =============================================================================
-- DOWN
-- =============================================================================

BEGIN;

DROP TABLE IF EXISTS connection_audit_log       CASCADE;
DROP TABLE IF EXISTS cluster_health_history      CASCADE;
DROP TABLE IF EXISTS cluster_group_members       CASCADE;
DROP TABLE IF EXISTS cluster_groups              CASCADE;
DROP TABLE IF EXISTS cluster_tags                CASCADE;
DROP TABLE IF EXISTS cluster_credentials         CASCADE;
DROP TABLE IF EXISTS cluster_connections         CASCADE;
DROP TABLE IF EXISTS cloud_providers             CASCADE;

DROP TYPE IF EXISTS cluster_health_status;
DROP TYPE IF EXISTS cluster_credential_type;
DROP TYPE IF EXISTS cluster_connection_status;

COMMIT;
