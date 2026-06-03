-- =============================================================================
-- GITOPS-04: Policy-as-Code for Remediation Approval Gates (Down Migration)
-- =============================================================================
-- Schema: gitops
--
-- Rolls back all tables, types, functions, triggers, and views created by
-- the GITOPS-04_000_policy_as_code.up.sql migration.
-- =============================================================================

-- =============================================================================
-- SECTION 1: Drop Triggers
-- =============================================================================

DROP TRIGGER IF EXISTS trg_policy_violations_emit_event ON gitops.policy_violations;
DROP TRIGGER IF EXISTS trg_approval_gates_emit_event ON gitops.approval_gates;
DROP TRIGGER IF EXISTS trg_approval_gates_status_change ON gitops.approval_gates;
DROP TRIGGER IF EXISTS trg_policy_rules_updated_at ON gitops.policy_rules;
DROP TRIGGER IF EXISTS trg_policy_evaluations_updated_at ON gitops.policy_evaluations;
DROP TRIGGER IF EXISTS trg_policy_violations_updated_at ON gitops.policy_violations;
DROP TRIGGER IF EXISTS trg_approval_gates_updated_at ON gitops.approval_gates;
DROP TRIGGER IF EXISTS trg_approval_gate_approvers_updated_at ON gitops.approval_gate_approvers;
DROP TRIGGER IF EXISTS trg_approval_gate_escalations_updated_at ON gitops.approval_gate_escalations;

-- =============================================================================
-- SECTION 2: Drop Functions
-- =============================================================================

DROP FUNCTION IF EXISTS gitops.track_gate_status_change();
DROP FUNCTION IF EXISTS gitops.emit_approval_gate_status_changed();
DROP FUNCTION IF EXISTS gitops.emit_policy_violation_detected();

-- =============================================================================
-- SECTION 3: Drop Views
-- =============================================================================

DROP VIEW IF EXISTS gitops.pr_policy_report;
DROP VIEW IF EXISTS gitops.active_policy_violations;
DROP VIEW IF EXISTS gitops.pending_gates_needing_attention;

-- =============================================================================
-- SECTION 4: Drop Tables (respecting foreign key order)
-- =============================================================================

DROP TABLE IF EXISTS gitops.policy_rule_sync_log CASCADE;
DROP TABLE IF EXISTS gitops.approval_gate_escalations CASCADE;
DROP TABLE IF EXISTS gitops.approval_gate_approvers CASCADE;
DROP TABLE IF EXISTS gitops.approval_gates CASCADE;
DROP TABLE IF EXISTS gitops.policy_violations CASCADE;
DROP TABLE IF EXISTS gitops.policy_evaluations CASCADE;
DROP TABLE IF EXISTS gitops.policy_rules CASCADE;

-- =============================================================================
-- SECTION 5: Drop ENUM Types
-- =============================================================================

DROP TYPE IF EXISTS gitops.approver_type;
DROP TYPE IF EXISTS gitops.environment_name;
DROP TYPE IF EXISTS gitops.approval_gate_status;
DROP TYPE IF EXISTS gitops.policy_evaluation_status;
DROP TYPE IF EXISTS gitops.policy_rule_effect;
DROP TYPE IF EXISTS gitops.policy_rule_severity;
