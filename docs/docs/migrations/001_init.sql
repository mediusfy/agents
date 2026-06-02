-- ============================================================================
-- RUFKIS — Kubernetes Operations Console
-- Migration 001: Core Schema
-- 
-- This migration creates all tables for every bounded context in Rufkis:
--   - Workload Management   (workload_snapshots, pod_log_streams)
--   - Diagnostics           (diagnostic_requests)
--   - Agents                (agent_workflows, agent_workflow_events)
--   - FinOps                (cost_metrics, cost_anomalies, budget_alerts)
--   - Notifications         (notification_preferences)
--   - Tasks                 (tasks, task_steps)
--   - GitOps                (remediation_prs)
--   - Auth                  (sessions)
--   - Realtime              (realtime_connections)
--   - Shared Outbox         (domain_events)
--
-- Dependencies: pgcrypto (for gen_random_uuid)
-- Migrator:     golang-migrate/migrate/v4 with pgx/v5 driver
-- ============================================================================

-- +goose Up
-- +migrate Up

BEGIN;

-- ============================================================================
-- 1. Extension Enablement
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================================
-- 2. Auto-updating timestamp function (shared across all tables)
-- ============================================================================
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 3. Table: workload_snapshots
-- Stores the last-known K8s state for offline/quick-load views.
-- ============================================================================
CREATE TABLE IF NOT EXISTS workload_snapshots (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_name    VARCHAR(255) NOT NULL,
    namespace       VARCHAR(255) NOT NULL,
    resource_type   VARCHAR(50)  NOT NULL,   -- 'pod', 'deployment', 'service'
    resource_name   VARCHAR(255) NOT NULL,
    resource_json   JSONB        NOT NULL DEFAULT '{}',
    labels          JSONB        NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ           -- soft delete
);

-- Index: composite for namespace-scoped lookups
CREATE INDEX IF NOT EXISTS idx_wkl_snap_ns_resource
    ON workload_snapshots(cluster_name, namespace, resource_type);

-- Index: composite for resource-type + name searches
CREATE INDEX IF NOT EXISTS idx_wkl_snap_resource_type_name
    ON workload_snapshots(resource_type, resource_name);

-- Index: filter out soft-deleted rows
CREATE INDEX IF NOT EXISTS idx_wkl_snap_deleted_at
    ON workload_snapshots(deleted_at)
    WHERE deleted_at IS NULL;

CREATE TRIGGER trg_workload_snapshots_updated_at
    BEFORE UPDATE ON workload_snapshots
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- 4. Table: pod_log_streams
-- Tracks active log stream sessions (PooledStreamManager).
-- ============================================================================
CREATE TABLE IF NOT EXISTS pod_log_streams (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_name      VARCHAR(255) NOT NULL,
    namespace         VARCHAR(255) NOT NULL,
    pod_name          VARCHAR(255) NOT NULL,
    container_name    VARCHAR(255) NOT NULL,
    tail_lines        INT          NOT NULL DEFAULT 100,
    status            VARCHAR(20)  NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'closed', 'error')),
    opened_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    last_activity_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    closed_at         TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_pod_log_streams_status
    ON pod_log_streams(status);

CREATE INDEX IF NOT EXISTS idx_pod_log_streams_last_activity
    ON pod_log_streams(last_activity_at)
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_pod_log_streams_pod
    ON pod_log_streams(cluster_name, namespace, pod_name);

