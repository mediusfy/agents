-- Migration: GITOPS-02_001_runbook_definitions.up.sql
-- Description: Declarative Runbook Definitions Stored in Git
-- Schema: gitops
-- Creates ENUM types, tables, indexes, and triggers for runbook management.

-- ============================================================================
-- ENUM Types
-- ============================================================================

CREATE TYPE gitops.runbook_status AS ENUM (
    'draft',        -- Being authored, not yet active
    'validated',    -- Passed schema validation
    'active',       -- Available for execution
    'deprecated',   -- No longer recommended, but still registered
    'archived'      -- Removed from registry, historical only
);

CREATE TYPE gitops.runbook_validation_status AS ENUM (
    'pending',   -- Awaiting validation
    'passed',    -- Schema validation successful
    'failed'     -- Schema validation failed
);

CREATE TYPE gitops.runbook_trigger_type AS ENUM (
    'event',     -- Triggered by a specific event (e.g., alert, webhook)
    'schedule',  -- Triggered by a cron/time schedule
    'manual',    -- Triggered manually by an SRE
    'webhook'    -- Triggered by an external webhook call
);

CREATE TYPE gitops.runbook_step_action_type AS ENUM (
    'command',      -- Shell command execution
    'script',       -- Inline or referenced script
    'api_call',     -- HTTP/REST API call
    'approval',     -- Wait for human approval
    'sub_runbook',  -- Execute another runbook as a step
    'notification'  -- Send a notification (Slack, PagerDuty, etc.)
);

CREATE TYPE gitops.runbook_step_on_failure AS ENUM (
    'abort',     -- Stop the runbook execution
    'continue',  -- Skip failed step and continue
    'rollback'   -- Execute rollback commands and stop
);

CREATE TYPE gitops.runbook_commit_pr_status AS ENUM (
    'open',
    'merged',
    'closed',
    'draft'
);

-- ============================================================================
-- Table: runbook_definitions
-- ============================================================================
-- Core table representing runbook YAML definitions stored in Git.
-- Each row corresponds to a unique runbook identified by its name and repository.

CREATE TABLE IF NOT EXISTS gitops.runbook_definitions (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Identity & Naming
    name                        VARCHAR(255) NOT NULL,
    slug                        VARCHAR(255) NOT NULL,
    display_name                VARCHAR(512),
    description                 TEXT,
    category                    VARCHAR(128),
    tags                        TEXT[] DEFAULT '{}',
    
    -- Version & Status
    status                      gitops.runbook_status NOT NULL DEFAULT 'draft',
    validation_status           gitops.runbook_validation_status NOT NULL DEFAULT 'pending',
    current_semver              VARCHAR(64),  -- e.g., "1.2.3"
    
    -- Git Metadata
    git_repository              VARCHAR(1024) NOT NULL,
    git_path                    VARCHAR(1024) NOT NULL,       -- Path within repo (e.g., "runbooks/incidents/db-failover.yaml")
    git_branch                  VARCHAR(512) DEFAULT 'main',
    current_git_commit_sha      CHAR(40),
    latest_pr_url               VARCHAR(2048),
    
    -- Raw Definition (parsed from YAML on commit)
    yaml_definition             JSONB NOT NULL DEFAULT '{}',
    yaml_sha256                 VARCHAR(64),                  -- SHA-256 hash of the raw YAML for integrity
    
    -- Ownership & Metadata
    author                      VARCHAR(255) NOT NULL,        -- SRE team member who authored
    owner_team                  VARCHAR(255),                 -- Owning SRE team
    runbook_url                 VARCHAR(2048),                -- Link to the Git source file
    
    -- Audit Columns
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT uq_runbook_definitions_slug UNIQUE (slug),
    CONSTRAINT uq_runbook_definitions_repo_path UNIQUE (git_repository, git_path),
    CONSTRAINT chk_runbook_definitions_name_not_empty CHECK (char_length(TRIM(name)) > 0)
);

