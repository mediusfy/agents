-- Migration 001: Waste Observations
-- PostgreSQL schema for Automated FinOps ROI (Strategy Theme 2).
-- Tracks resource waste observations from Prometheus metric analysis.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS waste_observations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cluster VARCHAR(255) NOT NULL,
    namespace VARCHAR(255) NOT NULL,
    resource_type VARCHAR(100) NOT NULL CHECK (resource_type IN ('pod', 'deployment', 'statefulset', 'daemonset', 'pvc')),
    workload_name VARCHAR(255) NOT NULL,
    container_name VARCHAR(255),
    current_requests_cpu VARCHAR(50),
    current_requests_memory VARCHAR(50),
    current_limits_cpu VARCHAR(50),
    current_limits_memory VARCHAR(50),
    recommended_requests_cpu VARCHAR(50),
    recommended_requests_memory VARCHAR(50),
    recommended_limits_cpu VARCHAR(50),
    recommended_limits_memory VARCHAR(50),
    monthly_waste_usd_cents BIGINT NOT NULL DEFAULT 0,
    detected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'actioned', 'dismissed', 'resolved')),
    runbook_ref TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for query performance
CREATE INDEX idx_waste_observations_cluster_status ON waste_observations (cluster, status);
CREATE INDEX idx_waste_observations_monthly_waste ON waste_observations (monthly_waste_usd_cents DESC);
CREATE INDEX idx_waste_observations_detected_at ON waste_observations (detected_at DESC);
CREATE INDEX idx_waste_observations_namespace ON waste_observations (namespace);

-- Updated_at trigger function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_waste_observations_updated_at
    BEFORE UPDATE ON waste_observations
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
