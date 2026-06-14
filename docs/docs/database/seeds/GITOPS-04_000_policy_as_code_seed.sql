-- =============================================================================
-- GITOPS-04: Seed Data - Policy-as-Code Rules
-- =============================================================================
-- Schema: gitops
--
-- Seeds the database with baseline policy-as-code rules that define
-- approval requirements for remediation PRs based on severity, service,
-- and environment.
--
-- These rules mirror the YAML policy files stored in the git repository
-- at .gitops/policies/ and are used as the initial set after migration.
-- =============================================================================

-- =============================================================================
-- 1. Production CAB Approval Rule
-- =============================================================================
-- Any remediation PR targeting production requires Change Advisory Board approval.
-- This is a compliance requirement for all production changes.
INSERT INTO gitops.policy_rules (
    id, name, slug, description, category, tags,
    severity, effect,
    applies_to_environments, applies_to_services, applies_to_severities, applies_to_teams,
    required_approvers,
    violation_message, remediation_guidance,
    blocks_merge, escalation_minutes, priority,
    git_repository, git_path, git_branch, git_commit_sha,
    enabled
) VALUES (
    gen_random_uuid(),
    'Production Change Advisory Board Approval',
    'prod-cab-approval',
    'Any remediation PR targeting production requires Change Advisory Board (CAB) approval before merge. This is a mandatory compliance gate for all production infrastructure changes.',
    'compliance',
    ARRAY['production', 'cab', 'compliance', 'change-management'],
    'critical', 'require_approval',
    ARRAY['production'],     -- applies_to_environments
    '{}',                    -- applies_to_services (all services)
    '{}',                    -- applies_to_severities (all severities)
    '{}',                    -- applies_to_teams (all teams)
    '[
        {
            "type": "group",
            "value": "change-advisory-board",
            "min_approvals": 1,
            "reason": "Production changes require Change Advisory Board approval"
        }
    ]'::JSONB,
    'This remediation PR targets the production environment and requires Change Advisory Board (CAB) approval before it can be merged. CAB approval ensures that all production changes are reviewed for impact, rollback plan, and compliance with change management policies.',
    'Please request CAB approval by commenting /approve-cab on this PR, or escalate to the incident commander if this is a time-sensitive remediation. CAB meeting schedule and members can be found in the runbook: runbooks/compliance/cab-approval.md',
    TRUE,    -- blocks_merge
    120,     -- escalation_minutes (2 hours)
    10,      -- priority (high priority)
    'gitops-platform/policy-rules',
    '.gitops/policies/prod-cab-approval.yaml',
    'main',
    NULL,    -- Will be set on first sync
    TRUE
);

-- =============================================================================
-- 2. Critical Severity SRE Lead Approval
-- =============================================================================
-- Critical severity remediations require SRE Lead sign-off regardless of environment.
INSERT INTO gitops.policy_rules (
    id, name, slug, description, category, tags,
    severity, effect,
    applies_to_environments, applies_to_services, applies_to_severities, applies_to_teams,
    required_approvers,
    violation_message, remediation_guidance,
    blocks_merge, escalation_minutes, priority,
    git_repository, git_path, git_branch, git_commit_sha,
    enabled
) VALUES (
    gen_random_uuid(),
    'Critical Severity SRE Lead Approval',
    'critical-sre-lead-approval',
    'Any remediation PR addressing a critical severity incident requires SRE Lead approval before merge. Critical severity changes carry significant operational risk.',
    'security',
    ARRAY['critical', 'sre', 'security'],
    'critical', 'require_approval',
    '{}',                    -- applies_to_environments (all environments)
    '{}',                    -- applies_to_services (all services)
    ARRAY['critical'],       -- applies_to_severities
    '{}',                    -- applies_to_teams (all teams)
    '[
        {
            "type": "role",
            "value": "sre-lead",
            "min_approvals": 1,
            "reason": "Critical severity remediations require SRE Lead approval"
        }
    ]'::JSONB,
    'This remediation PR addresses a critical severity incident. SRE Lead approval is required before this PR can be merged. Critical severity changes carry significant operational risk and require senior engineering oversight.',
    'Please request SRE Lead approval by tagging @sre-leads on this PR. If the SRE Lead is unavailable, escalate to the Engineering Manager on call per the escalation runbook: runbooks/incidents/critical-severity-escalation.md',
    TRUE,    -- blocks_merge
    60,      -- escalation_minutes (1 hour)
    20,      -- priority
    'gitops-platform/policy-rules',
    '.gitops/policies/critical-sre-lead-approval.yaml',
    'main',
    NULL,
    TRUE
);