COMMENT ON TABLE gitops.runbook_definitions IS 'Core table for declarative runbook definitions stored in Git. Tracks runbooks authored by SRE team members.';
COMMENT ON COLUMN gitops.runbook_definitions.slug IS 'URL-safe unique identifier derived from the runbook name.';
COMMENT ON COLUMN gitops.runbook_definitions.yaml_definition IS 'The complete runbook YAML parsed into JSONB, containing triggers, steps, rollbacks, and approvals.';
COMMENT ON COLUMN gitops.runbook_definitions.author IS 'SRE team member who authored/committed the runbook definition.';

-- Indexes for runbook_definitions
CREATE INDEX IF NOT EXISTS idx_runbook_definitions_status ON gitops.runbook_definitions(status);
CREATE INDEX IF NOT EXISTS idx_runbook_definitions_validation_status ON gitops.runbook_definitions(validation_status);
CREATE INDEX IF NOT EXISTS idx_runbook_definitions_category ON gitops.runbook_definitions(category);
CREATE INDEX IF NOT EXISTS idx_runbook_definitions_author ON gitops.runbook_definitions(author);
CREATE INDEX IF NOT EXISTS idx_runbook_definitions_tags ON gitops.runbook_definitions USING GIN(tags);
CREATE INDEX IF NOT EXISTS idx_runbook_definitions_yaml_gin ON gitops.runbook_definitions USING GIN(yaml_definition jsonb_path_ops);
CREATE INDEX IF NOT EXISTS idx_runbook_definitions_created_at ON gitops.runbook_definitions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_runbook_definitions_git_commit ON gitops.runbook_definitions(current_git_commit_sha);

-- ============================================================================
-- Table: runbook_versions
-- ============================================================================
-- Tracks semantic version history for runbooks, linked to Git tags.
-- Each version corresponds to a semantic version tag applied to a commit.

CREATE TABLE IF NOT EXISTS gitops.runbook_versions (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    runbook_id                  UUID NOT NULL REFERENCES gitops.runbook_definitions(id) ON DELETE CASCADE,
    
    -- Semantic Versioning
    semver_major                INTEGER NOT NULL CHECK (semver_major >= 0),
    semver_minor                INTEGER NOT NULL CHECK (semver_minor >= 0),
    semver_patch                INTEGER NOT NULL CHECK (semver_patch >= 0),
    semver_label                VARCHAR(64),                -- Optional pre-release label: "alpha.1", "rc.2"
    semver_string               VARCHAR(64) NOT NULL,       -- Fully qualified: "1.2.3" or "1.2.3-rc.1"
    
    -- Git Tags
    git_tag                     VARCHAR(255) NOT NULL,       -- e.g., "v1.2.3"
    git_commit_sha              CHAR(40) NOT NULL,
    git_tag_author              VARCHAR(255),               -- Who applied the tag
    
    -- Snapshot
    yaml_snapshot               JSONB NOT NULL,              -- Immutable snapshot of the definition at this version
    yaml_snapshot_sha256        VARCHAR(64),
    
    -- Metadata
    changelog                   TEXT,
    is_current                  BOOLEAN NOT NULL DEFAULT FALSE,
    published_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Audit
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT uq_runbook_versions_tag UNIQUE (runbook_id, git_tag),
    CONSTRAINT uq_runbook_versions_semver UNIQUE (runbook_id, semver_string),
    CONSTRAINT chk_runbook_versions_semver_format CHECK (
        semver_string ~ '^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$'
    )
);

COMMENT ON TABLE gitops.runbook_versions IS 'Semantic version history for runbooks, linked to Git tags. Generated when a gitops.RunbookVersionTagged event is published.';
COMMENT ON COLUMN gitops.runbook_versions.is_current IS 'Flag indicating if this version is the current active version of the runbook.';

CREATE INDEX IF NOT EXISTS idx_runbook_versions_runbook_id ON gitops.runbook_versions(runbook_id);
CREATE INDEX IF NOT EXISTS idx_runbook_versions_semver ON gitops.runbook_versions(runbook_id, semver_string);
CREATE INDEX IF NOT EXISTS idx_runbook_versions_is_current ON gitops.runbook_versions(runbook_id, is_current) WHERE is_current = TRUE;
CREATE INDEX IF NOT EXISTS idx_runbook_versions_git_tag ON gitops.runbook_versions(git_tag);
CREATE INDEX IF NOT EXISTS idx_runbook_versions_published_at ON gitops.runbook_versions(published_at DESC);

