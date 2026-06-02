-- ============================================================
-- Rufkis - Initial Schema (Down Migration)
-- Order respects FK dependencies.
-- ============================================================

BEGIN;

DROP INDEX IF EXISTS idx_audit_events_created_at;
DROP INDEX IF EXISTS idx_audit_events_cluster_id;
DROP INDEX IF EXISTS idx_notifications_user_unread;
DROP INDEX IF EXISTS idx_comments_board_resource;
DROP INDEX IF EXISTS idx_outbox_events_published_at;
DROP INDEX IF EXISTS uq_outbox_events_dedup_key;
DROP INDEX IF EXISTS uq_clusters_kubeconfig_fingerprint;
DROP INDEX IF EXISTS uq_clusters_name;

DROP TABLE IF EXISTS audit_events;
DROP TABLE IF EXISTS notifications;
DROP TABLE IF EXISTS comments;
DROP TABLE IF EXISTS board_members;
DROP TABLE IF EXISTS outbox_events;
DROP TABLE IF EXISTS clusters;

DROP TRIGGER IF EXISTS trg_clusters_updated_at ON clusters;
DROP FUNCTION IF EXISTS update_modified_column();

COMMIT;
