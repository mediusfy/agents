-- =============================================================================
-- GITOPS-04: Policy-as-Code for Remediation Approval Gates
-- =============================================================================
-- Schema: gitops
--
-- This migration implements the Policy-as-Code subsystem for remediation PRs.
-- Policy rules are YAML files stored in the same git repository as runbooks.
-- When a remediation PR is created, the policy engine evaluates it against
-- the active rules and determines:
--   1. Required approvers (based on severity, service, environment)
--   2. Whether the PR is blocked due to policy violations
--   3. Whether escalation is needed
--
-- Events emitted by this subsystem:
--   - gitops.ApprovalGateStatusChanged  (approved/blocked/escalated)
--   - policyEngine.PolicyViolationDetected
--
-- Dependencies:
--   - Requires the 'gitops' schema (created by GITOPS-02_000_schema_setup)
--   - Reuses the trigger function gitops.update_modified_column()
-- =============================================================================

-- =============================================================================
-- SECTION 1: ENUM Types
-- =============================================================================

CREATE TYPE gitops.policy_rule_severity AS ENUM (
    'critical',   -- Immediate threat to production
    'high',       -- Significant impact
    'medium',     -- Moderate impact
    'low',        -- Minor impact
    'informational' -- Advisory only
);

CREATE TYPE gitops.policy_rule_effect AS ENUM (
    'require_approval',  -- Requires specific approver(s) to sign off
    'block',             -- Blocks the merge entirely
    'warn',              -- Warning only, does not block
    'escalate'           -- Escalates to higher authority
);

CREATE TYPE gitops.approval_gate_status AS ENUM (
    'pending',    -- Awaiting approvals
    'approved',   -- All required approvals obtained
    'blocked',    -- Policy violation blocking the merge
    'escalated',  -- Escalated to higher authority
    'expired',    -- Approval window expired
    'denied'      -- Explicitly denied
);

CREATE TYPE gitops.policy_evaluation_status AS ENUM (
    'running',    -- Evaluation in progress
    'passed',     -- No violations
    'failed',     -- One or more violations detected
    'error'       -- Evaluation encountered an error
);

CREATE TYPE gitops.approver_type AS ENUM (
    'user',           -- Specific individual
    'role',           -- Any member of a role (e.g., 'sre-lead')
    'team',           -- Any member of a team
    'group'           -- Any member of an external group
);

CREATE TYPE gitops.environment_name AS ENUM (
    'production',
    'staging',
    'development',
    'sandbox'
);

-- =============================================================================
-- SECTION 2: policy_rules
-- =============================================================================
-- Cached representation of the YAML policy-as-code files stored in the git
-- repository alongside runbooks. The policy engine syncs rules from the git
-- repository on startup and on webhook events.
--
-- Each rule defines:
--   - Conditions under which it applies (severity, service, environment)
--   - Required approvers or approval groups
--   - The effect when the rule is triggered
--   - Remediation guidance for PR authors
-- =============================================================================

CREATE TABLE IF NOT EXISTS gitops.policy_rules (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Identity & Naming
    name                            VARCHAR(255) NOT NULL,
    slug                            VARCHAR(255) NOT NULL,
    description                     TEXT,
    category                        VARCHAR(128),           -- e.g., 'compliance', 'security', 'operational'
    tags                            TEXT[] DEFAULT '{}',

    -- Policy Rule Details
    severity                        gitops.policy_rule_severity NOT NULL DEFAULT 'medium',
    effect                          gitops.policy_rule_effect NOT NULL DEFAULT 'require_approval',

    -- Conditions (the "when" part of the rule)
    -- The policy engine evaluates these conditions against the PR context
    -- Format: {"environments": ["production"], "services": ["api-gateway", "auth"], "severities": ["critical", "high"]}
    -- If a condition is empty/null, it matches all (wildcard)
    applies_to_environments         TEXT[] DEFAULT '{}',     -- Empty = all environments
    applies_to_services             TEXT[] DEFAULT '{}',     -- Empty = all services
    applies_to_severities           TEXT[] DEFAULT '{}',     -- Empty = all severities
    applies_to_teams                TEXT[] DEFAULT '{}',     -- Empty = all teams

    -- Additional CEL expression for advanced condition matching
    -- e.g., "has_pr_label('change-advisory-board') == false && environment == 'production'"
    condition_expression            TEXT,

    -- Required Approvers (the "who" part)
    -- List of approver specifications that must be satisfied
    required_approvers              JSONB NOT NULL DEFAULT '[]',
    -- Each entry in the array:
    -- {
    --   "type": "role" | "user" | "team" | "group",
    --   "value": "sre-lead" | "jane.doe" | "security-team" | "change-advisory-board",
    --   "min_approvals": 1,
    --   "reason": "Production changes require SRE lead approval"
    -- }

    -- Remediation Guidance (shown to PR author on violation)
    violation_message               TEXT,
    remediation_guidance            TEXT,

    -- Merge Blocking
    blocks_merge                    BOOLEAN NOT NULL DEFAULT TRUE,
    escalation_minutes              INTEGER,                -- Auto-escalate after N minutes

    -- Git Source (which repo/file defines this rule)
    git_repository                  VARCHAR(1024) NOT NULL,
    git_path                        VARCHAR(1024) NOT NULL,
    git_branch                      VARCHAR(512) DEFAULT 'main',
    git_commit_sha                  CHAR(40),

    -- Rule Lifecycle
    enabled                         BOOLEAN NOT NULL DEFAULT TRUE,
    priority                        INTEGER NOT NULL DEFAULT 100,  -- Lower = higher priority (evaluated first)

    -- Audit
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Constraints
    CONSTRAINT uq_policy_rules_slug UNIQUE (slug),
    CONSTRAINT uq_policy_rules_repo_path UNIQUE (git_repository, git_path),
    CONSTRAINT chk_policy_rules_name_not_empty CHECK (char_length(TRIM(name)) > 0)
);