-- ============================================================================
-- Table: runbook_triggers
-- ============================================================================
-- Defines the conditions under which a runbook is triggered.
-- Supports event-based, schedule-based, manual, and webhook trigger types.

CREATE TABLE IF NOT EXISTS gitops.runbook_triggers (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    runbook_id                  UUID NOT NULL REFERENCES gitops.runbook_definitions(id) ON DELETE CASCADE,
    version_id                  UUID REFERENCES gitops.runbook_versions(id) ON DELETE SET NULL,
    
    -- Trigger Identity
    name                        VARCHAR(255) NOT NULL,
    description                 TEXT,
    trigger_type                gitops.runbook_trigger_type NOT NULL,
    
    -- Configuration (type-specific)
    -- For 'event': {"event_type": "incident.triggered", "severity": ["critical","major"]}
    -- For 'schedule': {"cron": "0 0 * * *", "timezone": "UTC"}
    -- For 'webhook': {"endpoint": "/webhook/runbook-123", "secret_ref": "vault://webhook-secrets/runbook-123"}
    trigger_config              JSONB NOT NULL DEFAULT '{}',
    
    -- Conditions & Filters
    condition_expression        TEXT,                         -- Optional CEL-like expression to evaluate before triggering
    cooldown_seconds            INTEGER DEFAULT 300,          -- Minimum seconds between re-triggers
    max_concurrent_executions   INTEGER DEFAULT 1,            -- Limit on simultaneous executions
    
    -- Status
    enabled                     BOOLEAN NOT NULL DEFAULT TRUE,
    is_default                  BOOLEAN NOT NULL DEFAULT FALSE,
    
    -- Audit
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT uq_runbook_triggers_name UNIQUE (runbook_id, name)
);

COMMENT ON TABLE gitops.runbook_triggers IS 'Trigger definitions that determine when a runbook should be executed. Supports event-based, schedule-based, manual, and webhook triggers.';
COMMENT ON COLUMN gitops.runbook_triggers.trigger_config IS 'JSONB configuration specific to the trigger type. Schema-validated against the trigger type.';
COMMENT ON COLUMN gitops.runbook_triggers.condition_expression IS 'Optional CEL (Common Expression Language) expression for advanced trigger filtering.';

CREATE INDEX IF NOT EXISTS idx_runbook_triggers_runbook_id ON gitops.runbook_triggers(runbook_id);
CREATE INDEX IF NOT EXISTS idx_runbook_triggers_type ON gitops.runbook_triggers(trigger_type);
CREATE INDEX IF NOT EXISTS idx_runbook_triggers_enabled ON gitops.runbook_triggers(runbook_id, enabled) WHERE enabled = TRUE;
CREATE INDEX IF NOT EXISTS idx_runbook_triggers_config_gin ON gitops.runbook_triggers USING GIN(trigger_config jsonb_path_ops);

-- ============================================================================
-- Table: runbook_steps
-- ============================================================================
-- Ordered steps within a runbook definition. Each step represents an action
-- to perform during runbook execution.

