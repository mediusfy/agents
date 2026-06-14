CREATE TABLE IF NOT EXISTS entities (
    id                 TEXT PRIMARY KEY,
    schema_id          TEXT NOT NULL REFERENCES entity_schemas(id),
    name               TEXT NOT NULL,
    type               TEXT NOT NULL DEFAULT '',
    region             TEXT NOT NULL DEFAULT '',
    data_residency_zone TEXT NOT NULL DEFAULT '',
    status             TEXT NOT NULL DEFAULT 'active',
    version            INTEGER NOT NULL DEFAULT 1,
    attributes         JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata           JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at         TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_entities_schema_id ON entities(schema_id);
CREATE INDEX IF NOT EXISTS idx_entities_status ON entities(status);
CREATE INDEX IF NOT EXISTS idx_entities_region ON entities(region);
CREATE INDEX IF NOT EXISTS idx_entities_deleted_at ON entities(deleted_at);
CREATE INDEX IF NOT EXISTS idx_entities_schema_created_id
    ON entities(schema_id, created_at DESC, id DESC);
