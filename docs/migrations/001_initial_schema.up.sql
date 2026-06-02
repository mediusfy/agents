-- ============================================================
-- Rufkis - Initial Schema (Up Migration)
-- PostgreSQL 16-compatible
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. Trigger function for auto-updating updated_at
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $func$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$func$ LANGUAGE plpgsql;


-- ------------------------------------------------------------
-- 2. clusters
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clusters (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                    VARCHAR(255) NOT NULL,
    encrypted_kubeconfig    BYTEA NOT NULL,
    key_id                  VARCHAR(255) NOT NULL,
    kubeconfig_fingerprint  VARCHAR(64) NOT NULL,
    server_version          VARCHAR(64),
    status                  VARCHAR(32) NOT NULL DEFAULT 'unknown',
    status_changed_at       TIMESTAMPTZ,
    last_health_check_at    TIMESTAMPTZ,
    consecutive_failures    INTEGER NOT NULL DEFAULT 0,
    health_status           VARCHAR(32) NOT NULL DEFAULT 'unknown',
    metadata                JSONB NOT NULL DEFAULT '{}',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_clusters_name ON clusters(name);
CREATE UNIQUE INDEX IF NOT EXISTS uq_clusters_kubeconfig_fingerprint ON clusters(kubeconfig_fingerprint);

CREATE TRIGGER trg_clusters_updated_at
    BEFORE UPDATE ON clusters
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();


-- ------------------------------------------------------------
-- 3. outbox_events
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS outbox_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type      VARCHAR(255) NOT NULL,
    source          VARCHAR(255) NOT NULL,
    specversion     VARCHAR(8) NOT NULL DEFAULT '1.0',
    datacontenttype VARCHAR(64) NOT NULL DEFAULT 'application/json',
    subject         VARCHAR(255),
    payload         JSONB NOT NULL,
    dedup_key       VARCHAR(64),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at    TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_outbox_events_dedup_key
    ON outbox_events(dedup_key)
    WHERE dedup_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_outbox_events_published_at
    ON outbox_events(published_at);


-- ------------------------------------------------------------
-- 4. board_members
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS board_members (
    board_id    UUID NOT NULL,
    user_id     UUID NOT NULL,
    role        VARCHAR(16) NOT NULL CHECK (role IN ('viewer', 'editor', 'admin')),
    invited_by  UUID NOT NULL,
    invited_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (board_id, user_id)
);


-- ------------------------------------------------------------
-- 5. comments
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS comments (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource_type       VARCHAR(64) NOT NULL,
    resource_fingerprint VARCHAR(255) NOT NULL,
    board_id            UUID NOT NULL,
    author_id           UUID NOT NULL,
    body                TEXT NOT NULL,
    parent_comment_id   UUID,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_comments_parent
        FOREIGN KEY (parent_comment_id)
        REFERENCES comments(id)
        ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_comments_board_resource
    ON comments(board_id, resource_fingerprint);


-- ------------------------------------------------------------
-- 6. notifications
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notifications (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL,
    event_type          VARCHAR(255) NOT NULL,
    title               VARCHAR(255) NOT NULL,
    body                TEXT,
    board_id            UUID,
    resource_fingerprint VARCHAR(255),
    is_read             BOOLEAN NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user_unread
    ON notifications(user_id, is_read);


-- ------------------------------------------------------------
-- 7. audit_events
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID,
    action          VARCHAR(64) NOT NULL,
    resource_type   VARCHAR(64),
    resource_id     VARCHAR(255),
    cluster_id      UUID,
    board_id        UUID,
    details         JSONB,
    severity        VARCHAR(16) NOT NULL DEFAULT 'info'
                    CHECK (severity IN ('info', 'warning', 'high', 'critical')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_events_cluster_id ON audit_events(cluster_id);
CREATE INDEX IF NOT EXISTS idx_audit_events_created_at  ON audit_events(created_at);


COMMIT;