CREATE TABLE IF NOT EXISTS gitops.runbook_steps (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    runbook_id                  UUID NOT NULL REFERENCES gitops.runbook_definitions(id) ON DELETE CASCADE,
    version_id                  UUID REFERENCES gitops.runbook_versions(id) ON DELETE SET NULL,
    
    -- Step Identity & Ordering
    name                        VARCHAR(255) NOT NULL,
    description                 TEXT,
    step_order                  INTEGER NOT NULL CHECK (step_order >= 0),
    step_group                  VARCHAR(255),                -- Logical grouping (e.g., "diagnose", "mitigate", "restore")
    
    -- Action Configuration
    action_type                 gitops.runbook_step_action_type NOT NULL,
    action_config               JSONB NOT NULL DEFAULT '{}',
    -- For 'command': {"command": "kubectl get pods -n $NAMESPACE", "shell": "/bin/bash"}
    -- For 'script': {"script_ref": "./scripts/healthcheck.sh", "args": ["--verbose"]}
    -- For 'api_call': {"url": "https://api.example.com/health", "method": "GET", "headers": {...}}
    -- For 'approval': {"message": "Confirm database failover?"}
    -- For 'sub_runbook': {"runbook_slug": "db-healthcheck", "version": ">=1.0.0"}
    -- For 'notification': {"channel": "#sre-alerts", "template": "...", "severity": "critical"}
    
    -- Execution Controls
    timeout_seconds             INTEGER DEFAULT 300 CHECK (timeout_seconds > 0),
    retry_count                 INTEGER DEFAULT 0 CHECK (retry_count >= 0),
    retry_delay_seconds         INTEGER DEFAULT 30 CHECK (retry_delay_seconds >= 0),
    on_failure                  gitops.runbook_step_on_failure NOT NULL DEFAULT 'abort',
    
    -- Parallel Execution
    depends_on                  UUID[] DEFAULT '{}',          -- IDs of steps that must complete before this one
    parallel_group              VARCHAR(128),                 -- Steps in same parallel group run concurrently
    
    -- Audit
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT uq_runbook_steps_order UNIQUE (runbook_id, step_order)
);

COMMENT ON TABLE gitops.runbook_steps IS 'Ordered steps within a runbook definition. Each step contains the action to perform and execution controls.';
COMMENT ON COLUMN gitops.runbook_steps.action_config IS 'JSONB configuration for the step action. Schema varies based on action_type.';
COMMENT ON COLUMN gitops.runbook_steps.depends_on IS 'Array of step UUIDs that must complete before this step can execute. Enables DAG-based execution ordering.';

CREATE INDEX IF NOT EXISTS idx_runbook_steps_runbook_id ON gitops.runbook_steps(runbook_id);
CREATE INDEX IF NOT EXISTS idx_runbook_steps_order ON gitops.runbook_steps(runbook_id, step_order);
CREATE INDEX IF NOT EXISTS idx_runbook_steps_action_type ON gitops.runbook_steps(action_type);
CREATE INDEX IF NOT EXISTS idx_runbook_steps_group ON gitops.runbook_steps(runbook_id, step_group);
CREATE INDEX IF NOT EXISTS idx_runbook_steps_action_config_gin ON gitops.runbook_steps USING GIN(action_config jsonb_path_ops);

-- ============================================================================
-- Table: runbook_rollback_commands
-- ============================================================================
-- Rollback commands associated with runbook steps. When a step fails with
-- 'rollback' on_failure policy, these commands are executed in order.

CREATE TABLE IF NOT EXISTS gitops.runbook_rollback_commands (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    runbook_step_id             UUID NOT NULL REFERENCES gitops.runbook_steps(id) ON DELETE CASCADE,
    
    -- Rollback Identity
    name                        VARCHAR(255) NOT NULL,
    description                 TEXT,
    rollback_order              INTEGER NOT NULL CHECK (rollback_order >= 0),
    
    -- Command Configuration
    command_type                gitops.runbook_step_action_type NOT NULL DEFAULT 'command',
    command_config              JSONB NOT NULL DEFAULT '{}',
    -- For 'command': {"command": "kubectl rollout undo deployment/db", "shell": "/bin/bash"}
    -- For 'script': {"script_ref": "./scripts/rollback.sh", "args": ["--state", "previous"]}
    
    -- Execution Controls
    timeout_seconds             INTEGER DEFAULT 300 CHECK (timeout_seconds > 0),
    ignore_failure              BOOLEAN NOT NULL DEFAULT FALSE,  -- If true, continue rollback even if this command fails
    critical                    BOOLEAN NOT NULL DEFAULT TRUE,   -- If true, rollback must succeed
    
    -- Audit
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT uq_runbook_rollback_commands_order UNIQUE (runbook_step_id, rollback_order)
);

