-- Migration 002: Cost Saving Actions
-- Tracks remediation actions taken against waste observations.

CREATE TABLE IF NOT EXISTS cost_saving_actions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    waste_observation_id UUID NOT NULL REFERENCES waste_observations(id) ON DELETE CASCADE,
    action_type TEXT NOT NULL CHECK (action_type IN ('pr_rightsize', 'pr_remove', 'pr_scaledown', 'dismiss', 'manual')),
    target_kind VARCHAR(100),
    target_name VARCHAR(255),
    recommended_savings_cents BIGINT NOT NULL DEFAULT 0,
    pr_url TEXT,
    pr_status TEXT NOT NULL DEFAULT 'pending' CHECK (pr_status IN ('pending', 'open', 'merged', 'closed', 'failed')),
    applied_at TIMESTAMPTZ,
    rollback_manifest JSONB,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_cost_saving_actions_waste_obs ON cost_saving_actions (waste_observation_id);
CREATE INDEX idx_cost_saving_actions_pr_status ON cost_saving_actions (pr_status);
CREATE INDEX idx_cost_saving_actions_applied_at ON cost_saving_actions (applied_at DESC);

-- Updated_at trigger
CREATE TRIGGER trg_cost_saving_actions_updated_at
    BEFORE UPDATE ON cost_saving_actions
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Down migration
-- DROP TABLE IF EXISTS cost_saving_actions;
-- DROP TABLE IF EXISTS waste_observations;
-- DROP FUNCTION IF EXISTS update_updated_at_column();