CREATE TRIGGER trg_pod_log_streams_updated_at
    BEFORE UPDATE ON pod_log_streams
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- 5. Table: diagnostic_requests
-- Two-phase diagnostics: K8s scan phase + AI analysis phase.
-- ============================================================================
CREATE TABLE IF NOT EXISTS diagnostic_requests (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_name      VARCHAR(255) NOT NULL,
    namespace         VARCHAR(255),   -- nullable for cluster-scoped diagnostics
    resource_selector JSONB NOT NULL DEFAULT '{}',
    scan_status       VARCHAR(30) NOT NULL DEFAULT 'pending'
                      CHECK (scan_status IN ('pending', 'scanning', 'scan_complete', 'analyzing', 'completed', 'failed')),
    analysis_status   VARCHAR(30),
    scan_result       JSONB,
    analysis_result   JSONB,
    cost_budget_cents INT          NOT NULL DEFAULT 500,
    actual_cost_cents INT,
    scheduled_at      TIMESTAMPTZ,
    completed_at      TIMESTAMPTZ,
    error             TEXT,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_diag_req_scan_status
    ON diagnostic_requests(scan_status);

CREATE INDEX IF NOT EXISTS idx_diag_req_cluster
    ON diagnostic_requests(cluster_name, created_at DESC);

CREATE TRIGGER trg_diagnostic_requests_updated_at
    BEFORE UPDATE ON diagnostic_requests
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- 6. Table: agent_workflows
-- State machine for Agent Creation Wizard.
-- ============================================================================
CREATE TABLE IF NOT EXISTS agent_workflows (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                     VARCHAR(255) NOT NULL,
    workflow_type            VARCHAR(50)  NOT NULL DEFAULT 'agent_creation'
                             CHECK (workflow_type IN ('agent_creation')),
    state                    VARCHAR(50)  NOT NULL DEFAULT 'draft'
                             CHECK (state IN (
                                 'draft', 'policy_pending', 'policy_validating',
                                 'policy_failed', 'pending_approval', 'approved',
                                 'rejected', 'deploying', 'deployed', 'failed'
                             )),
    payload                  JSONB NOT NULL DEFAULT '{}',
    mcp_policy               JSONB,
    policy_validation_result JSONB,
    approval_token           VARCHAR(255),
    approved_by              VARCHAR(255),
    approved_at              TIMESTAMPTZ,
    created_by               VARCHAR(255) NOT NULL,
    version                  INT          NOT NULL DEFAULT 1,
    created_at               TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at               TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_agent_wf_state
    ON agent_workflows(state);

CREATE INDEX IF NOT EXISTS idx_agent_wf_created_by
    ON agent_workflows(created_by);

CREATE INDEX IF NOT EXISTS idx_agent_wf_created_at
    ON agent_workflows(created_at DESC);

CREATE TRIGGER trg_agent_workflows_updated_at
    BEFORE UPDATE ON agent_workflows
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- 7. Table: agent_workflow_events
-- Event sourcing / state transition log for agent workflows.
-- ============================================================================
CREATE TABLE IF NOT EXISTS agent_workflow_events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workflow_id UUID NOT NULL REFERENCES agent_workflows(id) ON DELETE CASCADE,
    from_state  VARCHAR(50),
    to_state    VARCHAR(50),
    event_type  VARCHAR(100) NOT NULL,
    metadata    JSONB NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_agent_wf_events_workflow
    ON agent_workflow_events(workflow_id, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_agent_wf_events_type
    ON agent_workflow_events(event_type);

-- ============================================================================
-- 8. Table: cost_metrics
-- Materialized cost data (FINOPS-01 CQRS Read Model).
-- ============================================================================
CREATE TABLE IF NOT EXISTS cost_metrics (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_name   VARCHAR(255)  NOT NULL,
    namespace      VARCHAR(255)  NOT NULL,
    resource_type  VARCHAR(50)   NOT NULL,
    resource_name  VARCHAR(255)  NOT NULL,
    metric_name    VARCHAR(255)  NOT NULL,   -- 'cpu_cost', 'memory_cost', 'storage_cost', 'network_cost'
    metric_value   NUMERIC(20,6) NOT NULL,
    currency       VARCHAR(3)    NOT NULL DEFAULT 'USD',
    interval_start TIMESTAMPTZ   NOT NULL,
    interval_end   TIMESTAMPTZ   NOT NULL,
    labels         JSONB         NOT NULL DEFAULT '{}',
    ingested_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cost_metrics_cluster_interval
    ON cost_metrics(cluster_name, interval_start, interval_end);

CREATE INDEX IF NOT EXISTS idx_cost_metrics_metric_interval
    ON cost_metrics(metric_name, interval_start);

CREATE INDEX IF NOT EXISTS idx_cost_metrics_namespace
    ON cost_metrics(cluster_name, namespace, metric_name);

-- ============================================================================
-- 9. Table: cost_anomalies
-- Anomaly detection results (FINOPS-02).
-- ============================================================================
CREATE TABLE IF NOT EXISTS cost_anomalies (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_name     VARCHAR(255)  NOT NULL,
    namespace        VARCHAR(255)  NOT NULL,
    resource_name    VARCHAR(255)  NOT NULL,
    metric_name      VARCHAR(255)  NOT NULL,
    baseline_value   NUMERIC(20,6) NOT NULL,
    observed_value   NUMERIC(20,6) NOT NULL,
    deviation_pct    NUMERIC(10,4) NOT NULL,
    severity         VARCHAR(20)   NOT NULL
                     CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    detected_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    acknowledged     BOOLEAN       NOT NULL DEFAULT FALSE,
    acknowledged_by  VARCHAR(255),
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cost_anomalies_severity
    ON cost_anomalies(severity, detected_at DESC);

CREATE INDEX IF NOT EXISTS idx_cost_anomalies_acknowledged
    ON cost_anomalies(acknowledged)
    WHERE acknowledged = FALSE;

CREATE INDEX IF NOT EXISTS idx_cost_anomalies_cluster
    ON cost_anomalies(cluster_name, detected_at DESC);

-- ============================================================================
-- 10. Table: budget_alerts
-- Budget threshold alerts (FINOPS-03).
-- ============================================================================
CREATE TABLE IF NOT EXISTS budget_alerts (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster_name       VARCHAR(255) NOT NULL,
    namespace          VARCHAR(255),
    budget_cents       INT          NOT NULL,
    spent_cents        INT          NOT NULL,
    threshold_pct      NUMERIC(5,2) NOT NULL,
    status             VARCHAR(20)  NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active', 'triggered', 'resolved')),
    triggered_at       TIMESTAMPTZ,
    resolved_at        TIMESTAMPTZ,
    notification_sent  BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_budget_alerts_status
    ON budget_alerts(status);

CREATE INDEX IF NOT EXISTS idx_budget_alerts_cluster
    ON budget_alerts(cluster_name, status);

-- ============================================================================
-- 11. Table: notification_preferences
-- JSONB bitfield-based preferences per user+channel (NOTIFICATIONS-01).
-- ============================================================================
CREATE TABLE IF NOT EXISTS notification_preferences (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             VARCHAR(255) NOT NULL,
    channel             VARCHAR(20)  NOT NULL
                        CHECK (channel IN ('email', 'slack', 'web', 'pagerduty')),
    preferences_bitfield BIGINT      NOT NULL DEFAULT 0,
    preferences_json     JSONB       NOT NULL DEFAULT '{}',
    muted_until         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, channel)
);

CREATE INDEX IF NOT EXISTS idx_notification_prefs_user
    ON notification_preferences(user_id);

CREATE TRIGGER trg_notification_preferences_updated_at
    BEFORE UPDATE ON notification_preferences
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- 12. Table: tasks
-- Task with metadata and polymorphic resource linking (TASKS-01).
-- ============================================================================
CREATE TABLE IF NOT EXISTS tasks (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title         VARCHAR(500) NOT NULL,
    description   TEXT,
    status        VARCHAR(30)  NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'in_progress', 'completed', 'failed', 'cancelled')),
    created_by    VARCHAR(255) NOT NULL,
    assigned_to   VARCHAR(255),
    resource_type VARCHAR(100),    -- polymorphic link type
    resource_id   VARCHAR(255),    -- polymorphic link ID
    metadata      JSONB NOT NULL DEFAULT '{}',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tasks_status
    ON tasks(status);

CREATE INDEX IF NOT EXISTS idx_tasks_assigned_to
    ON tasks(assigned_to)
    WHERE assigned_to IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tasks_resource
    ON tasks(resource_type, resource_id)
    WHERE resource_type IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tasks_created_at
    ON tasks(created_at DESC);

CREATE TRIGGER trg_tasks_updated_at
    BEFORE UPDATE ON tasks
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- 13. Table: task_steps
-- Individual checklist steps within a task (TASKS-02).
-- ============================================================================
CREATE TABLE IF NOT EXISTS task_steps (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id     UUID         NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    step_order  INT          NOT NULL,
    title       VARCHAR(500) NOT NULL,
    status      VARCHAR(30)  NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'in_progress', 'completed', 'failed', 'skipped')),
    depends_on  UUID         REFERENCES task_steps(id) ON DELETE SET NULL,
    metadata    JSONB        NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE(task_id, step_order)
);

CREATE INDEX IF NOT EXISTS idx_task_steps_task
    ON task_steps(task_id, step_order);

CREATE INDEX IF NOT EXISTS idx_task_steps_depends
    ON task_steps(depends_on)
    WHERE depends_on IS NOT NULL;

CREATE TRIGGER trg_task_steps_updated_at
    BEFORE UPDATE ON task_steps
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- 14. Table: remediation_prs
-- Remediation PR service — Anti-Corruption Layer (GITOPS-01/02).
-- ============================================================================
CREATE TABLE IF NOT EXISTS remediation_prs (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source       VARCHAR(50)  NOT NULL
                 CHECK (source IN ('diagnostics', 'finops')),
    source_id    UUID         NOT NULL,
    title        VARCHAR(500) NOT NULL,
    description  TEXT,
    branch_name  VARCHAR(255) NOT NULL,
    pr_url       VARCHAR(1000),
    pr_status    VARCHAR(30)  NOT NULL DEFAULT 'draft'
                 CHECK (pr_status IN ('draft', 'open', 'merged', 'closed', 'failed')),
    diff_json    JSONB        NOT NULL DEFAULT '[]',
    created_by   VARCHAR(255) NOT NULL,
    reviewers    TEXT[]       NOT NULL DEFAULT '{}',
    approved     BOOLEAN      NOT NULL DEFAULT FALSE,
    merged_at    TIMESTAMPTZ,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_remediation_prs_source
    ON remediation_prs(source, source_id);

CREATE INDEX IF NOT EXISTS idx_remediation_prs_status
    ON remediation_prs(pr_status);

CREATE INDEX IF NOT EXISTS idx_remediation_prs_created_by
    ON remediation_prs(created_by);

-- Note: source_id is polymorphic (references diagnostic_requests or cost_anomalies)
-- and cannot have a single FK constraint. Application enforces referential integrity.

CREATE TRIGGER trg_remediation_prs_updated_at
    BEFORE UPDATE ON remediation_prs
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- ============================================================================
-- 15. Table: sessions
-- Multi-provider session management (AUTH-01).
-- ============================================================================
CREATE TABLE IF NOT EXISTS sessions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             VARCHAR(255) NOT NULL,
    provider            VARCHAR(30)  NOT NULL
                        CHECK (provider IN ('password', 'biometric', 'tailscale')),
    provider_session_id VARCHAR(500),
    token_hash          VARCHAR(255) NOT NULL,
    refresh_token_hash  VARCHAR(255),
    expires_at          TIMESTAMPTZ  NOT NULL,
    last_used_at        TIMESTAMPTZ,
    revoked             BOOLEAN      NOT NULL DEFAULT FALSE,
    metadata            JSONB        NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sessions_user_id
    ON sessions(user_id);

CREATE INDEX IF NOT EXISTS idx_sessions_token_hash
    ON sessions(token_hash);

CREATE INDEX IF NOT EXISTS idx_sessions_active
    ON sessions(user_id, expires_at DESC)
    WHERE revoked = FALSE;

CREATE INDEX IF NOT EXISTS idx_sessions_expires
    ON sessions(expires_at)
    WHERE revoked = FALSE;

-- ============================================================================
-- 16. Table: realtime_connections
-- WebSocket connection tracking for chunked snapshot sync (REALTIME-01).
-- ============================================================================
CREATE TABLE IF NOT EXISTS realtime_connections (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           VARCHAR(255),
    connection_id     VARCHAR(255) NOT NULL,
    snapshot_token    VARCHAR(255),
    cursor            VARCHAR(255),
    page_size         INT          NOT NULL DEFAULT 50,
    resource_filters  JSONB        NOT NULL DEFAULT '{}',
    status            VARCHAR(20)  NOT NULL DEFAULT 'syncing'
                      CHECK (status IN ('syncing', 'synced', 'error')),
    connected_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    disconnected_at   TIMESTAMPTZ,
    last_heartbeat    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rt_connections_user
    ON realtime_connections(user_id);

CREATE INDEX IF NOT EXISTS idx_rt_connections_connection
    ON realtime_connections(connection_id);

CREATE INDEX IF NOT EXISTS idx_rt_connections_status
    ON realtime_connections(status);

CREATE INDEX IF NOT EXISTS idx_rt_connections_heartbeat
    ON realtime_connections(last_heartbeat)
    WHERE status = 'syncing';

-- ============================================================================
-- 17. Table: domain_events
-- Shared outbox for reliable CloudEvents publishing.
-- ============================================================================
CREATE TABLE IF NOT EXISTS domain_events (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id                VARCHAR(255) NOT NULL UNIQUE,
    event_type              VARCHAR(255) NOT NULL,
    event_source            VARCHAR(255) NOT NULL,
    event_spec_version      VARCHAR(10)  NOT NULL DEFAULT '1.0',
    event_data              JSONB        NOT NULL DEFAULT '{}',
    event_data_content_type VARCHAR(100) NOT NULL DEFAULT 'application/json',
    subject                 VARCHAR(255),
    aggregate_type          VARCHAR(100),
    aggregate_id            VARCHAR(255),
    published               BOOLEAN      NOT NULL DEFAULT FALSE,
    published_at            TIMESTAMPTZ,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Composite index for outbox polling: find unpublished events in order
CREATE INDEX IF NOT EXISTS idx_domain_events_outbox
    ON domain_events(published, created_at ASC)
    WHERE published = FALSE;

CREATE INDEX IF NOT EXISTS idx_domain_events_aggregate
    ON domain_events(aggregate_type, aggregate_id);

CREATE INDEX IF NOT EXISTS idx_domain_events_type
    ON domain_events(event_type);

-- ============================================================================
-- 18. Foreign Key: agent_workflow_events -> agent_workflows
-- (declared inline above, but listing for clarity)
-- ============================================================================
-- agent_workflow_events.workflow_id -> agent_workflows(id) ON DELETE CASCADE

-- ============================================================================
-- 19. Foreign Key: task_steps -> tasks
-- (declared inline above)
-- ============================================================================
-- task_steps.task_id -> tasks(id) ON DELETE CASCADE
-- task_steps.depends_on -> task_steps(id) ON DELETE SET NULL

COMMIT;

-- ============================================================================
-- DOWN MIGRATION
-- ============================================================================
-- +migrate Down
-- +goose Down

BEGIN;

DROP TRIGGER IF EXISTS trg_workload_snapshots_updated_at    ON workload_snapshots;
DROP TRIGGER IF EXISTS trg_pod_log_streams_updated_at       ON pod_log_streams;
DROP TRIGGER IF EXISTS trg_diagnostic_requests_updated_at   ON diagnostic_requests;
DROP TRIGGER IF EXISTS trg_agent_workflows_updated_at       ON agent_workflows;
DROP TRIGGER IF EXISTS trg_notification_preferences_updated_at ON notification_preferences;
DROP TRIGGER IF EXISTS trg_tasks_updated_at                 ON tasks;
DROP TRIGGER IF EXISTS trg_task_steps_updated_at            ON task_steps;
DROP TRIGGER IF EXISTS trg_remediation_prs_updated_at       ON remediation_prs;

DROP TABLE IF EXISTS domain_events          CASCADE;
DROP TABLE IF EXISTS realtime_connections   CASCADE;
DROP TABLE IF EXISTS sessions               CASCADE;
DROP TABLE IF EXISTS remediation_prs        CASCADE;
DROP TABLE IF EXISTS task_steps             CASCADE;
DROP TABLE IF EXISTS tasks                  CASCADE;
DROP TABLE IF EXISTS notification_preferences CASCADE;
DROP TABLE IF EXISTS budget_alerts          CASCADE;
DROP TABLE IF EXISTS cost_anomalies         CASCADE;
DROP TABLE IF EXISTS cost_metrics           CASCADE;
DROP TABLE IF EXISTS agent_workflow_events  CASCADE;
DROP TABLE IF EXISTS agent_workflows        CASCADE;
DROP TABLE IF EXISTS diagnostic_requests    CASCADE;
DROP TABLE IF EXISTS pod_log_streams        CASCADE;
DROP TABLE IF EXISTS workload_snapshots     CASCADE;

DROP FUNCTION IF EXISTS update_modified_column();

COMMIT;
