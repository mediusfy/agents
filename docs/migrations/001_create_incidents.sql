-- Migration: 001_create_incidents_table
-- Description: Rufkis SRE Platform - Incidents table (Domain 3: Autonomous Triage)
-- This is the core entity for incident management across the platform.

-- UP
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Enum types
DO $$ BEGIN
    CREATE TYPE incident_severity AS ENUM ('SEV0', 'SEV1', 'SEV2', 'SEV3', 'SEV4', 'UNKNOWN');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE incident_status AS ENUM (
        'Detected', 'Acknowledged', 'TriageInProgress', 'Investigating',
        'Remediating', 'Monitoring', 'Resolved', 'Closed', 'FalsePositive'
    );
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE incident_source AS ENUM (
        'Datadog', 'Prometheus', 'PagerDuty', 'CloudWatch', 'Grafana',
        'UserReport', 'SyntheticCheck', 'AgentTriage', 'OpsGenie', 'Slack', 'Webhook', 'Other'
    );
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- Main table
CREATE TABLE IF NOT EXISTS incidents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id     VARCHAR(255),
    title           VARCHAR(512) NOT NULL,
    description     TEXT,
    severity        incident_severity NOT NULL DEFAULT 'UNKNOWN',
    status          incident_status NOT NULL DEFAULT 'Detected',
    source          incident_source NOT NULL,
    source_event_id VARCHAR(255),
    service_id      UUID,
    service_name    VARCHAR(255),
    environment     JSONB,                         -- EnvironmentRef as JSON
    classification  JSONB,                         -- IncidentClassification as JSON
    rca_summary     JSONB,                         -- RCASummary as JSON
    assigned_to     UUID,
    escalation_policy_id UUID,
    remediation_execution_id UUID,
    workspace_id    UUID NOT NULL,
    tags            TEXT[] DEFAULT '{}',
    detected_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    acknowledged_at TIMESTAMPTZ,
    resolved_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- FK placeholders (create after workspace/services tables exist)
    -- CONSTRAINT fk_incidents_workspace FOREIGN KEY (workspace_id) REFERENCES workspaces(id),
    -- CONSTRAINT fk_incidents_service FOREIGN KEY (service_id) REFERENCES services(id),
    -- CONSTRAINT fk_incidents_assigned_to FOREIGN KEY (assigned_to) REFERENCES users(id),
    -- CONSTRAINT fk_incidents_escalation_policy FOREIGN KEY (escalation_policy_id) REFERENCES escalation_policies(id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_incidents_workspace_status ON incidents(workspace_id, status);
CREATE INDEX IF NOT EXISTS idx_incidents_severity_status ON incidents(severity, status);
CREATE INDEX IF NOT EXISTS idx_incidents_service_id ON incidents(service_id);
CREATE INDEX IF NOT EXISTS idx_incidents_detected_at ON incidents(detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_incidents_assigned_to ON incidents(assigned_to);
CREATE INDEX IF NOT EXISTS idx_incidents_tags ON incidents USING GIN(tags);
CREATE INDEX IF NOT EXISTS idx_incidents_environment ON incidents USING GIN(environment jsonb_path_ops);

-- Trigger for updated_at
CREATE TRIGGER update_incidents_modtime
    BEFORE UPDATE ON incidents
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_column();

-- DOWN
DROP TRIGGER IF EXISTS update_incidents_modtime ON incidents;
DROP TABLE IF EXISTS incidents;
DROP TYPE IF EXISTS incident_source;
DROP TYPE IF EXISTS incident_status;
DROP TYPE IF EXISTS incident_severity;
