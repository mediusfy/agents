

-- ============================================================================
-- RESOURCE-01: Global Control Plane Schema
-- Description: Multi-region K8s Resource Manager — Global Registry
-- Region: Global (single deployment)
-- ============================================================================
-- This migration creates the global control plane tables that manage cluster
-- registrations, user/team registries, RBAC rules, and kubeconfig secret
-- references to Vault/Secret Manager.
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
    CREATE TYPE cluster_status AS ENUM (
        'pending', 'active', 'degraded', 'offline', 'removed'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE principal_type AS ENUM ('user', 'team');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE secret_provider AS ENUM (
        'vault', 'aws-secrets-manager', 'gcp-secret-manager', 'azure-keyvault'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- --------------------------------------------------------------------------
-- 3. clusters — K8s cluster registry
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clusters (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(253) NOT NULL,
    region          VARCHAR(20)  NOT NULL CHECK (region IN ('us', 'eu', 'ap')),
    api_server_url  TEXT         NOT NULL,
    kubeconfig_ref  VARCHAR(255),          -- pointer to Vault secret path
    status          cluster_status NOT NULL DEFAULT 'pending',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    -- K8s cluster names must be DNS-1123 labels
    CONSTRAINT uq_clusters_name UNIQUE (name),
    CONSTRAINT chk_clusters_api_server_url CHECK (
        api_server_url ~ '^https?://'
    )
);

CREATE INDEX IF NOT EXISTS idx_clusters_region     ON clusters(region);
CREATE INDEX IF NOT EXISTS idx_clusters_status     ON clusters(status);
CREATE INDEX IF NOT EXISTS idx_clusters_name_trgm  ON clusters USING gin (name gin_trgm_ops);

CREATE TRIGGER trg_clusters_updated_at
    BEFORE UPDATE ON clusters
    FOR EACH ROW EXECUTE FUNCTION update_modified_column();

COMMENT ON TABLE  clusters IS 'Global K8s cluster registry — one row per managed cluster';
COMMENT ON COLUMN clusters.kubeconfig_ref IS 'Reference path in Vault/Secret Manager; never store raw kubeconfig in DB';

-- --------------------------------------------------------------------------
-- 4. users — User registry
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    email       VARCHAR(320) NOT NULL,
    name        VARCHAR(255) NOT NULL,
    teams       UUID[]       NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_users_email UNIQUE (email),
    CONSTRAINT chk_users_email CHECK (
        email ~ '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
    )
);

CREATE INDEX IF NOT EXISTS idx_users_email_lower ON users (LOWER(email));
CREATE INDEX IF NOT EXISTS idx_users_teams_gin   ON users USING gin (teams);

COMMENT ON TABLE  users IS 'Global user registry';
COMMENT ON COLUMN users.teams IS 'Array of team UUIDs the user belongs to';

-- --------------------------------------------------------------------------
-- 5. teams — Team registry
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS teams (
    id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(255) NOT NULL,
    members     UUID[]       NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_teams_name UNIQUE (name)
);

CREATE INDEX IF NOT EXISTS idx_teams_members_gin ON teams USING gin (members);

COMMENT ON TABLE  teams IS 'Global team registry';
COMMENT ON COLUMN teams.members IS 'Array of user UUIDs belonging to this team';

-- --------------------------------------------------------------------------
-- 6. rbac_rules — Per-cluster RBAC rules for users and teams
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rbac_rules (
    id              UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id      UUID           NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
    principal_type  principal_type NOT NULL,
    principal_id    UUID           NOT NULL,  -- user UUID or team UUID
    verb            VARCHAR(20)    NOT NULL,
    resource        VARCHAR(255)   NOT NULL,
    namespace       VARCHAR(253),            -- NULL = all namespaces
    created_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_rbac_verb CHECK (
        verb IN ('get', 'list', 'create', 'update', 'delete', 'watch', 'patch', '*')
    ),
    CONSTRAINT chk_rbac_resource CHECK (
        resource ~ '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(\/[a-z0-9]+)*$|^\*$'
    )
);

-- Common query patterns:
CREATE INDEX IF NOT EXISTS idx_rbac_cluster       ON rbac_rules(cluster_id);
CREATE INDEX IF NOT EXISTS idx_rbac_principal     ON rbac_rules(principal_type, principal_id);
CREATE INDEX IF NOT EXISTS idx_rbac_lookup        ON rbac_rules(cluster_id, principal_type, principal_id, verb, resource);
-- Partial index: only non-null namespaces for namespace-scoped queries
CREATE INDEX IF NOT EXISTS idx_rbac_namespace_scope
    ON rbac_rules(cluster_id, principal_type, principal_id, namespace)
    WHERE namespace IS NOT NULL;

COMMENT ON TABLE  rbac_rules IS 'RBAC rules per cluster per team/user — evaluated at API gateway';
COMMENT ON COLUMN rbac_rules.principal_id IS 'UUID of the user or team (resolved by principal_type)';
COMMENT ON COLUMN rbac_rules.verb IS 'K8s verb: get, list, create, update, delete, watch, patch, or *';

-- --------------------------------------------------------------------------
-- 7. kubeconfig_secrets — Vault/Secret Manager reference pointers
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS kubeconfig_secrets (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_id      UUID            NOT NULL UNIQUE REFERENCES clusters(id) ON DELETE CASCADE,
    provider        secret_provider NOT NULL,
    secret_path     TEXT            NOT NULL,
    version         INT             NOT NULL DEFAULT 1,
    rotated_at      TIMESTAMPTZ,

    CONSTRAINT chk_kubeconfig_secret_path CHECK (length(secret_path) > 0)
);

CREATE INDEX IF NOT EXISTS idx_kubeconfig_secrets_provider ON kubeconfig_secrets(provider);

COMMENT ON TABLE  kubeconfig_secrets IS 'References only — actual kubeconfigs stored in Vault/Secret Manager';
COMMENT ON COLUMN kubeconfig_secrets.secret_path IS 'Full path in the secret store (e.g., secret/data/k8s/us-prod/kubeconfig)';
COMMENT ON COLUMN kubeconfig_secrets.version IS 'Version of the secret in the external store';
COMMENT ON COLUMN kubeconfig_secrets.rotated_at IS 'Timestamp of last rotation';

-- --------------------------------------------------------------------------
-- 8. Row-Level Security for multi-tenant isolation (global plane)
-- --------------------------------------------------------------------------
ALTER TABLE clusters          ENABLE ROW LEVEL SECURITY;
ALTER TABLE users             ENABLE ROW LEVEL SECURITY;
ALTER TABLE teams             ENABLE ROW LEVEL SECURITY;
ALTER TABLE rbac_rules        ENABLE ROW LEVEL SECURITY;
ALTER TABLE kubeconfig_secrets ENABLE ROW LEVEL SECURITY;

-- Policy: cluster-admins see all; team members see their clusters via RBAC
CREATE POLICY p_clusters_tenant_isolation ON clusters
    USING (
        EXISTS (
            SELECT 1 FROM rbac_rules
            WHERE rbac_rules.cluster_id = clusters.id
              AND (
                  (rbac_rules.principal_type = 'user' AND rbac_rules.principal_id = current_setting('app.current_user_id')::UUID)
                  OR
                  (rbac_rules.principal_type = 'team' AND rbac_rules.principal_id = ANY(
                      SELECT unnest(teams) FROM users WHERE users.id = current_setting('app.current_user_id')::UUID
                  ))
              )
        )
        OR current_setting('app.current_role') = 'cluster-admin'
    );

CREATE POLICY p_rbac_rules_tenant_isolation ON rbac_rules
    USING (
        rbac_rules.principal_type = 'user' AND rbac_rules.principal_id = current_setting('app.current_user_id')::UUID
        OR rbac_rules.principal_type = 'team' AND rbac_rules.principal_id = ANY(
            SELECT unnest(teams) FROM users WHERE users.id = current_setting('app.current_user_id')::UUID
        )
        OR current_setting('app.current_role') = 'cluster-admin'
    );

CREATE POLICY p_kubeconfig_secrets_admin_only ON kubeconfig_secrets
    USING (current_setting('app.current_role') = 'cluster-admin');

COMMIT;
