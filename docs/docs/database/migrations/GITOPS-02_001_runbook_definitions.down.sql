-- Migration: GITOPS-02_001_runbook_definitions.down.sql
-- Rollback for runbook definitions schema

-- Drop triggers
DROP TRIGGER IF EXISTS trg_runbook_definitions_auto_register ON gitops.runbook_definitions;
DROP TRIGGER IF EXISTS trg_runbook_versions_update_current ON gitops.runbook_versions;
DROP TRIGGER IF EXISTS trg_runbook_registry_search_vector ON gitops.runbook_registry;

DROP TRIGGER IF EXISTS trg_runbook_definitions_updated_at ON gitops.runbook_definitions;
DROP TRIGGER IF EXISTS trg_runbook_versions_updated_at ON gitops.runbook_versions;
DROP TRIGGER IF EXISTS trg_runbook_triggers_updated_at ON gitops.runbook_triggers;
DROP TRIGGER IF EXISTS trg_runbook_steps_updated_at ON gitops.runbook_steps;
DROP TRIGGER IF EXISTS trg_runbook_rollback_commands_updated_at ON gitops.runbook_rollback_commands;
DROP TRIGGER IF EXISTS trg_runbook_approval_requirements_updated_at ON gitops.runbook_approval_requirements;
DROP TRIGGER IF EXISTS trg_runbook_registry_updated_at ON gitops.runbook_registry;

-- Drop functions
DROP FUNCTION IF EXISTS gitops.auto_register_runbook();
DROP FUNCTION IF EXISTS gitops.update_current_version();
DROP FUNCTION IF EXISTS gitops.update_registry_search_vector();
DROP FUNCTION IF EXISTS gitops.update_modified_column();

-- Drop tables (order respects foreign keys)
DROP TABLE IF EXISTS gitops.runbook_commits CASCADE;
DROP TABLE IF EXISTS gitops.runbook_validation_results CASCADE;
DROP TABLE IF EXISTS gitops.runbook_registry CASCADE;
DROP TABLE IF EXISTS gitops.runbook_rollback_commands CASCADE;
DROP TABLE IF EXISTS gitops.runbook_approval_requirements CASCADE;
DROP TABLE IF EXISTS gitops.runbook_triggers CASCADE;
DROP TABLE IF EXISTS gitops.runbook_steps CASCADE;
DROP TABLE IF EXISTS gitops.runbook_versions CASCADE;
DROP TABLE IF EXISTS gitops.runbook_definitions CASCADE;

-- Drop ENUM types (order respects dependencies)
DROP TYPE IF EXISTS gitops.runbook_commit_pr_status;
DROP TYPE IF EXISTS gitops.runbook_step_on_failure;
DROP TYPE IF EXISTS gitops.runbook_step_action_type;
DROP TYPE IF EXISTS gitops.runbook_trigger_type;
DROP TYPE IF EXISTS gitops.runbook_validation_status;
DROP TYPE IF EXISTS gitops.runbook_status;

-- Drop schema (only if empty)
-- NOTE: Only drop if no other objects exist in the gitops schema
-- DROP SCHEMA IF EXISTS gitops CASCADE;
