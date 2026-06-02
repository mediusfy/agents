

-- ============================================================================
-- BOARD-02: Customizable Board Column Configuration
-- Service: board-service (Rufkis Multi-Region K8s Console)
-- 
-- Tables:
--   1. boards                     — Core board entity
--   2. board_columns              — Column configs within a board
--   3. board_cards                — Materialised cards in columns
--   4. board_templates            — Reusable board templates
--   5. board_managed_resources    — Materialised resource cache (R6)
--   6. audit_wal                  — Partitioned WAL-style audit log (R5)
--   7. region_cluster_mapping     — Multi-region cluster tracking
--
-- Design decisions:
--   - UUIDv7 PKs for temporal ordering (surrogate, cluster-safe)
--   - GIN indexes on JSONB columns for filter_expression / filter_criteria
--   - Composite indexes optimised for board-loading query paths
--   - audit_wal is LIST-partitioned by region for data-plane isolation
--   - Chain-link columns (chain_link_id, chain_prev_id) allow background
--     worker to link audit events without blocking writes
--   - version column on boards for optimistic concurrency control
--   - All timestamps are TIMESTAMPTZ; updated_at auto-managed by trigger
-- ============================================================================

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 0. UUIDv7 support
--    PostgreSQL ≥17 ships gen_uuid_v7() built-in.  For PG13–16 we define a
--    PL/pgSQL shim that produces the same temporal sort order.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.gen_uuid_v7()
RETURNS uuid
IMMUTABLE LEAKPROOF
LANGUAGE plpgsql AS $$
DECLARE
  -- UNIX timestamp in milliseconds (48 bits)
  ms      BIGINT := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT;
  -- Random bits (74 bits)
  rand_a  INT    := (random() * 2147483647)::INT;      -- 31 bits
  rand_b  BIGINT := (random() * 9223372036854775807)::BIGINT; -- 63 bits
  ts_hex  TEXT   := lpad(to_hex(ms), 12, '0');
  ver_hex TEXT   := '7';                                 -- version 7
  var_hex TEXT   := '8';                                 -- variant RFC 4122
  a_hex   TEXT   := lpad(to_hex(rand_a), 8, '0');
  b_hex   TEXT   := lpad(to_hex(rand_b), 16, '0');
BEGIN
  -- uuid: tttttttt-tttt-7aaa-8bbb-bbbbbbbbbbbb
  RETURN (ts_hex || '-' ||
          substr(ts_hex, 5, 4) || '-' ||
          ver_hex || substr(a_hex, 2, 3) || '-' ||
          var_hex || substr(b_hex, 2, 3) || '-' ||
          substr(b_hex, 5, 12)
         )::uuid;
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 0b. Common trigger function for updated_at
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_modified_column()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. boards – core board entity
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.boards (
    id              UUID        NOT NULL DEFAULT public.gen_uuid_v7(),
    name            TEXT        NOT NULL,
    description     TEXT,
    owner_team      TEXT        NOT NULL,
    region          TEXT        NOT NULL,          -- global control-plane or per-region data-plane
    filter_criteria JSONB       NOT NULL DEFAULT '{}'::jsonb,  -- top-level resource filter
    version         BIGINT      NOT NULL DEFAULT 1,            -- optimistic locking
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_boards PRIMARY KEY (id)
);

-- Optimistic-locking lookup: load board + version
CREATE INDEX IF NOT EXISTS idx_boards_region        ON public.boards (region);
CREATE INDEX IF NOT EXISTS idx_boards_owner_team    ON public.boards (owner_team);
-- GIN for JSONB filter queries
CREATE INDEX IF NOT EXISTS idx_boards_filter_criteria ON public.boards USING GIN (filter_criteria jsonb_path_ops);

CREATE TRIGGER trg_boards_updated_at
    BEFORE UPDATE ON public.boards
    FOR EACH ROW
    EXECUTE FUNCTION public.update_modified_column();

COMMENT ON TABLE  public.boards                  IS 'Core board entity (Rufkis K8s console). Each board belongs to a single region.';
COMMENT ON COLUMN public.boards.version           IS 'Optimistic-lock counter incremented on every write.';
COMMENT ON COLUMN public.boards.filter_criteria   IS 'Top-level JSONB filter applied across all columns (e.g. cluster=*, namespace=monitoring).';
COMMENT ON COLUMN public.boards.region            IS 'Region hint: "global" for control-plane boards, else the per-region data-plane identifier.';