-- =============================================================================
-- 3. Production Database Changes - DBA Approval
-- =============================================================================
-- Database changes in production require DBA (Database Administrator) approval.
INSERT INTO gitops.policy_rules (
    id, name, slug, description, category, tags,
    severity, effect,
    applies_to_environments, applies_to_services, applies_to_severities, applies_to_teams,
    required_approvers,
    violation_message, remediation_guidance,
    blocks_merge, escalation_minutes, priority,
    git_repository, git_path, git_branch, git_commit_sha,
    enabled
) VALUES (
    gen_random_uuid(),
    'Production Database Changes Require DBA Approval',
    'prod-db-dba-approval',
    'Any remediation PR that changes database configurations, migrations, or queries in production requires Database Administrator (DBA) approval to prevent data loss or corruption.',
    'operational',
    ARRAY['database', 'dba', 'production', 'data-integrity'],
    'high', 'require_approval',
    ARRAY['production'],     -- applies_to_environments
    ARRAY['database', 'postgresql', 'mysql', 'redis', 'mongodb'],  -- applies_to_services
    '{}',                    -- applies_to_severities (all severities)
    '{}',                    -- applies_to_teams (all teams)
    '[
        {
            "type": "role",
            "value": "dba",
            "min_approvals": 1,
            "reason": "Production database changes require DBA approval to prevent data loss"
        }
    ]'::JSONB,
    'This remediation PR modifies database infrastructure in the production environment. Database Administrators (DBA) must approve this change to ensure data integrity and prevent potential data loss or corruption.',
    'Please request DBA review by tagging @database-admins on this PR. Include the SQL migration or configuration changes in the PR description. Reference the database change runbook for guidelines: runbooks/database/production-change-review.md',
    TRUE,    -- blocks_merge
    90,      -- escalation_minutes (1.5 hours)
    30,      -- priority
    'gitops-platform/policy-rules',
    '.gitops/policies/prod-db-dba-approval.yaml',
    'main',
    NULL,
    TRUE
);

-- =============================================================================
-- 4. Security-Related Changes - Security Team Approval
-- =============================================================================
-- Changes to security-critical services require Security Team approval.
INSERT INTO gitops.policy_rules (
    id, name, slug, description, category, tags,
    severity, effect,
    applies_to_environments, applies_to_services, applies_to_severities, applies_to_teams,
    required_approvers,
    violation_message, remediation_guidance,
    blocks_merge, escalation_minutes, priority,
    git_repository, git_path, git_branch, git_commit_sha,
    enabled
) VALUES (
    gen_random_uuid(),
    'Security-Critical Service Changes Require Security Team Approval',
    'security-team-approval',
    'Changes to security-critical services (auth, WAF, secrets management, IAM) require Security Team approval regardless of environment to prevent security regressions.',
    'security',
    ARRAY['security', 'auth', 'iam', 'compliance'],
    'critical', 'require_approval',
    '{}',                    -- applies_to_environments (all environments)
    ARRAY['auth', 'authentication', 'authorization', 'iam', 'secrets', 'waf', 'firewall', 'cert-manager'],
    '{}',                    -- applies_to_severities (all severities)
    '{}',                    -- applies_to_teams (all teams)
    '[
        {
            "type": "role",
            "value": "security-team",
            "min_approvals": 1,
            "reason": "Security-critical service changes require Security Team review"
        }
    ]'::JSONB,
    'This remediation PR modifies a security-critical service. The Security Team must review and approve this change to ensure no security regressions are introduced.',
    'Please request Security Team review by tagging @security-team on this PR. Include details of the security impact assessment in the PR description. Reference: runbooks/security/change-review.md',
    TRUE,    -- blocks_merge
    60,      -- escalation_minutes (1 hour)
    25,      -- priority
    'gitops-platform/policy-rules',
    '.gitops/policies/security-team-approval.yaml',
    'main',
    NULL,
    TRUE
);

-- =============================================================================
-- 5. Staging Environment - Team Lead Approval
-- =============================================================================
-- Changes to staging require Team Lead approval (non-blocking warning).
INSERT INTO gitops.policy_rules (
    id, name, slug, description, category, tags,
    severity, effect,
    applies_to_environments, applies_to_services, applies_to_severities, applies_to_teams,
    required_approvers,
    violation_message, remediation_guidance,
    blocks_merge, escalation_minutes, priority,
    git_repository, git_path, git_branch, git_commit_sha,
    enabled
) VALUES (
    gen_random_uuid(),
    'Staging Changes Require Team Lead Awareness',
    'staging-team-lead-awareness',
    'Changes to the staging environment should be reviewed by the Team Lead. This is a best-practice approval gate that does not block the merge but ensures team awareness.',
    'operational',
    ARRAY['staging', 'team-lead', 'best-practice'],
    'medium', 'warn',
    ARRAY['staging'],        -- applies_to_environments
    '{}',                    -- applies_to_services (all services)
    '{}',                    -- applies_to_severities (all severities)
    '{}',                    -- applies_to_teams (all teams)
    '[
        {
            "type": "role",
            "value": "team-lead",
            "min_approvals": 1,
            "reason": "Staging environment changes should be reviewed by the Team Lead"
        }
    ]'::JSONB,
    'This remediation PR targets the staging environment. While not a blocking requirement, notifying the Team Lead is recommended for awareness and coordination.',
    'Consider tagging @team-leads on this PR for awareness. This is a non-blocking advisory.',
    FALSE,   -- does NOT block merge
    NULL,    -- no escalation
    100,     -- priority (lower priority)
    'gitops-platform/policy-rules',
    '.gitops/policies/staging-team-lead-awareness.yaml',
    'main',
    NULL,
    TRUE
);

