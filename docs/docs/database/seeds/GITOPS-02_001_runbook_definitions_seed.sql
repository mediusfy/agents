-- Seed: GITOPS-02_001_runbook_definitions_seed.sql
-- Sample runbook definitions for development and testing.
-- These simulate real SRE runbooks that would be defined in YAML and stored in Git.

-- ============================================================================
-- Helper function to create runbooks with all related data
-- ============================================================================

-- Sample Runbook 1: Database failover runbook
WITH 
rb1 AS (
    INSERT INTO gitops.runbook_definitions (
        name, slug, display_name, description, category, tags,
        status, validation_status, current_semver,
        git_repository, git_path, git_branch, current_git_commit_sha,
        yaml_definition, author, owner_team, runbook_url
    ) VALUES (
        'Database Failover',
        'database-failover',
        'Database Failover Runbook',
        'Automated database failover procedure for primary database outages. Includes health checks, replica promotion, and traffic switching.',
        'database',
        ARRAY['database', 'failover', 'postgresql', 'disaster-recovery', 'critical'],
        'active',
        'passed',
        '2.1.0',
        'git@github.com:acme-sre/runbooks.git',
        'runbooks/database/failover.yaml',
        'main',
        'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0',
        '{
            "apiVersion": "runbooks.acme.io/v1",
            "kind": "Runbook",
            "metadata": {
                "name": "database-failover",
                "labels": {
                    "severity": "critical",
                    "team": "sre-database",
                    "pagerduty_urgency": "high"
                }
            },
            "spec": {
                "description": "Automated database failover procedure for primary database outages.",
                "timeout": 1800,
                "runbook_level": "emergency",
                "environments": ["production", "staging"]
            }
        }'::jsonb,
        'jane.doe@acme.com',
        'sre-database',
        'https://github.com/acme-sre/runbooks/blob/main/runbooks/database/failover.yaml'
    ) RETURNING id
),
rb1_version AS (
    INSERT INTO gitops.runbook_versions (
        runbook_id, semver_major, semver_minor, semver_patch, semver_string,
        git_tag, git_commit_sha, git_tag_author, yaml_snapshot, is_current, changelog
    ) VALUES (
        (SELECT id FROM rb1),
        2, 1, 0, '2.1.0',
        'v2.1.0', 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0', 'jane.doe@acme.com',
        '{"name": "database-failover", "version": "2.1.0"}',
        TRUE,
        'Added health check validation before failover. Reduced cooldown from 600s to 300s.'
    ) RETURNING id
),
rb1_trigger AS (
    INSERT INTO gitops.runbook_triggers (
        runbook_id, name, description, trigger_type, trigger_config, enabled, is_default
    ) VALUES 
    (
        (SELECT id FROM rb1),
        'pagerduty-incident-triggered',
        'Automatically triggered when PagerDuty fires a critical database incident',
        'event',
        '{
            "event_type": "incident.triggered",
            "source": "pagerduty",
            "severity": ["critical", "high"],
            "filters": {"service_name": "postgresql-primary"}
        }'::jsonb,
        TRUE, TRUE
    ),
    (
        (SELECT id FROM rb1),
        'manual-sre-invocation',
        'Manually triggered by an SRE during maintenance windows',
        'manual',
        '{
            "allowed_roles": ["sre", "sre-lead", "on-call"],
            "confirmation_required": true,
            "reason_required": true
        }'::jsonb,
        TRUE, FALSE
    )
    RETURNING id
),
rb1_steps AS (
    INSERT INTO gitops.runbook_steps (
        runbook_id, name, description, step_order, step_group, action_type, action_config,
        timeout_seconds, retry_count, retry_delay_seconds, on_failure, parallel_group
    ) VALUES 
    (
        (SELECT id FROM rb1),
        'Health Check Pre-Failover',
        'Verify cluster health and confirm primary is actually down',
        0, 'diagnose', 'command',
        '{
            "command": "pg_isready -h $PRIMARY_HOST -p 5432 -t 10",
            "shell": "/bin/bash",
            "env_vars": ["PRIMARY_HOST"]
        }'::jsonb,
        30, 2, 10, 'abort', NULL
    ),
    (
        (SELECT id FROM rb1),
        'Check Replica Lag',
        'Ensure replica is caught up and ready for promotion',
        1, 'diagnose', 'command',
        '{
            "command": "psql -h $REPLICA_HOST -c \"SELECT pg_last_wal_receive_lsn() - pg_last_wal_replay_lsn() AS lag_bytes;\"",
            "shell": "/bin/bash",
            "env_vars": ["REPLICA_HOST"]
        }'::jsonb,
        30, 1, 5, 'abort', 'diagnose-parallel'
    ),
    (
        (SELECT id FROM rb1),
        'Check Disk Space on Replica',
        'Ensure replica has sufficient disk for promotion',
        1, 'diagnose', 'command',
        '{
            "command": "df -h /data/postgresql | awk \'NR==2 {print $5}\' | sed \'s/%//\'",
            "shell": "/bin/bash"
        }'::jsonb,
        15, 1, 5, 'continue', 'diagnose-parallel'
    ),
    (
        (SELECT id FROM rb1),
        'Approval Gate: Confirm Failover',
        'Requires SRE lead approval before proceeding with failover',
        2, 'approval', 'approval',
        '{
            "message": "Primary database {{PRIMARY_HOST}} is down. Proceed with failover to {{REPLICA_HOST}}?",
            "notification_channel": "#sre-alerts",
            "context": {
                "primary": "$PRIMARY_HOST",
                "replica": "$REPLICA_HOST",
                "lag_bytes": "$LAG_BYTES"
            }
        }'::jsonb,
        300, 0, 0, 'abort', NULL
    ),
    (
        (SELECT id FROM rb1),
        'Promote Replica to Primary',
        'Promote the standby replica to become the new primary',
        3, 'mitigate', 'command',
        '{
            "command": "pg_ctl promote -D /data/postgresql && touch /tmp/failover-complete",
            "shell": "/bin/bash",
            "run_on_host": "$REPLICA_HOST"
        }'::jsonb,
        120, 1, 15, 'rollback', NULL
    ),
    (
        (SELECT id FROM rb1),
        'Update DNS Records',
        'Point the database endpoint to the new primary',
        4, 'mitigate', 'command',
        '{
            "command": "curl -X POST \"https://dns-api.acme.io/v1/records/update\" -H \"Authorization: Bearer $DNS_TOKEN\" -d \'{\"record\": \"db-primary.acme.io\", \"target\": \"{{NEW_PRIMARY_IP}}\"}\'",
            "shell": "/bin/bash"
        }'::jsonb,
        60, 2, 10, 'rollback', NULL
    ),
    (
        (SELECT id FROM rb1),
        'Verify New Primary',
        'Verify the promoted replica is accepting writes',
        5, 'verify', 'command',
        '{
            "command": "psql -h $NEW_PRIMARY -c \"SELECT pg_is_in_recovery(), pg_is_in_recovery() IS FALSE AS is_primary;\" && pg_isready -h $NEW_PRIMARY",
            "shell": "/bin/bash",
            "env_vars": ["NEW_PRIMARY"]
        }'::jsonb,
        30, 2, 5, 'rollback', NULL
    ),
    (
        (SELECT id FROM rb1),
        'Notify Team',
        'Send success notification to SRE team channel',
        6, 'notify', 'notification',
        '{
            "channel": "#sre-database",
            "template": "✅ Database failover completed successfully.\nNew primary: {{NEW_PRIMARY}}\nOld primary: {{PRIMARY_HOST}}\nDuration: {{DURATION}}",
            "severity": "high",
            "pagerduty": true
        }'::jsonb,
        15, 0, 0, 'continue', NULL
    )
    RETURNING id
)
INSERT INTO gitops.runbook_rollback_commands (runbook_step_id, name, description, rollback_order, command_type, command_config, timeout_seconds, ignore_failure, critical)
SELECT
    rb1_steps.id, name, description, 0, 'command',
    '{
        "command": "pg_ctl promote -D /data/postgresql",
        "shell": "/bin/bash",
        "run_on_host": "$PRIMARY_HOST"
    }'::jsonb,
    120, FALSE, TRUE