COMMENT ON TABLE gitops.runbook_rollback_commands IS 'Rollback commands that revert changes made by a runbook step. Executed in order when a step fails with rollback on_failure policy.';
COMMENT ON COLUMN gitops.runbook_rollback_commands.ignore_failure IS 'If true, the rollback continues even if this command fails.';
COMMENT ON COLUMN gitops.runbook_rollback_commands.critical IS 'If true, this rollback command must succeed for the overall rollback to be considered successful.';

CREATE INDEX IF NOT EXISTS idx_runbook_rollback_commands_step_id ON gitops.runbook_rollback_commands(runbook_step_id);
CREATE INDEX IF NOT EXISTS idx_runbook_rollback_commands_order ON gitops.runbook_rollback_commands(runbook_step_id, rollback_order);
CREATE INDEX IF NOT EXISTS idx_runbook_rollback_commands_config_gin ON gitops.runbook_rollback_commands USING GIN(command_config jsonb_path_ops);

-- ============================================================================
-- Table: runbook_approval_requirements
-- ============================================================================
-- Defines approval gates for runbook execution. Runbooks can have different
-- approval requirements at various stages (e.g., before execution, before
-- destructive steps, before production deployment).

CREATE TABLE IF NOT EXISTS gitops.runbook_approval_requirements (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    runbook_id                  UUID NOT NULL REFERENCES gitops.runbook_definitions(id) ON DELETE CASCADE,
    version_id                  UUID REFERENCES gitops.runbook_versions(id) ON DELETE SET NULL,
    
    -- Approval Identity
    name                        VARCHAR(255) NOT NULL,
    description                 TEXT,
    approval_stage              VARCHAR(128) NOT NULL DEFAULT 'pre_execution',
    -- Stages: 'pre_execution', 'step_gate' (before a specific step), 'post_execution'
    
    -- Approval Rules
    min_approvals               INTEGER NOT NULL DEFAULT 1 CHECK (min_approvals >= 1),
    max_approvals               INTEGER CHECK (max_approvals IS NULL OR max_approvals >= min_approvals),
    allowed_approvers           TEXT[] NOT NULL DEFAULT '{}',    -- Roles or team members
    allowed_approver_roles      TEXT[] NOT NULL DEFAULT '{}',    -- e.g., { "sre", "sre-lead", "on-call" }
    
    -- Timeout & Expiry
    timeout_minutes             INTEGER DEFAULT 60 CHECK (timeout_minutes > 0),
    auto_approve_after_minutes  INTEGER,                         -- If set, auto-approves after timeout
    expires_in_hours            INTEGER,                         -- Approval validity window
    
    -- Step Gate (if approval_stage = 'step_gate')
    target_step_id              UUID REFERENCES gitops.runbook_steps(id) ON DELETE CASCADE,
    
    -- Notifications
    notification_channel        VARCHAR(255),                    -- Where to send approval requests
    notification_template       TEXT,                            -- Custom message template
    
    -- Audit
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT uq_runbook_approval_requirements_name UNIQUE (runbook_id, name)
);

COMMENT ON TABLE gitops.runbook_approval_requirements IS 'Approval requirements for runbook execution. Defines who can approve, how many approvals are needed, and timeout policies.';
COMMENT ON COLUMN gitops.runbook_approval_requirements.allowed_approvers IS 'List of specific SRE team members who can approve.';
COMMENT ON COLUMN gitops.runbook_approval_requirements.allowed_approver_roles IS 'List of roles that can approve (e.g., sre, sre-lead).';

CREATE INDEX IF NOT EXISTS idx_runbook_approval_runbook_id ON gitops.runbook_approval_requirements(runbook_id);
CREATE INDEX IF NOT EXISTS idx_runbook_approval_stage ON gitops.runbook_approval_requirements(approval_stage);
CREATE INDEX IF NOT EXISTS idx_runbook_approval_target_step ON gitops.runbook_approval_requirements(target_step_id);
CREATE INDEX IF NOT EXISTS idx_runbook_approval_allowed_gin ON gitops.runbook_approval_requirements USING GIN(allowed_approvers);
CREATE INDEX IF NOT EXISTS idx_runbook_approval_roles_gin ON gitops.runbook_approval_requirements USING GIN(allowed_approver_roles);