COMMENT ON TABLE gitops.policy_rules IS
    'Policy-as-Code rules synced from git repository. Defines approval requirements, merge blocks, and escalation policies for remediation PRs based on severity, service, and environment.';
COMMENT ON COLUMN gitops.policy_rules.required_approvers IS
    'JSONB array of required approver specifications. Each entry: {type, value, min_approvals, reason}.';
COMMENT ON COLUMN gitops.policy_rules.condition_expression IS
    'Optional CEL (Common Expression Language) expression for advanced condition matching beyond the basic applies_to fields.';
COMMENT ON COLUMN gitops.policy_rules.violation_message IS
    'Detailed message shown to the PR author when this rule is violated.';
COMMENT ON COLUMN gitops.policy_rules.remediation_guidance IS
    'Actionable guidance for the PR author on how to resolve the violation.';
COMMENT ON COLUMN gitops.policy_rules.blocks_merge IS
    'If true, a violation of this rule prevents the PR from being merged.';
COMMENT ON COLUMN gitops.policy_rules.escalation_minutes IS
    'If set and required approvals are not obtained within this time, the gate is automatically escalated.';

-- Indexes for policy_rules
CREATE INDEX IF NOT EXISTS idx_policy_rules_enabled ON gitops.policy_rules(enabled) WHERE enabled = TRUE;
CREATE INDEX IF NOT EXISTS idx_policy_rules_severity ON gitops.policy_rules(severity);
CREATE INDEX IF NOT EXISTS idx_policy_rules_effect ON gitops.policy_rules(effect);
CREATE INDEX IF NOT EXISTS idx_policy_rules_category ON gitops.policy_rules(category);
CREATE INDEX IF NOT EXISTS idx_policy_rules_priority ON gitops.policy_rules(priority);
CREATE INDEX IF NOT EXISTS idx_policy_rules_tags ON gitops.policy_rules USING GIN(tags);
CREATE INDEX IF NOT EXISTS idx_policy_rules_environments ON gitops.policy_rules USING GIN(applies_to_environments);
CREATE INDEX IF NOT EXISTS idx_policy_rules_services ON gitops.policy_rules USING GIN(applies_to_services);
CREATE INDEX IF NOT EXISTS idx_policy_rules_severities ON gitops.policy_rules USING GIN(applies_to_severities);
CREATE INDEX IF NOT EXISTS idx_policy_rules_teams ON gitops.policy_rules USING GIN(applies_to_teams);
CREATE INDEX IF NOT EXISTS idx_policy_rules_git_commit ON gitops.policy_rules(git_commit_sha);
CREATE INDEX IF NOT EXISTS idx_policy_rules_created_at ON gitops.policy_rules(created_at DESC);

-- =============================================================================
-- SECTION 3: policy_evaluations
-- =============================================================================
-- Records each evaluation run of a remediation PR by the policy engine.
-- An evaluation references all matching rules and their outcomes.
-- =============================================================================

