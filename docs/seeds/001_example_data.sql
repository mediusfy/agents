-- Seed: Example data for Rufkis SRE Platform
-- This demonstrates realistic data across all 4 domains

-- ============================================================
-- Domain 4: Workspace & Team (foundational)
-- ============================================================
INSERT INTO workspaces (id, name, slug, description, settings, created_by, created_at)
VALUES (
    'a1b2c3d4-0000-4000-8000-000000000001',
    'Acme SRE',
    'acme-sre',
    'SRE workspace for Acme Corp production services',
    '{"timezone":"UTC","incident_auto_triage_enabled":true,"self_healing_enabled":false,"finops_enabled":true,"offline_sync_enabled":true}',
    'u0000000-0000-4000-8000-000000000001',
    NOW()
);

INSERT INTO teams (id, workspace_id, name, slug, created_at)
VALUES
    ('t0000001-0000-4000-8000-000000000001', 'a1b2c3d4-0000-4000-8000-000000000001', 'Platform Engineering', 'platform-eng', NOW()),
    ('t0000001-0000-4000-8000-000000000002', 'a1b2c3d4-0000-4000-8000-000000000001', 'SRE', 'sre-team', NOW()),
    ('t0000001-0000-4000-8000-000000000003', 'a1b2c3d4-0000-4000-8000-000000000001', 'FinOps', 'finops', NOW());

-- ============================================================
-- Domain 3: Incident + Classification + RCA
-- ============================================================
INSERT INTO incidents (
    id, title, description, severity, status, source, source_event_id,
    service_name, environment, classification, rca_summary,
    assigned_to, workspace_id, tags, detected_at
) VALUES (
    'i0000001-0000-4000-8000-000000000001',
    'prod-us-east-1: Payment API latency > 5s (p99)',
    'Alert from Datadog: p99 latency on payment-api increased from 200ms to 5.2s at 14:32 UTC. Impacting checkout flow.',
    'SEV1', 'Investigating', 'Datadog', 'dd-mon-12345',
    'payment-api',
    '{"provider":"aws","region":"us-east-1","cluster":"prod-eks-1","namespace":"production"}',
    '{"category":"Application","sub_category":"HighLatency","suggested_team_name":"Platform Engineering","confidence_score":0.87,"reasoning":"Latency spike correlates with recent deployment v2.3.1 at 14:00 UTC. Previous similar incidents attributed to connection pool exhaustion.","classified_by":"rufkis-agent-v2","classified_at":"2026-06-03T14:35:00Z"}',
    '{"summary":"Likely caused by connection pool exhaustion after deployment v2.3.1 increased concurrent connections without pool size adjustment.","confidence_score":0.82,"likely_causes":[{"cause":"Database connection pool exhausted after deployment change","probability":0.72,"evidence":["deployment v2.3.1 @ 14:00","pg_stat_activity shows 200 idle connections"]},{"cause":"Upstream dependency (redis cache cluster) degraded","probability":0.18,"evidence":["redis latency spike at 14:31"]}]}',
    'u0000000-0000-4000-8000-000000000002',
    'a1b2c3d4-0000-4000-8000-000000000001',
    ARRAY['payment', 'latency', 'p99'],
    '2026-06-03T14:32:00Z'
);

-- ============================================================
-- Domain 1: Runbook + Remediation Request
-- ============================================================
INSERT INTO runbook_definitions (
    id, name, description, git_repo, git_path, git_ref, commit_sha,
    version, status, steps, required_approvals, timeout_seconds,
    allowed_services, created_by, created_at
) VALUES (
    'r0000001-0000-4000-8000-000000000001',
    'Restart Payment API Pods',
    'Gracefully restart payment-api pods in a Kubernetes cluster after verifying health checks.',
    'https://github.com/acme/runbooks',
    'runbooks/k8s/restart-payment-api.yaml',
    'main', 'abc123def456',
    '1.2.0', 'Active',
    '[{"order":1,"name":"Verify deployment health","action":"ExecuteScript","target":"check_health.py","parameters":{"endpoint":"/healthz","timeout":10},"on_failure":"Abort"},{"order":2,"name":"Cordon node","action":"ScaleResource","target":"payment-api","parameters":{"replicas":3},"retry_count":1,"on_failure":"Skip"},{"order":3,"name":"Rolling restart","action":"RestartService","target":"deployment/payment-api","parameters":{"strategy":"rolling","max_surge":1},"on_failure":"Escalate"},{"order":4,"name":"Verify recovery","action":"ExecuteScript","target":"check_health.py","parameters":{"endpoint":"/ready","timeout":30},"on_failure":"Rollback"}]',
    1, 600,
    ARRAY['payment-api'],
    'u0000000-0000-4000-8000-000000000001',
    NOW()
);