-- ============================================================================
-- Table: runbook_registry
-- ============================================================================
-- Registry for runbook discoverability. When a runbook is validated and active,
-- it is registered here for discovery via the runbook registry API.

CREATE TABLE IF NOT EXISTS gitops.runbook_registry (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    runbook_id                  UUID NOT NULL REFERENCES gitops.runbook_definitions(id) ON DELETE CASCADE,
    version_id                  UUID REFERENCES gitops.runbook_versions(id) ON DELETE SET NULL,
    
    -- Registry Identity
    registered_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    registered_by               VARCHAR(255) NOT NULL,        -- Who/what registered the runbook
    is_discoverable             BOOLEAN NOT NULL DEFAULT TRUE,
    
    -- Search & Discovery
    search_tags                 TEXT[] DEFAULT '{}',
    search_vector               TSVECTOR,                      -- Full-text search vector
    category                    VARCHAR(128),
    popularity_score            INTEGER DEFAULT 0,             -- Based on usage/execution count
    
    -- API Metadata
    api_endpoint                VARCHAR(2048),                 -- Registry API endpoint for this runbook
    schema_url                  VARCHAR(2048),                 -- URL to the runbook schema definition
    
    -- Audit
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT uq_runbook_registry_runbook UNIQUE (runbook_id)
);

COMMENT ON TABLE gitops.runbook_registry IS 'Registry for runbook discoverability via the Registry API. Populated when a gitops.RunbookRegistered event is published.';
COMMENT ON COLUMN gitops.runbook_registry.search_vector IS 'Full-text search vector enabling fast text search across runbook names, descriptions, and tags.';
COMMENT ON COLUMN gitops.runbook_registry.popularity_score IS 'Heuristic score based on runbook execution frequency, incrementing on each successful execution.';

CREATE INDEX IF NOT EXISTS idx_runbook_registry_discoverable ON gitops.runbook_registry(is_discoverable) WHERE is_discoverable = TRUE;
CREATE INDEX IF NOT EXISTS idx_runbook_registry_category ON gitops.runbook_registry(category);
CREATE INDEX IF NOT EXISTS idx_runbook_registry_tags_gin ON gitops.runbook_registry USING GIN(search_tags);
CREATE INDEX IF NOT EXISTS idx_runbook_registry_search_gin ON gitops.runbook_registry USING GIN(search_vector);
CREATE INDEX IF NOT EXISTS idx_runbook_registry_popularity ON gitops.runbook_registry(popularity_score DESC);
CREATE INDEX IF NOT EXISTS idx_runbook_registry_registered_at ON gitops.runbook_registry(registered_at DESC);

-- ============================================================================
-- Table: runbook_validation_results
-- ============================================================================
-- Records the results of schema validation when a runbook is committed.
-- Linked to the gitops.RunbookValidated event.

CREATE TABLE IF NOT EXISTS gitops.runbook_validation_results (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    runbook_id                  UUID NOT NULL REFERENCES gitops.runbook_definitions(id) ON DELETE CASCADE,
    version_id                  UUID REFERENCES gitops.runbook_versions(id) ON DELETE SET NULL,
    
    -- Validation Details
    validation_status           gitops.runbook_validation_status NOT NULL,
    validated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    validated_by                VARCHAR(255) NOT NULL,        -- Validator service or version
    
    -- Results
    validation_errors           JSONB DEFAULT '[]'::JSONB,    -- Array of validation error objects
    validation_warnings         JSONB DEFAULT '[]'::JSONB,    -- Array of validation warning objects
    schema_version              VARCHAR(64) NOT NULL,          -- Version of the runbook schema used
    
    -- Execution Context
    git_commit_sha              CHAR(40) NOT NULL,             -- Which commit was validated
    execution_time_ms           INTEGER,                       -- How long validation took
    
    -- Audit
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Validation error format:
    -- [{
    --   "field": "triggers[0].trigger_type",
    --   "message": "Invalid trigger type 'invalid_type'. Expected one of: event, schedule, manual, webhook",
    --   "severity": "error",
    --   "schema_path": "#/definitions/Trigger/properties/trigger_type"
    -- }]
);