CREATE TABLE IF NOT EXISTS gitops.policy_evaluations (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- PR Context (what was evaluated)
    pr_vendor                       VARCHAR(64) NOT NULL,    -- e.g., 'github', 'gitlab', 'bitbucket'
    pr_repository                   VARCHAR(1024) NOT NULL,  -- e.g., 'org/repo-name'
    pr_number                       INTEGER NOT NULL,
    pr_branch                       VARCHAR(512),
    pr_title                        VARCHAR(500),
    pr_author                       VARCHAR(255) NOT NULL,
    pr_url                          VARCHAR(2048),

    -- Evaluation Context
    environment                     gitops.environment_name,
    service                         VARCHAR(255),
    severity                        gitops.policy_rule_severity NOT NULL,
    team                            VARCHAR(255),

    -- Results
    status                          gitops.policy_evaluation_status NOT NULL DEFAULT 'running',
    overall_decision                VARCHAR(32) NOT NULL DEFAULT 'pending'
                                        CHECK (overall_decision IN ('pending', 'approved', 'blocked', 'needs_approval')),

    -- Evaluation Metadata
    rules_matched                   INTEGER NOT NULL DEFAULT 0,
    violations_count                INTEGER NOT NULL DEFAULT 0,
    warnings_count                  INTEGER NOT NULL DEFAULT 0,
    engine_version                  VARCHAR(64),            -- Version of the policy engine
    evaluation_time_ms              INTEGER,                -- How long evaluation took

    -- Raw evaluation data (for auditing/debugging)
    evaluation_context              JSONB DEFAULT '{}',     -- Full context used during evaluation
    matching_rule_ids               UUID[] DEFAULT '{}',    -- IDs of rules that matched this PR
    evaluation_output               JSONB DEFAULT '{}',     -- Full evaluation output

    -- Actor
    initiated_by                    VARCHAR(255) NOT NULL DEFAULT 'system',
    -- e.g., 'system', 'webhook', 'manual', 'pr_created', 'pr_updated'

    -- Audit
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Constraints
    CONSTRAINT uq_policy_evaluations_pr UNIQUE (pr_vendor, pr_repository, pr_number)
);

COMMENT ON TABLE gitops.policy_evaluations IS
    'Records each evaluation of a remediation PR by the policy engine. Stores the PR context, matching rules, violations, and overall decision.';
COMMENT ON COLUMN gitops.policy_evaluations.overall_decision IS
    'The final decision: approved (no blocking violations), blocked (blocking violations found), needs_approval (non-blocking approvals required), pending (still evaluating).';
COMMENT ON COLUMN gitops.policy_evaluations.evaluation_context IS
    'JSONB snapshot of the full context used during evaluation including PR metadata, changed files, commit history, etc.';

-- Indexes for policy_evaluations
CREATE INDEX IF NOT EXISTS idx_policy_evaluations_pr
    ON gitops.policy_evaluations(pr_vendor, pr_repository, pr_number);
CREATE INDEX IF NOT EXISTS idx_policy_evaluations_status
    ON gitops.policy_evaluations(status);
CREATE INDEX IF NOT EXISTS idx_policy_evaluations_decision
    ON gitops.policy_evaluations(overall_decision);
CREATE INDEX IF NOT EXISTS idx_policy_evaluations_environment
    ON gitops.policy_evaluations(environment);
CREATE INDEX IF NOT EXISTS idx_policy_evaluations_service
    ON gitops.policy_evaluations(service);
CREATE INDEX IF NOT EXISTS idx_policy_evaluations_severity
    ON gitops.policy_evaluations(severity);
CREATE INDEX IF NOT EXISTS idx_policy_evaluations_author
    ON gitops.policy_evaluations(pr_author);
