

-- ============================================================================
-- BOARD-02 Down Migration
-- ============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.audit_wal_link_chain;
DROP TABLE IF EXISTS public.region_cluster_mapping;
DROP TYPE IF EXISTS public.cluster_status;

-- Drop partitions first, then parent
DROP TABLE IF EXISTS public.audit_wal_global;
DROP TABLE IF EXISTS public.audit_wal_default;
DROP TABLE IF EXISTS public.audit_wal CASCADE;

DROP TABLE IF EXISTS public.board_managed_resources CASCADE;
DROP TABLE IF EXISTS public.board_templates CASCADE;
DROP TYPE IF EXISTS public.template_scope;
DROP TABLE IF EXISTS public.board_cards CASCADE;
DROP TABLE IF EXISTS public.board_columns CASCADE;
DROP TABLE IF EXISTS public.boards CASCADE;

DROP FUNCTION IF EXISTS public.update_modified_column;
DROP FUNCTION IF EXISTS public.gen_uuid_v7;

COMMIT;