COMMENT ON TABLE gitops.runbook_validation_results IS 'Records the results of runbook schema validation. Published when a gitops.RunbookValidated event is emitted.';
COMMENT ON COLUMN gitops.runbook_validation_results.validation_errors IS 'JSONB array of validation error objects with field path, message, severity, and schema reference.';

CREATE INDEX IF NOT EXISTS idx_runbook_validation_runbook_id ON gitops.runbook_validation_results(runbook_id);
CREATE INDEX IF NOT EXISTS idx_runbook_validation_status ON gitops.runbook_validation_results(validation_status);
CREATE INDEX IF NOT EXISTS idx_runbook_validation_git_commit ON gitops.runbook_validation_results(git_commit_sha);
CREATE INDEX IF NOT EXISTS idx_runbook_validation_validated_at ON gitops.runbook_validation_results(validated_at DESC);
CREATE INDEX IF NOT EXISTS idx_runbook_validation_errors_gin ON gitops.runbook_validation_results USING GIN(validation_errors jsonb_path_ops);

-- ============================================================================
-- Table: runbook_commits
-- ============================================================================
-- Tracks Git commits associated with runbook changes. Supports the PR workflow
-- by linking commits, PRs, and validation results.

CREATE TABLE IF NOT EXISTS gitops.runbook_commits (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    runbook_id                  UUID NOT NULL REFERENCES gitops.runbook_definitions(id) ON DELETE CASCADE,
    
    -- Git Commit Details
    commit_sha                  CHAR(40) NOT NULL,
    commit_message              TEXT NOT NULL,
    committed_by                VARCHAR(255) NOT NULL,        -- Git author
    committed_at                TIMESTAMPTZ NOT NULL,
    
    -- PR Workflow
    pr_number                   VARCHAR(32),                  -- PR number (e.g., "42")
    pr_url                      VARCHAR(2048),                -- Full URL to the PR
    pr_status                   gitops.runbook_commit_pr_status,
    pr_branch_source            VARCHAR(512),                 -- Source branch (feature branch)
    pr_branch_target            VARCHAR(512) DEFAULT 'main',  -- Target branch
    
    -- Versioning
    version_tag                 VARCHAR(64),                  -- Semver tag applied to this commit (e.g., "v1.2.3")
    version_id                  UUID REFERENCES gitops.runbook_versions(id) ON DELETE SET NULL,
    
    -- Validation
    validation_result_id        UUID REFERENCES gitops.runbook_validation_results(id) ON DELETE SET NULL,
    
    -- Audit
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT uq_runbook_commits_commit UNIQUE (runbook_id, commit_sha)
);

COMMENT ON TABLE gitops.runbook_commits IS 'Tracks Git commits associated with runbook changes. Enables PR workflow audit trail and links commits to versions and validation results.';

CREATE INDEX IF NOT EXISTS idx_runbook_commits_runbook_id ON gitops.runbook_commits(runbook_id);
CREATE INDEX IF NOT EXISTS idx_runbook_commits_commit_sha ON gitops.runbook_commits(commit_sha);
CREATE INDEX IF NOT EXISTS idx_runbook_commits_committed_by ON gitops.runbook_commits(committed_by);
CREATE INDEX IF NOT EXISTS idx_runbook_commits_pr_status ON gitops.runbook_commits(pr_status);
CREATE INDEX IF NOT EXISTS idx_runbook_commits_pr_number ON gitops.runbook_commits(pr_number);
CREATE INDEX IF NOT EXISTS idx_runbook_commits_committed_at ON gitops.runbook_commits(committed_at DESC);

-- ============================================================================
-- Triggers
-- ============================================================================

-- Auto-update updated_at for all tables
CREATE OR REPLACE FUNCTION gitops.update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply updated_at triggers
CREATE TRIGGER trg_runbook_definitions_updated_at
    BEFORE UPDATE ON gitops.runbook_definitions
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

