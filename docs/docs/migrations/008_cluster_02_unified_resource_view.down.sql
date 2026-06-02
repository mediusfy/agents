-- Migration: 008_cluster_02_unified_resource_view.down.sql
-- Description: Rollback CLUSTER-02: Unified Cross-Cluster Resource View

DROP TRIGGER IF EXISTS trg_refresh_matviews_on_resource_change ON cluster_resources;
DROP FUNCTION IF EXISTS trigger_refresh_resource_matviews();
DROP FUNCTION IF EXISTS refresh_cluster_resource_matviews();
DROP FUNCTION IF EXISTS search_resources_by_label(TEXT, TEXT, TEXT, TEXT[]);
DROP FUNCTION IF EXISTS log_resource_change();

DROP MATERIALIZED VIEW IF EXISTS cluster_namespace_summary;
DROP MATERIALIZED VIEW IF EXISTS cross_cluster_resource_summary;

DROP TABLE IF EXISTS saved_resource_views CASCADE;
DROP TABLE IF EXISTS cluster_resource_snapshots CASCADE;
DROP TABLE IF EXISTS cluster_resource_metrics CASCADE;
DROP TABLE IF EXISTS cluster_resource_owners CASCADE;
DROP TABLE IF EXISTS cluster_resource_conditions CASCADE;
DROP TABLE IF EXISTS cluster_resource_labels CASCADE;
DROP TABLE IF EXISTS cluster_resources CASCADE;
DROP TABLE IF EXISTS cluster_namespaces CASCADE;
DROP TABLE IF EXISTS cluster_resource_types CASCADE;
DROP TABLE IF EXISTS cluster_resource_categories CASCADE;

DROP TYPE IF EXISTS view_visibility;
DROP TYPE IF EXISTS resource_phase;
DROP TYPE IF EXISTS resource_sync_status;
DROP TYPE IF EXISTS cluster_resource_health;