-- Remediation request linked to above incident
INSERT INTO remediation_requests (
    id, runbook_id, title, status, environment, parameters_override,
    requested_by, source, created_at
) VALUES (
    'm0000001-0000-4000-8000-000000000001',
    'r0000001-0000-4000-8000-000000000001',
    'Restart payment-api pods in prod-us-east-1 (latency incident)',
    'PendingApproval',
    '{"provider":"aws","region":"us-east-1","cluster":"prod-eks-1","namespace":"production"}',
    '{"steps":[{"order":2,"parameters":{"replicas":5}}]}',
    'i0000001-0000-4000-8000-000000000001',  -- Agent triggered this
    'AgentTriage',
    NOW()
);

-- ============================================================
-- Domain 2: FinOps
-- ============================================================
INSERT INTO cost_anomalies (
    id, anomaly_type, severity, provider, region, service, team_id,
    detected_amount_cents, baseline_amount_cents, variance_percent,
    window_start, window_end, dimensions, root_cause_hint, status, detected_at
) VALUES (
    'c0000001-0000-4000-8000-000000000001',
    'Spike', 'High', 'aws', 'us-east-1', 'EC2', 't0000001-0000-4000-8000-000000000001',
    452300, 120500, 275.3,
    '2026-06-01T00:00:00Z', '2026-06-02T00:00:00Z',
    '{"instance_type":"p4d.24xlarge","usage_type":"BoxUsage","region":"us-east-1"}',
    'Unused GPU instances left running over the weekend by CI pipeline',
    'Open',
    '2026-06-02T06:00:00Z'
);

INSERT INTO optimization_recommendations (
    id, title, recommendation_type, provider, region, resource_id,
    current_monthly_cost_cents, estimated_monthly_savings_cents,
    implementation_cost_cents, roi_months, confidence_score, risk_level,
    status, created_at
) VALUES (
    'o0000001-0000-4000-8000-000000000001',
    'Downsize idle p4d.24xlarge GPU instances in us-east-1',
    'ResizeInstance', 'aws', 'us-east-1', 'i-0abcd1234efgh5678',
    452300, 384455, 5000, 0.39, 0.94, 'Low',
    'PendingReview',
    NOW()
);

INSERT INTO showback_allocations (
    id, team_id, team_name, billing_period, provider,
    total_cost_cents, allocated_cost_cents, allocation_method,
    cost_breakdown, created_at
) VALUES (
    's0000001-0000-4000-8000-000000000001',
    't0000001-0000-4000-8000-000000000001', 'Platform Engineering',
    '2026-05', 'aws',
    1250000, 1187500,
    'DirectTag',
    '{"compute_cents":850000,"storage_cents":200000,"networking_cents":87500,"data_transfer_cents":62500,"managed_services_cents":50000,"other_cents":0}',
    NOW()
);

-- ============================================================
-- Domain 4: CRDT / Offline examples
-- ============================================================
INSERT INTO crdt_items (
    id, type, version, lamport_timestamp, actor_id, data,
    parent_id, workspace_id, created_at, updated_at
) VALUES (
    'crdt-0001-0000-4000-8000-000000000001',
    'incident_note', 3, 42, 'u0000000-0000-4000-8000-000000000002',
    '{"content":"Investigation notes: checked Redis cluster health - appears normal. Connection pool settings are being reviewed.","author_name":"Alice SRE","created_at":"2026-06-03T15:00:00Z"}',
    'i0000001-0000-4000-8000-000000000001',
    'a1b2c3d4-0000-4000-8000-000000000001',
    NOW(), NOW()
);