CREATE TRIGGER trg_runbook_versions_updated_at
    BEFORE UPDATE ON gitops.runbook_versions
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

CREATE TRIGGER trg_runbook_triggers_updated_at
    BEFORE UPDATE ON gitops.runbook_triggers
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

CREATE TRIGGER trg_runbook_steps_updated_at
    BEFORE UPDATE ON gitops.runbook_steps
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

CREATE TRIGGER trg_runbook_rollback_commands_updated_at
    BEFORE UPDATE ON gitops.runbook_rollback_commands
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

CREATE TRIGGER trg_runbook_approval_requirements_updated_at
    BEFORE UPDATE ON gitops.runbook_approval_requirements
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

CREATE TRIGGER trg_runbook_registry_updated_at
    BEFORE UPDATE ON gitops.runbook_registry
    FOR EACH ROW EXECUTE FUNCTION gitops.update_modified_column();

-- ============================================================================
-- Trigger: Auto-register runbook on validation pass
-- ============================================================================
-- When a runbook's validation status changes to 'passed', automatically
-- register it in the runbook_registry if not already registered.

CREATE OR REPLACE FUNCTION gitops.auto_register_runbook()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.validation_status = 'passed' AND (OLD.validation_status IS DISTINCT FROM 'passed') THEN
        INSERT INTO gitops.runbook_registry (runbook_id, registered_by, is_discoverable, search_tags, category, search_vector)
        VALUES (
            NEW.id,
            'system:auto-register',
            TRUE,
            NEW.tags,
            NEW.category,
            to_tsvector('english', COALESCE(NEW.name, '') || ' ' || COALESCE(NEW.description, '') || ' ' || COALESCE(array_to_string(NEW.tags, ' '), ''))
        )
        ON CONFLICT (runbook_id) DO UPDATE SET
            is_discoverable = TRUE,
            search_tags = NEW.tags,
            category = NEW.category,
            search_vector = to_tsvector('english', COALESCE(NEW.name, '') || ' ' || COALESCE(NEW.description, '') || ' ' || COALESCE(array_to_string(NEW.tags, ' '), '')),
            updated_at = NOW()
        WHERE gitops.runbook_registry.runbook_id = NEW.id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_runbook_definitions_auto_register
    AFTER UPDATE OF validation_status ON gitops.runbook_definitions
    FOR EACH ROW
    WHEN (NEW.validation_status = 'passed')
    EXECUTE FUNCTION gitops.auto_register_runbook();

-- ============================================================================
-- Trigger: Update current version flag
-- ============================================================================
-- When a new version is marked as is_current, clear the flag on all other
-- versions for the same runbook.

CREATE OR REPLACE FUNCTION gitops.update_current_version()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.is_current = TRUE THEN
        UPDATE gitops.runbook_versions
        SET is_current = FALSE
        WHERE runbook_id = NEW.runbook_id AND id <> NEW.id AND is_current = TRUE;
        
        UPDATE gitops.runbook_definitions
        SET current_semver = NEW.semver_string
        WHERE id = NEW.runbook_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_runbook_versions_update_current
    AFTER INSERT OR UPDATE OF is_current ON gitops.runbook_versions
    FOR EACH ROW
    WHEN (NEW.is_current = TRUE)
    EXECUTE FUNCTION gitops.update_current_version();

-- ============================================================================
-- Trigger: Update search vector on registry changes
-- ============================================================================

CREATE OR REPLACE FUNCTION gitops.update_registry_search_vector()
RETURNS TRIGGER AS $$
BEGIN
    NEW.search_vector = to_tsvector('english', 
        COALESCE((SELECT name FROM gitops.runbook_definitions WHERE id = NEW.runbook_id), '') || ' ' ||
        COALESCE((SELECT description FROM gitops.runbook_definitions WHERE id = NEW.runbook_id), '') || ' ' ||
        COALESCE(array_to_string(NEW.search_tags, ' '), '')
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_runbook_registry_search_vector
    BEFORE INSERT OR UPDATE OF search_tags, category ON gitops.runbook_registry
    FOR EACH ROW EXECUTE FUNCTION gitops.update_registry_search_vector();