FROM rb1_steps WHERE rb1_steps.name = 'Promote Replica to Primary';

-- ============================================================================
-- Sample Runbook 2: Kubernetes Node Drain
-- ============================================================================

WITH 
rb2 AS (
    INSERT INTO gitops.runbook_definitions (
        name, slug, display_name, description, category, tags,
        status, validation_status, current_semver,
        git_repository, git_path, git_branch, current_git_commit_sha,
        yaml_definition, author, owner_team, runbook_url
    ) VALUES (
        'Kubernetes Node Drain',
        'k8s-node-drain',
        'K8s Node Drain and Replace',
        'Safely drain, cordon, and replace a Kubernetes worker node. Includes pod migration and node health verification.',
        'kubernetes',
        ARRAY['kubernetes', 'node', 'drain', 'maintenance', 'scheduling'],
        'active',
        'passed',
        '1.3.0',
        'git@github.com:acme-sre/runbooks.git',
        'runbooks/kubernetes/node-drain.yaml',
        'main',
        'b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1',
        '{
            "apiVersion": "runbooks.acme.io/v1",
            "kind": "Runbook",
            "metadata": {
                "name": "k8s-node-drain",
                "labels": {
                    "severity": "moderate",
                    "team": "sre-platform",
                    "environment": ["production", "staging", "development"]
                }
            }
        }'::jsonb,
        'john.smith@acme.com',
        'sre-platform',
        'https://github.com/acme-sre/runbooks/blob/main/runbooks/kubernetes/node-drain.yaml'
    ) RETURNING id
)
INSERT INTO gitops.runbook_versions (
    runbook_id, semver_major, semver_minor, semver_patch, semver_string,
    git_tag, git_commit_sha, git_tag_author, yaml_snapshot, is_current, changelog
) VALUES (
    (SELECT id FROM rb2),
    1, 3, 0, '1.3.0',
    'v1.3.0', 'b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1', 'john.smith@acme.com',
    '{"name": "k8s-node-drain", "version": "1.3.0"}',
    TRUE,
    'Added pre-drain pod count validation. Updated kubectl commands for k8s 1.28 API changes.'
);