CREATE INDEX IF NOT EXISTS idx_policy_evaluations_created_at
    ON gitops.policy_evaluations(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_policy_evaluations_rule_ids_gin
    ON gitops.policy_evaluations USING GIN(matching_rule_ids);

-- =============================================================================
-- SECTION 4: policy_violations
-- =============================================================================
-- Records each specific policy violation detected during a PR evaluation.
-- Each violation links back to the policy rule that was violated and
-- includes the violation message and remediation guidance for the PR author.
-- =============================================================================

CREATE TABLE IF NOT EXISTS gitops.policy_violations (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Links
    policy_evaluation_id            UUID NOT NULL REFERENCES gitops.policy_evaluations(id) ON DELETE CASCADE,
    policy_rule_id                  UUID REFERENCES gitops.policy_rules(id) ON DELETE SET NULL,
    approval_gate_id                UUID,                   -- Set when this violation creates/references an approval gate

    -- Violation Details
    rule_name                       VARCHAR(255) NOT NULL,  -- Denormalized for immutability
    rule_slug                       VARCHAR(255) NOT NULL,
    severity                        gitops.policy_rule_severity NOT NULL,
    effect                          gitops.policy_rule_effect NOT NULL,

    -- Message & Guidance
    violation_message               TEXT NOT NULL,
    remediation_guidance            TEXT,
    violation_detail                JSONB DEFAULT '{}',
    -- Includes contextual details like:
    -- {
    --   "blocking": true,
    --   "matched_condition": "environment=production AND service=api-gateway",
    --   "missing_approvers": ["change-advisory-board"],
    --   "affected_files": ["deploy/api-gateway.yaml"]
    -- }

    -- Resolution
    resolved                        BOOLEAN NOT NULL DEFAULT FALSE,
    resolved_at                     TIMESTAMPTZ,
    resolved_by                     VARCHAR(255),
    resolution_type                 VARCHAR(32),            -- 'approved', 'overridden', 'rule_changed', 'auto_resolved'
    resolution_comment              TEXT,

    -- Audit
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Constraints
    CONSTRAINT fk_violation_approval_gate
        FOREIGN KEY (approval_gate_id)
        REFERENCES gitops.approval_gates(id)
        ON DELETE SET NULL
        DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE gitops.policy_violations IS
    'Records each specific policy violation detected during a PR evaluation. Includes the violation message and remediation guidance shown to the PR author.';
COMMENT ON COLUMN gitops.policy_violations.resolution_type IS
    'How this violation was resolved: approved (approver signed off), overridden (admin override), rule_changed (policy rule was updated), auto_resolved (condition no longer applies).';

-- Indexes for policy_violations
CREATE INDEX IF NOT EXISTS idx_policy_violations_evaluation
    ON gitops.policy_violations(policy_evaluation_id);
CREATE INDEX IF NOT EXISTS idx_policy_violations_rule
    ON gitops.policy_violations(policy_rule_id);
CREATE INDEX IF NOT EXISTS idx_policy_violations_gate
    ON gitops.policy_violations(approval_gate_id);
CREATE INDEX IF NOT EXISTS idx_policy_violations_severity
    ON gitops.policy_violations(severity);
CREATE INDEX IF NOT EXISTS idx_policy_violations_effect
    ON gitops.policy_violations(effect);
CREATE INDEX IF NOT EXISTS idx_policy_violations_resolved
    ON gitops.policy_violations(resolved) WHERE resolved = FALSE;
CREATE INDEX IF NOT EXISTS idx_policy_violations_created_at
    ON gitops.policy_violations(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_policy_violations_detail_gin
    ON gitops.policy_violations USING GIN(violation_detail jsonb_path_ops);

-- =============================================================================
-- SECTION 5: approval_gates
-- =============================================================================
-- Tracks the approval gate lifecycle for a remediation PR.
-- Each gate is tied to a specific PR and environment/service combination.
-- The gate status determines whether the PR can be merged.
--
-- Status lifecycle:
--   pending  -->  approved  (all required approvals obtained)
--   pending  -->  blocked   (blocking policy violation)
--   pending  -->  escalated (auto-escalated or manually escalated)
--   pending  -->  expired   (approval window expired)
--   pending  -->  denied    (explicitly denied by an approver)
--   blocked  -->  escalated (escalated after being blocked)
--   blocked  -->  approved  (violations resolved or overridden)
-- =============================================================================

CREATE TABLE IF NOT EXISTS gitops.approval_gates (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- PR Context
    pr_vendor                       VARCHAR(64) NOT NULL,
    pr_repository                   VARCHAR(1024) NOT NULL,
    pr_number                       INTEGER NOT NULL,
    pr_branch                       VARCHAR(512),
    pr_title                        VARCHAR(500),
    pr_author                       VARCHAR(255) NOT NULL,
    pr_url                          VARCHAR(2048),

    -- Gate Context
    environment                     gitops.environment_name,
    service                         VARCHAR(255),
    severity                        gitops.policy_rule_severity NOT NULL,
    team                            VARCHAR(255),

    -- Status & Decision
    status                          gitops.approval_gate_status NOT NULL DEFAULT 'pending',
    previous_status                 gitops.approval_gate_status,  -- Track transitions for events

    -- Approval Requirements
    min_approvals_required          INTEGER NOT NULL DEFAULT 1 CHECK (min_approvals_required >= 1),
    total_approvals_obtained        INTEGER NOT NULL DEFAULT 0 CHECK (total_approvals_obtained >= 0),
    unique_approver_roles_required  TEXT[] DEFAULT '{}',    -- e.g., {'sre-lead', 'change-advisory-board'}
    unique_approver_roles_obtained  TEXT[] DEFAULT '{}',

    -- Timing
    expires_at                      TIMESTAMPTZ,            -- If set, gate expires after this time
    escalated_at                    TIMESTAMPTZ,
    approved_at                     TIMESTAMPTZ,
    blocked_at                      TIMESTAMPTZ,
    denied_at                       TIMESTAMPTZ,
    denied_reason                   TEXT,

    -- Policy Evaluation Link
    policy_evaluation_id            UUID REFERENCES gitops.policy_evaluations(id) ON DELETE SET NULL,

    -- Event Tracking
    last_status_change_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status_change_count             INTEGER NOT NULL DEFAULT 0,

    -- Audit
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Constraints
    CONSTRAINT uq_approval_gates_pr UNIQUE (pr_vendor, pr_repository, pr_number),
    CONSTRAINT chk_approval_gates_approvals CHECK (total_approvals_obtained <= min_approvals_required OR status = 'escalated')
);

COMMENT ON TABLE gitops.approval_gates IS
    'Tracks the approval gate lifecycle for a remediation PR. Each gate is tied to a specific PR and determines whether the PR can be merged based on policy evaluation results.';
COMMENT ON COLUMN gitops.approval_gates.status IS
    'Current gate status: pending (awaiting approvals), approved (merge allowed), blocked (merge blocked by policy), escalated (sent to higher authority), expired (approval window lapsed), denied (rejected).';
COMMENT ON COLUMN gitops.approval_gates.previous_status IS
    'Tracks the previous status to compute status transitions and publish gitops.ApprovalGateStatusChanged events.';
COMMENT ON COLUMN gitops.approval_gates.last_status_change_at IS
    'Timestamp of the last status change, used for auto-escalation monitoring.';

-- Indexes for approval_gates
CREATE INDEX IF NOT EXISTS idx_approval_gates_pr
    ON gitops.approval_gates(pr_vendor, pr_repository, pr_number);
CREATE INDEX IF NOT EXISTS idx_approval_gates_status
    ON gitops.approval_gates(status);
CREATE INDEX IF NOT EXISTS idx_approval_gates_environment
    ON gitops.approval_gates(environment);
CREATE INDEX IF NOT EXISTS idx_approval_gates_service
    ON gitops.approval_gates(service);
CREATE INDEX IF NOT EXISTS idx_approval_gates_severity
    ON gitops.approval_gates(severity);
CREATE INDEX IF NOT EXISTS idx_approval_gates_author
    ON gitops.approval_gates(pr_author);
CREATE INDEX IF NOT EXISTS idx_approval_gates_expires_at
    ON gitops.approval_gates(expires_at) WHERE status = 'pending' AND expires_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_approval_gates_escalation_due
    ON gitops.approval_gates(status, last_status_change_at)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_approval_gates_created_at
    ON gitops.approval_gates(created_at DESC);

-- =============================================================================
-- SECTION 6: approval_gate_approvers
-- =============================================================================
-- Records the required approvers for a specific approval gate and tracks
-- their approval status. This is the concrete assignment of who needs
-- to approve based on policy rule evaluation.
-- =============================================================================

CREATE TABLE IF NOT EXISTS gitops.approval_gate_approvers (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Links
    approval_gate_id                UUID NOT NULL REFERENCES gitops.approval_gates(id) ON DELETE CASCADE,
    policy_rule_id                  UUID REFERENCES gitops.policy_rules(id) ON DELETE SET NULL,
    policy_violation_id             UUID REFERENCES gitops.policy_violations(id) ON DELETE SET NULL,

    -- Approver Identity
    approver_type                   gitops.approver_type NOT NULL,
    approver_value                  VARCHAR(255) NOT NULL,
    -- For 'user': 'jane.doe@company.com'
    -- For 'role': 'sre-lead'
    -- For 'team': 'security-team'
    -- For 'group': 'change-advisory-board'

    approver_display_name           VARCHAR(255),           -- Human-readable name

    -- Reason this approver is required
    requirement_reason              TEXT NOT NULL,
    rule_name                       VARCHAR(255),           -- Denormalized for context

    -- Approval Status
    approved                        BOOLEAN NOT NULL DEFAULT FALSE,
    approved_at                     TIMESTAMPTZ,
    approved_by_user_id             VARCHAR(255),           -- Who actually approved (may differ from approver_value for roles/teams)
    approved_by_user_display        VARCHAR(255),

    -- Order
    approval_order                  INTEGER NOT NULL DEFAULT 0,  -- Sequential order for requiring approvals

    -- Audit
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Constraints
    CONSTRAINT uq_approval_gate_approvers UNIQUE (approval_gate_id, approver_type, approver_value)
);

COMMENT ON TABLE gitops.approval_gate_approvers IS
    'Records the concrete assignment of required approvers for a specific approval gate, based on policy rule evaluation. Tracks who needs to approve and whether they have.';
COMMENT ON COLUMN gitops.approval_gate_approvers.requirement_reason IS
    'Human-readable explanation of why this approver is required (e.g., "Production changes require CAB approval").';

-- Indexes for approval_gate_approvers
CREATE INDEX IF NOT EXISTS idx_approval_gate_approvers_gate
    ON gitops.approval_gate_approvers(approval_gate_id);
CREATE INDEX IF NOT EXISTS idx_approval_gate_approvers_rule
    ON gitops.approval_gate_approvers(policy_rule_id);
CREATE INDEX IF NOT EXISTS idx_approval_gate_approvers_violation
    ON gitops.approval_gate_approvers(policy_violation_id);
CREATE INDEX IF NOT EXISTS idx_approval_gate_approvers_type
    ON gitops.approval_gate_approvers(approver_type);
CREATE INDEX IF NOT EXISTS idx_approval_gate_approvers_pending
    ON gitops.approval_gate_approvers(approval_gate_id, approved)
    WHERE approved = FALSE;

-- =============================================================================
-- SECTION 7: approval_gate_escalations
-- =============================================================================
-- Records the escalation history for approval gates. When a gate is escalated
-- (either automatically due to timeout or manually), this table tracks who
-- it was escalated to, why, and the resolution.
-- =============================================================================

CREATE TABLE IF NOT EXISTS gitops.approval_gate_escalations (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Links
    approval_gate_id                UUID NOT NULL REFERENCES gitops.approval_gates(id) ON DELETE CASCADE,

    -- Escalation Details
    escalation_level                INTEGER NOT NULL DEFAULT 1,  -- 1st escalation, 2nd escalation, etc.
    escalated_from_status           gitops.approval_gate_status NOT NULL,
    escalated_to_role               VARCHAR(255) NOT NULL,       -- e.g., 'vp-engineering', 'cto', 'incident-commander'
    escalated_to_user               VARCHAR(255),                -- Specific person escalated to

    -- Reason
    reason                          TEXT NOT NULL,
    escalation_trigger              VARCHAR(32) NOT NULL DEFAULT 'auto_timeout'
                                        CHECK (escalation_trigger IN (
                                            'auto_timeout',     -- Escalation due to approval timeout
                                            'manual',           -- Manual escalation by a user
                                            'severity_increase',-- Escalation due to severity increase
                                            'auto_escalation',  -- Automated policy-driven escalation
                                            'blocked_escalation'-- Escalation of a blocked gate
                                        )),

    -- Timing
    escalated_at                    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    response_deadline               TIMESTAMPTZ,             -- Expected response deadline

    -- Resolution
    resolved                        BOOLEAN NOT NULL DEFAULT FALSE,
    resolved_at                     TIMESTAMPTZ,
    resolved_by                     VARCHAR(255),
    resolution_action               VARCHAR(32),
                                        CHECK (resolution_action IN (
                                            'approved',     -- Escalated approver approved
                                            'denied',       -- Escalated approver denied
                                            'overridden',   -- Escalated approver overrode blocks
                                            'returned',     -- Returned to original approvers
                                            'auto_expired'  -- Escalation expired
                                        )),
    resolution_comment              TEXT,

    -- Audit
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE gitops.approval_gate_escalations IS
    'Records the escalation history for approval gates. Includes auto-escalation due to timeout and manual escalations.';

-- Indexes for approval_gate_escalations
CREATE INDEX IF NOT EXISTS idx_approval_gate_escalations_gate
    ON gitops.approval_gate_escalations(approval_gate_id);
CREATE INDEX IF NOT EXISTS idx_approval_gate_escalations_level
    ON gitops.approval_gate_escalations(approval_gate_id, escalation_level);
CREATE INDEX IF NOT EXISTS idx_approval_gate_escalations_unresolved
    ON gitops.approval_gate_escalations(resolved) WHERE resolved = FALSE;
CREATE INDEX IF NOT EXISTS idx_approval_gate_escalations_deadline
    ON gitops.approval_gate_escalations(response_deadline)
    WHERE resolved = FALSE AND response_deadline IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_approval_gate_escalations_trigger
    ON gitops.approval_gate_escalations(escalation_trigger);
CREATE INDEX IF NOT EXISTS idx_approval_gate_escalations_created_at
    ON gitops.approval_gate_escalations(created_at DESC);

-- =============================================================================
-- SECTION 8: policy_rule_sync_log
-- =============================================================================
-- Tracks synchronization of policy rules from git repository to the database.
-- Useful for auditing when rules were synced and detecting drift.
-- =============================================================================

CREATE TABLE IF NOT EXISTS gitops.policy_rule_sync_log (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Sync Details
    sync_status                     VARCHAR(32) NOT NULL
                                        CHECK (sync_status IN ('running', 'success', 'partial', 'failed')),
    git_repository                  VARCHAR(1024) NOT NULL,
    git_branch                      VARCHAR(512) NOT NULL DEFAULT 'main',
    git_commit_sha                  CHAR(40),

    -- Results
    rules_found                     INTEGER NOT NULL DEFAULT 0,
    rules_created                   INTEGER NOT NULL DEFAULT 0,
    rules_updated                   INTEGER NOT NULL DEFAULT 0,
    rules_deleted                   INTEGER NOT NULL DEFAULT 0,
    rules_skipped                   INTEGER NOT NULL DEFAULT 0,
    errors                          JSONB DEFAULT '[]',

    -- Metadata
    sync_duration_ms                INTEGER,
    synced_by                       VARCHAR(255) NOT NULL,  -- Service or user that triggered the sync
    sync_trigger                    VARCHAR(32) NOT NULL DEFAULT 'startup'
                                        CHECK (sync_trigger IN ('startup', 'webhook', 'manual', 'scheduled')),

    -- Audit
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE gitops.policy_rule_sync_log IS
    'Tracks synchronization of policy rules from git repository to the database. Provides audit trail for rule updates and drift detection.';

CREATE INDEX IF NOT EXISTS idx_policy_rule_sync_log_status
    ON gitops.policy_rule_sync_log(sync_status);
CREATE INDEX IF NOT EXISTS idx_policy_rule_sync_log_repo
    ON gitops.policy_rule_sync_log(git_repository, git_branch);
CREATE INDEX IF NOT EXISTS idx_policy_rule_sync_log_commit
    ON gitops.policy_rule_sync_log(git_commit_sha);
CREATE INDEX IF NOT EXISTS idx_policy_rule_sync_log_created_at
    ON gitops.policy_rule_sync_log(created_at DESC);

-- =============================================================================
-- SECTION 9: Triggers
-- =============================================================================

-- Apply updated_at triggers to all tables
CREATE TRIGGER trg_policy_rules_updated_at
    BEFORE UPDATE ON gitops.policy_rules
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

CREATE TRIGGER trg_policy_evaluations_updated_at
    BEFORE UPDATE ON gitops.policy_evaluations
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

CREATE TRIGGER trg_policy_violations_updated_at
    BEFORE UPDATE ON gitops.policy_violations
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

CREATE TRIGGER trg_approval_gates_updated_at
    BEFORE UPDATE ON gitops.approval_gates
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

CREATE TRIGGER trg_approval_gate_approvers_updated_at
    BEFORE UPDATE ON gitops.approval_gate_approvers
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

CREATE TRIGGER trg_approval_gate_escalations_updated_at
    BEFORE UPDATE ON gitops.approval_gate_escalations
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

-- =============================================================================
-- Trigger: Track status changes for approval gates
-- =============================================================================
-- When an approval gate status changes, record the previous status and
-- update the last_status_change_at timestamp. This enables the event
-- publisher to detect status transitions and emit gitops.ApprovalGateStatusChanged events.
-- =============================================================================

CREATE OR REPLACE FUNCTION gitops.track_gate_status_change()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        NEW.previous_status := OLD.status;
        NEW.last_status_change_at := NOW();
        NEW.status_change_count := OLD.status_change_count + 1;

        -- Track timestamps for specific statuses
        CASE NEW.status
            WHEN 'approved' THEN
                NEW.approved_at := NOW();
            WHEN 'blocked' THEN
                NEW.blocked_at := NOW();
            WHEN 'escalated' THEN
                NEW.escalated_at := NOW();
            WHEN 'denied' THEN
                NEW.denied_at := NOW();
            ELSE
                -- No special timestamp needed
        END CASE;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_approval_gates_status_change
    BEFORE UPDATE OF status ON gitops.approval_gates
    FOR EACH ROW
    EXECUTE FUNCTION gitops.track_gate_status_change();

-- =============================================================================
-- SECTION 10: Views for common queries
-- =============================================================================

-- Complete policy evaluation report for a PR
CREATE OR REPLACE VIEW gitops.pr_policy_report AS
SELECT
    pe.id AS evaluation_id,
    pe.pr_vendor,
    pe.pr_repository,
    pe.pr_number,
    pe.pr_title,
    pe.pr_author,
    pe.environment,
    pe.service,
    pe.severity,
    pe.overall_decision AS evaluation_decision,
    pe.status AS evaluation_status,
    pe.rules_matched,
    pe.violations_count,
    pe.warnings_count,
    pe.created_at AS evaluated_at,

    ag.id AS gate_id,
    ag.status AS gate_status,
    ag.min_approvals_required,
    ag.total_approvals_obtained,
    ag.expires_at AS gate_expires_at,
    ag.escalated_at AS gate_escalated_at,
    ag.approved_at AS gate_approved_at,
    ag.last_status_change_at AS gate_last_changed_at,

    pv.id AS violation_id,
    pv.rule_name AS violation_rule,
    pv.severity AS violation_severity,
    pv.effect AS violation_effect,
    pv.violation_message,
    pv.remediation_guidance,
    pv.resolved AS violation_resolved,
    pv.resolved_at AS violation_resolved_at,

    aga.id AS approver_id,
    aga.approver_type,
    aga.approver_value,
    aga.approver_display_name,
    aga.requirement_reason,
    aga.approved AS approver_approved,
    aga.approved_at AS approver_approved_at

FROM gitops.policy_evaluations pe
LEFT JOIN gitops.approval_gates ag ON ag.policy_evaluation_id = pe.id
LEFT JOIN gitops.policy_violations pv ON pv.policy_evaluation_id = pe.id
LEFT JOIN gitops.approval_gate_approvers aga ON aga.approval_gate_id = ag.id;

COMMENT ON VIEW gitops.pr_policy_report IS
    'Complete policy evaluation report for a PR, including evaluation results, approval gate status, violations, and required approvers.';

-- Active (unresolved) policy violations
CREATE OR REPLACE VIEW gitops.active_policy_violations AS
SELECT
    pv.*,
    pe.pr_vendor,
    pe.pr_repository,
    pe.pr_number,
    pe.pr_title,
    pe.pr_author,
    pe.environment,
    pe.service,
    ag.status AS gate_status
FROM gitops.policy_violations pv
JOIN gitops.policy_evaluations pe ON pe.id = pv.policy_evaluation_id
LEFT JOIN gitops.approval_gates ag ON ag.id = pv.approval_gate_id
WHERE pv.resolved = FALSE
ORDER BY pv.severity DESC, pv.created_at DESC;

COMMENT ON VIEW gitops.active_policy_violations IS
    'All unresolved (active) policy violations with their PR context and current gate status.';

-- Pending approval gates that are approaching escalation
CREATE OR REPLACE VIEW gitops.pending_gates_needing_attention AS
SELECT
    ag.*,
    EXTRACT(EPOCH FROM (NOW() - ag.last_status_change_at)) / 60 AS minutes_pending,
    (SELECT COUNT(*) FROM gitops.approval_gate_approvers aga
     WHERE aga.approval_gate_id = ag.id AND aga.approved = FALSE) AS pending_approvers_count
FROM gitops.approval_gates ag
WHERE ag.status = 'pending'
ORDER BY ag.last_status_change_at ASC;

COMMENT ON VIEW gitops.pending_gates_needing_attention IS
    'Approval gates in pending status sorted by longest wait time, useful for monitoring and auto-escalation checks.';

-- =============================================================================
-- SECTION 11: Outbox Event Triggers for Domain Events
-- =============================================================================
-- These triggers automatically insert events into the outbox_events table
-- when key state changes occur, enabling the event publisher to emit
-- CloudEvents-compliant messages.
-- =============================================================================

-- Trigger: Emit gitops.ApprovalGateStatusChanged when gate status changes
CREATE OR REPLACE FUNCTION gitops.emit_approval_gate_status_changed()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO outbox_events (
            event_type, source, subject, payload, dedup_key
        ) VALUES (
            'gitops.ApprovalGateStatusChanged',
            '/gitops/policy-engine',
            'approval-gate:' || NEW.id::TEXT,
            jsonb_build_object(
                'gate_id', NEW.id,
                'pr_vendor', NEW.pr_vendor,
                'pr_repository', NEW.pr_repository,
                'pr_number', NEW.pr_number,
                'pr_url', NEW.pr_url,
                'environment', NEW.environment,
                'service', NEW.service,
                'severity', NEW.severity,
                'previous_status', OLD.status,
                'new_status', NEW.status,
                'changed_at', NEW.last_status_change_at,
                'status_change_count', NEW.status_change_count,
                'min_approvals_required', NEW.min_approvals_required,
                'total_approvals_obtained', NEW.total_approvals_obtained,
                'expires_at', NEW.expires_at
            ),
            'approval-gate-status-' || NEW.id::TEXT || '-' || OLD.status || '-' || NEW.status
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_approval_gates_emit_event
    AFTER UPDATE OF status ON gitops.approval_gates
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION gitops.emit_approval_gate_status_changed();

-- Trigger: Emit policyEngine.PolicyViolationDetected when a violation is created
CREATE OR REPLACE FUNCTION gitops.emit_policy_violation_detected()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO outbox_events (
        event_type, source, subject, payload, dedup_key
    ) VALUES (
        'policyEngine.PolicyViolationDetected',
        '/gitops/policy-engine',
        'policy-violation:' || NEW.id::TEXT,
        jsonb_build_object(
            'violation_id', NEW.id,
            'evaluation_id', NEW.policy_evaluation_id,
            'rule_name', NEW.rule_name,
            'rule_slug', NEW.rule_slug,
            'severity', NEW.severity,
            'effect', NEW.effect,
            'blocks_merge', (NEW.effect = 'block'),
            'violation_message', NEW.violation_message,
            'remediation_guidance', NEW.remediation_guidance,
            'violation_detail', NEW.violation_detail,
            'pr_info': (
                SELECT jsonb_build_object(
                    'vendor', pe.pr_vendor,
                    'repository', pe.pr_repository,
                    'number', pe.pr_number,
                    'title', pe.pr_title,
                    'author', pe.pr_author,
                    'url', pe.pr_url,
                    'environment', pe.environment,
                    'service', pe.service,
                    'severity', pe.severity
                )
                FROM gitops.policy_evaluations pe
                WHERE pe.id = NEW.policy_evaluation_id
            )
        ),
        'policy-violation-' || NEW.id::TEXT
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_policy_violations_emit_event
    AFTER INSERT ON gitops.policy_violations
    FOR EACH ROW
    EXECUTE FUNCTION gitops.emit_policy_violation_detected();

-- =============================================================================
-- SECTION 12: Comment all tables & columns (not all shown for brevity)
-- =============================================================================

COMMENT ON TABLE gitops.policy_evaluations IS
    'Records each evaluation of a remediation PR by the policy engine. Stores the PR context, matching rules, violations, and overall decision.';
COMMENT ON TABLE gitops.policy_violations IS
    'Specific violations detected during policy evaluation. Links to the violated rule and includes remediation guidance for the PR author.';
COMMENT ON TABLE gitops.approval_gates IS
    'Approval gate tracking for remediation PRs. Status determines if a PR can be merged. Supports state transitions: pending -> approved|blocked|escalated|expired|denied.';
COMMENT ON TABLE gitops.approval_gate_approvers IS
    'Concrete assignment of required approvers for a gate. Tracks who needs to approve and whether they have done so.';
COMMENT ON TABLE gitops.approval_gate_escalations IS
    'Escalation history for approval gates. Records when and why a gate was escalated and the resolution.';
COMMENT ON TABLE gitops.policy_rule_sync_log IS
    'Audit log for syncing policy rules from git repository to the database.';
