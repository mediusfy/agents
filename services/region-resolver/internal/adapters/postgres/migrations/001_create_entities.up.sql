CREATE TABLE IF NOT EXISTS entities (
    id                TEXT PRIMARY KEY,
    name              TEXT NOT NULL,
    region            TEXT NOT NULL,
    data_residency_zone TEXT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'active',
    version           INTEGER NOT NULL DEFAULT 1,
    labels            JSONB DEFAULT '{}',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_entities_region ON entities(region);
CREATE INDEX IF NOT EXISTS idx_entities_zone ON entities(data_residency_zone);
