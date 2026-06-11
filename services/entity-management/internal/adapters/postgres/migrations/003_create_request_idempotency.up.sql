CREATE TABLE IF NOT EXISTS request_idempotency_keys (
    request_key TEXT PRIMARY KEY,
    entity_id   TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at  TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '7 days'
);
CREATE INDEX IF NOT EXISTS idx_request_idempotency_expires
    ON request_idempotency_keys(expires_at);