-- ────────────────────────────────────────────────────────────────────────────
-- 2. board_columns – column configuration within a board
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.board_columns (
    id                UUID        NOT NULL DEFAULT public.gen_uuid_v7(),
    board_id          UUID        NOT NULL,
    name              TEXT        NOT NULL,
    position          INT         NOT NULL,                     -- ordinal within board (0-based)
    width_px          INT         NOT NULL DEFAULT 320,
    color_hex         TEXT        NOT NULL DEFAULT '#E2E8F0',   -- tailwind gray-200
    card_limit        INT         NULL,                         -- NULL = unlimited
    filter_expression JSONB       NOT NULL DEFAULT '{}'::jsonb, -- per-column resource filter
    sort_order        JSONB       NOT NULL DEFAULT '[]'::jsonb, -- e.g. [{"field":"name","dir":"asc"}]
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_board_columns PRIMARY KEY (id),
    CONSTRAINT fk_board_columns_board FOREIGN KEY (board_id)
        REFERENCES public.boards (id) ON DELETE CASCADE
);

-- Composite index: load all columns for a board in position order (most frequent query)
CREATE INDEX IF NOT EXISTS idx_board_columns_board_position
    ON public.board_columns (board_id, position);

-- GIN for filter_expression resource matching
CREATE INDEX IF NOT EXISTS idx_board_columns_filter_expr
    ON public.board_columns USING GIN (filter_expression jsonb_path_ops);

-- GIN for sort_order (queries may introspect sort config)
CREATE INDEX IF NOT EXISTS idx_board_columns_sort_order
    ON public.board_columns USING GIN (sort_order);

CREATE TRIGGER trg_board_columns_updated_at
    BEFORE UPDATE ON public.board_columns
    FOR EACH ROW
    EXECUTE FUNCTION public.update_modified_column();

COMMENT ON TABLE  public.board_columns                   IS 'Column definitions within a board. Cards appear in columns based on filter_expression.';
COMMENT ON COLUMN public.board_columns.filter_expression  IS 'JSONB predicate that decides which resources materialise into this column.';
COMMENT ON COLUMN public.board_columns.sort_order         IS 'JSONB array of sort directives: [{"field":"name","dir":"asc"}, …]';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. board_cards – materialised cards in columns (per R9: local board state)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.board_cards (
    id                UUID        NOT NULL DEFAULT public.gen_uuid_v7(),
    board_id          UUID        NOT NULL,
    column_id         UUID        NOT NULL,
    resource_id       UUID        NOT NULL,           -- UUID of the backing K8s resource
    resource_gvk      TEXT        NOT NULL,           -- e.g. "apps/v1/Deployment"
    resource_name     TEXT        NOT NULL,
    resource_namespace TEXT       NOT NULL DEFAULT '',
    cluster_id        TEXT        NOT NULL,           -- cluster that owns this resource
    card_title        TEXT        NOT NULL,
    card_metadata     JSONB       NOT NULL DEFAULT '{}'::jsonb,
    position          INT         NOT NULL,           -- ordinal within column
    moved_by          TEXT        NULL,               -- actor who last moved the card
    moved_at          TIMESTAMPTZ NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_board_cards PRIMARY KEY (id),
    CONSTRAINT fk_board_cards_board  FOREIGN KEY (board_id)  REFERENCES public.boards (id) ON DELETE CASCADE,
    CONSTRAINT fk_board_cards_column FOREIGN KEY (column_id) REFERENCES public.board_columns (id) ON DELETE CASCADE,
    -- One resource can appear in a board only once (but could move between columns)
    CONSTRAINT uq_board_cards_resource UNIQUE (board_id, resource_id)
);

-- Primary query: load all cards for a board, ordered by column+position
CREATE INDEX IF NOT EXISTS idx_board_cards_board_column_pos
    ON public.board_cards (board_id, column_id, position);

-- Lookup cards by resource for move / delete operations
CREATE INDEX IF NOT EXISTS idx_board_cards_resource
    ON public.board_cards (board_id, resource_id);

-- GIN for card_metadata filtering / search
CREATE INDEX IF NOT EXISTS idx_board_cards_metadata
    ON public.board_cards USING GIN (card_metadata jsonb_path_ops);

CREATE TRIGGER trg_board_cards_updated_at
    BEFORE UPDATE ON public.board_cards
    FOR EACH ROW
    EXECUTE FUNCTION public.update_modified_column();