-- ============================================================================
-- Sample Runbook 3: SSL Certificate Renewal (in development)
-- ============================================================================

WITH 
rb3 AS (
    INSERT INTO gitops.runbook_definitions (
        name, slug, display_name, description, category, tags,
        status, validation_status, current_semver,
        git_repository, git_path, git_branch, 
        yaml_definition, author, owner_team, runbook_url
    ) VALUES (
        'SSL Certificate Renewal',
        'ssl-cert-renewal',
        'SSL Certificate Renewal & Validation',
        'Automated SSL/TLS certificate renewal using ACME protocol with Let''s Encrypt. Includes validation, renewal, and deployment.',
        'security',
        ARRAY['ssl', 'tls', 'certificate', 'lets-encrypt', 'acme', 'security'],
        'draft',
        'pending',
        NULL,
        'git@github.com:acme-sre/runbooks.git',
        'runbooks/security/ssl-renewal.yaml',
        'feature/ssl-renewal-automation',
        '{
            "apiVersion": "runbooks.acme.io/v1",
            "kind": "Runbook",
            "metadata": {
                "name": "ssl-cert-renewal",
                "labels": {
                    "severity": "high",
                    "team": "sre-security"
                }
            }
        }'::jsonb,
        'alice.wong@acme.com',
        'sre-security',
        'https://github.com/acme-sre/runbooks/blob/feature/ssl-renewal-automation/runbooks/security/ssl-renewal.yaml'
    ) RETURNING id
)
INSERT INTO gitops.runbook_commits (
    runbook_id, commit_sha, commit_message, committed_by, committed_at,
    pr_number, pr_url, pr_status, pr_branch_source, pr_branch_target
) VALUES (
    (SELECT id FROM rb3),
    'c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2',
    'feat: add SSL certificate renewal runbook with ACME validation steps',
    'alice.wong@acme.com',
    NOW() - INTERVAL '2 days',
    '143',
    'https://github.com/acme-sre/runbooks/pull/143',
    'open',
    'feature/ssl-renewal-automation',
    'main'
);

-- ============================================================================
-- Sample Runbook 4: Deprecated runbook
-- ============================================================================

INSERT INTO gitops.runbook_definitions (
    name, slug, display_name, description, category, tags,
    status, validation_status, current_semver,
    git_repository, git_path, git_branch, current_git_commit_sha,
    yaml_definition, author, owner_team, runbook_url
) VALUES (
    'Legacy App Restart',
    'legacy-app-restart',
    'Legacy Application Restart (Deprecated)',
    '[DEPRECATED] Manual application restart procedure. Use the new rolling-update runbook instead.',
    'legacy',
    ARRAY['legacy', 'application', 'restart', 'deprecated'],
    'deprecated',
    'passed',
    '0.9.0',
    'git@github.com:acme-sre/runbooks.git',
    'runbooks/legacy/app-restart.yaml',
    'main',
    'd4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3',
    '{"apiVersion": "runbooks.acme.io/v1", "kind": "Runbook", "metadata": {"name": "legacy-app-restart"}}'::jsonb,
    'bob.johnson@acme.com',
    'sre-legacy',
    'https://github.com/acme-sre/runbooks/blob/main/runbooks/legacy/app-restart.yaml'
);

-- ============================================================================
-- Sample Registry Entries
-- ============================================================================

-- Auto-register the validated runbooks (simulating the trigger behavior)
INSERT INTO gitops.runbook_registry (runbook_id, registered_by, is_discoverable, search_tags, category, popularity_score)
SELECT 
    id, 'seed:initial-setup', TRUE, tags, category,
    CASE slug
        WHEN 'database-failover' THEN 152
        WHEN 'k8s-node-drain' THEN 87
        WHEN 'legacy-app-restart' THEN 12
        ELSE 0
    END
FROM gitops.runbook_definitions
WHERE slug IN ('database-failover', 'k8s-node-drain', 'legacy-app-restart');

-- Update search vectors
UPDATE gitops.runbook_registry SET
    search_vector = to_tsvector('english', 
        COALESCE((SELECT name FROM gitops.runbook_definitions WHERE id = runbook_id), '') || ' ' ||
        COALESCE((SELECT description FROM gitops.runbook_definitions WHERE id = runbook_id), '') || ' ' ||
        COALESCE(array_to_string(search_tags, ' '), '')
    );
