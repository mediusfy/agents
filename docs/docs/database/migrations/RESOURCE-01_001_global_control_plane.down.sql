

-- ============================================================================
-- RESOURCE-01: Global Control Plane Schema — ROLLBACK
-- ============================================================================

BEGIN;

DROP TABLE IF EXISTS kubeconfig_secrets CASCADE;
DROP TABLE IF EXISTS rbac_rules CASCADE;
DROP TABLE IF EXISTS teams CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS clusters CASCADE;

DROP TYPE IF EXISTS secret_provider;
DROP TYPE IF EXISTS principal_type;
DROP TYPE IF EXISTS cluster_status;

COMMIT;