-- =============================================================================
-- 6. High Severity - Cross-Team Notification
-- =============================================================================
-- High severity remediations require notifying the affected service team.
INSERT INTO gitops.policy_rules (
    id, name, slug, description, category, tags,
    severity, effect,
    applies_to_environments, applies_to_services, applies_to_severities, applies_to_teams,
    required_approvers,
    violation_message, remediation_guidance,
    blocks_merge, escalation_minutes, priority,
    git_repository, git_path, git_branch, git_commit_sha,
    enabled
) VALUES (
    gen_random_uuid(),
    'High Severity Cross-Team Notification',
    'high-severity-cross-team-notify',
    'High severity remediations require notifying the team that owns the affected service. Ensures cross-team coordination for impactful changes.',
    'operational',
    ARRAY['high-severity', 'cross-team', 'coordination'],
    'high', 'warn',
    '{}',                    -- applies_to_environments (all environments)
    '{}',                    -- applies_to_services (all services)
    ARRAY['high'],           -- applies_to_severities
    '{}',                    -- applies_to_teams (all teams)
    '[
        {
            "type": "team",
            "value": "{affected_service_team}",
            "min_approvals": 0,
            "reason": "High severity changes should be communicated to the affected service team"
        }
    ]'::JSONB,
    'This remediation PR addresses a high severity incident. The team owning the affected service should be notified for coordination.',
    'Please tag the affected service team (@{service_team}) on this PR for awareness and coordination. This is a non-blocking advisory.',
    FALSE,   -- does NOT block merge
    NULL,    -- no escalation
    110,     -- priority
    'gitops-platform/policy-rules',
    '.gitops/policies/high-severity-cross-team-notify.yaml',
    'main',
    NULL,
    TRUE
);

-- =============================================================================
-- 7. Escalation Rule: Production + Critical + Unapproved
-- =============================================================================
-- If production critical changes are not approved within 2 hours, escalate to CTO.
INSERT INTO gitops.policy_rules (
    id, name, slug, description, category, tags,
    severity, effect,
    applies_to_environments, applies_to_services, applies_to_severities, applies_to_teams,
    required_approvers,
    condition_expression,
    violation_message, remediation_guidance,
    blocks_merge, escalation_minutes, priority,
    git_repository, git_path, git_branch, git_commit_sha,
    enabled
) VALUES (
    gen_random_uuid(),
    'Production Critical Auto-Escalation to CTO',
    'prod-critical-auto-escalation',
    'If a production critical severity remediation PR has not been approved within the escalation window, it is automatically escalated to the CTO office for resolution.',
    'compliance',
    ARRAY['escalation', 'production', 'critical', 'cto'],
    'critical', 'escalate',
    ARRAY['production'],     -- applies_to_environments
    '{}',                    -- applies_to_services (all services)
    ARRAY['critical'],       -- applies_to_severities
    '{}',                    -- applies_to_teams (all teams)
    '[
        {
            "type": "role",
            "value": "cto",
            "min_approvals": 1,
            "reason": "Escalation: Production critical change not approved within window"
        }
    ]'::JSONB,
    'has_escalation_timed_out == true',
    'This production-critical remediation PR has not been approved within the required time window and has been escalated to the CTO office for immediate resolution.',
    'The CTO office has been notified. An incident commander will be assigned to resolve the approval bottleneck. For updates, contact the incident commander on-call.',
    TRUE,    -- blocks_merge
    120,     -- escalation_minutes (2 hours)
    5,       -- priority (highest priority)
    'gitops-platform/policy-rules',
    '.gitops/policies/prod-critical-auto-escalation.yaml',
    'main',
    NULL,
    TRUE
);

-- =============================================================================
-- Verify seed data
-- =============================================================================
-- Run this to verify:
-- SELECT COUNT(*) AS seeded_policy_rules FROM gitops.policy_rules WHERE enabled = TRUE;