COMMENT ON TABLE  public.board_cards IS 'Materialised card (resource representation) inside a board column. Local board state only (R9).';

-- ────────────────────────────────────────────────────────────────────────────
-- 4. board_templates – reusable board templates
-- ────────────────────────────────────────────────────────────────────────────
CREATE TYPE public.template_scope AS ENUM ('team', 'org');

CREATE TABLE IF NOT EXISTS public.board_templates (
    id                 UUID            NOT NULL DEFAULT public.gen_uuid_v7(),
    name               TEXT            NOT NULL,
    description        TEXT,
    columns_definition JSONB           NOT NULL,   -- full column configuration array
    created_by         TEXT            NOT NULL,   -- actor identity
    scope              template_scope  NOT NULL DEFAULT 'team',
    created_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_board_templates PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_board_templates_scope ON public.board_templates (scope, name);

COMMENT ON TABLE  public.board_templates                 IS 'Reusable board templates for quick board creation.';
COMMENT ON COLUMN public.board_templates.columns_definition IS 'JSONB array of column configs: [{name, width_px, color_hex, filter_expression, sort_order}, …]';

-- ────────────────────────────────────────────────────────────────────────────
-- 5. board_managed_resources – materialised resource cache (R6)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.board_managed_resources (
    id                  UUID        NOT NULL DEFAULT public.gen_uuid_v7(),
    board_id            UUID        NOT NULL,
    resource_id         UUID        NOT NULL,           -- K8s resource UID
    cluster_id          TEXT        NOT NULL,
    gvk                 TEXT        NOT NULL,           -- group/version/kind
    name                TEXT        NOT NULL,
    namespace           TEXT        NOT NULL DEFAULT '',
    labels              JSONB       NOT NULL DEFAULT '{}'::jsonb,
    annotations         JSONB       NOT NULL DEFAULT '{}'::jsonb,
    status              JSONB       NOT NULL DEFAULT '{}'::jsonb,  -- observed status sub-resource
    observed_generation BIGINT      NOT NULL DEFAULT 0,
    last_synced_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_board_managed_resources PRIMARY KEY (id),
    CONSTRAINT fk_bmr_board FOREIGN KEY (board_id) REFERENCES public.boards (id) ON DELETE CASCADE,
    CONSTRAINT uq_bmr_resource UNIQUE (board_id, cluster_id, resource_id)
);

-- Primary query: load all cached resources for a board (used by reconciliation loop)
CREATE INDEX IF NOT EXISTS idx_bmr_board ON public.board_managed_resources (board_id);

-- Lookup by GVK + namespace for filter matching
CREATE INDEX IF NOT EXISTS idx_bmr_gvk_ns ON public.board_managed_resources (board_id, gvk, namespace);

-- GIN for label-based filtering
CREATE INDEX IF NOT EXISTS idx_bmr_labels ON public.board_managed_resources USING GIN (labels jsonb_path_ops);

-- GIN for status queries (e.g. status.phase = 'Running')
CREATE INDEX IF NOT EXISTS idx_bmr_status ON public.board_managed_resources USING GIN (status jsonb_path_ops);

-- Composite: find stale entries for re-sync
CREATE INDEX IF NOT EXISTS idx_bmr_stale ON public.board_managed_resources (board_id, last_synced_at)
    WHERE observed_generation > 0;

COMMENT ON TABLE  public.board_managed_resources IS 'Materialised cache of K8s resources visible to a board. Synchronised asynchronously via Kafka events (R6).';
COMMENT ON COLUMN public.board_managed_resources.observed_generation IS 'K8s resource.metadata.generation at last sync.';

-- ────────────────────────────────────────────────────────────────────────────
-- 6. audit_wal – WAL-style audit log (R5), partitioned by region
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.audit_wal (
    id              BIGSERIAL       NOT NULL,
    event_id        UUID            NOT NULL DEFAULT gen_random_uuid(),
    event_type      TEXT            NOT NULL,           -- e.g. "board.created", "card.moved"
    aggregate_type  TEXT            NOT NULL,           -- e.g. "board", "board_card"
    aggregate_id    UUID            NOT NULL,
    actor_id        TEXT            NOT NULL,           -- user or service account
    region          TEXT            NOT NULL,           -- partition key
    payload         JSONB           NOT NULL DEFAULT '{}'::jsonb,
    occurred_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    chain_link_id   UUID            NULL,               -- set by background worker
    chain_prev_id   UUID            NULL,               -- set by background worker

    CONSTRAINT pk_audit_wal PRIMARY KEY (region, id)
) PARTITION BY LIST (region);

-- NOTE: Partitions are created dynamically.  Minimal starter partitions:
CREATE TABLE IF NOT EXISTS public.audit_wal_global PARTITION OF public.audit_wal
    FOR VALUES IN ('global')
    PARTITION BY LIST ('global');   -- dummy, the value matches

-- Default partition for any unregistered region
CREATE TABLE IF NOT EXISTS public.audit_wal_default PARTITION OF public.audit_wal
    DEFAULT;

-- Per-region partitions should be created by the provisioning pipeline:
--   CREATE TABLE IF NOT EXISTS audit_wal_us_east_1 PARTITION OF audit_wal
--       FOR VALUES IN ('us-east-1');

-- Indexes on the parent (PG propagates to partitions in PG12+)
CREATE INDEX IF NOT EXISTS idx_audit_wal_event_type     ON public.audit_wal (event_type);
CREATE INDEX IF NOT EXISTS idx_audit_wal_aggregate      ON public.audit_wal (aggregate_type, aggregate_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_wal_actor          ON public.audit_wal (actor_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_wal_occurred_at    ON public.audit_wal (occurred_at DESC);

-- GIN for payload introspection (ad-hoc queries / forensics)
CREATE INDEX IF NOT EXISTS idx_audit_wal_payload        ON public.audit_wal USING GIN (payload jsonb_path_ops);

-- Partial index: find unlinked events for the background chain-link worker
CREATE INDEX IF NOT EXISTS idx_audit_wal_unlinked       ON public.audit_wal (occurred_at)
    WHERE chain_link_id IS NULL;

COMMENT ON TABLE  public.audit_wal IS 'Append-only WAL-style audit log partitioned by region. Chain links computed asynchronously by background worker (every 1 s / 1000 entries).';

-- ────────────────────────────────────────────────────────────────────────────
-- 7. region_cluster_mapping – multi-region cluster tracking
-- ────────────────────────────────────────────────────────────────────────────
CREATE TYPE public.cluster_status AS ENUM ('active', 'inactive', 'degraded', 'offline');

CREATE TABLE IF NOT EXISTS public.region_cluster_mapping (
    region          TEXT            NOT NULL,
    cluster_id      TEXT            NOT NULL,
    cluster_name    TEXT            NOT NULL,
    status          cluster_status  NOT NULL DEFAULT 'active',
    last_heartbeat  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_region_cluster_mapping PRIMARY KEY (region, cluster_id)
);

CREATE INDEX IF NOT EXISTS idx_rcm_region_status ON public.region_cluster_mapping (region, status);
CREATE INDEX IF NOT EXISTS idx_rcm_heartbeat     ON public.region_cluster_mapping (last_heartbeat);

COMMENT ON TABLE  public.region_cluster_mapping IS 'Tracks which clusters belong to which region and their health status. Updated by heartbeats from per-region data-plane agents.';

-- ────────────────────────────────────────────────────────────────────────────
-- 8. (Optional) Background-worker helper: get unlinked audit events
--    This query is used by the chain-link maintenance worker.
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.audit_wal_link_chain(batch_size INT DEFAULT 1000)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    updated_count INT := 0;
    prev_record   RECORD;
    cur_record    RECORD;
BEGIN
    FOR cur_record IN
        SELECT a.id, a.event_id, a.occurred_at, a.region
          FROM public.audit_wal a
         WHERE a.chain_link_id IS NULL
         ORDER BY a.region, a.occurred_at, a.id
         LIMIT batch_size
         FOR UPDATE SKIP LOCKED
    LOOP
        -- Find the previous linked event in the same region for chain
        SELECT a.chain_link_id INTO prev_record
          FROM public.audit_wal a
         WHERE a.region = cur_record.region
           AND a.chain_link_id IS NOT NULL
         ORDER BY a.occurred_at DESC, a.id DESC
         LIMIT 1;

        UPDATE public.audit_wal
           SET chain_link_id = public.gen_uuid_v7(),
               chain_prev_id = prev_record.chain_link_id
         WHERE id = cur_record.id
           AND region = cur_record.region;

        updated_count := updated_count + 1;
    END LOOP;

    RETURN updated_count;
END;
$$;

COMMENT ON FUNCTION public.audit_wal_link_chain IS 'Background-worker helper that assigns chain links to unlinked audit events. Idempotent – safe to run concurrently.';

COMMIT;
