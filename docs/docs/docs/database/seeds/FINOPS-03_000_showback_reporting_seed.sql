

-- FINOPS-03: Showback/Show-Charge Reporting — Seed Data
-- =====================================================
-- Seeds reference data: SRE teams, services, providers, regions,
-- allocation tags, data residency rules, and sample cost allocations.

BEGIN;

-- ==========================================================
-- 1. SRE TEAMS
-- ==========================================================
INSERT INTO sre_teams (id, name, description, cost_center_code, is_active) VALUES
    (gen_random_uuid(), 'CloudSRE-Squadron', 'Cloud infrastructure SRE team', 'CC-CLOUD-001', TRUE),
    (gen_random_uuid(), 'K8s-SRE', 'Kubernetes platform SRE team', 'CC-K8S-002', TRUE),
    (gen_random_uuid(), 'DataSRE', 'Data platform & analytics SRE team', 'CC-DATA-003', TRUE),
    (gen_random_uuid(), 'NetSRE', 'Network & connectivity SRE team', 'CC-NET-004', TRUE),
    (gen_random_uuid(), 'SecuritySRE', 'Security & compliance SRE team', 'CC-SEC-005', TRUE)
ON CONFLICT (name) DO NOTHING;

-- ==========================================================
-- 2. COST PROVIDERS
-- ==========================================================
INSERT INTO cost_providers (id, name, display_name, logo_url) VALUES
    (gen_random_uuid(), 'AWS', 'Amazon Web Services', 'https://logo.clearbit.com/aws.amazon.com'),
    (gen_random_uuid(), 'Azure', 'Microsoft Azure', 'https://logo.clearbit.com/azure.microsoft.com'),
    (gen_random_uuid(), 'GCP', 'Google Cloud Platform', 'https://logo.clearbit.com/cloud.google.com'),
    (gen_random_uuid(), 'OCI', 'Oracle Cloud Infrastructure', 'https://logo.clearbit.com/oracle.com')
ON CONFLICT (name) DO NOTHING;

-- ==========================================================
-- 3. COST REGIONS (with data residency zones)
-- ==========================================================
-- We need to reference provider IDs. Use a CTE to get them.
WITH provider_ids AS (
    SELECT id, name FROM cost_providers WHERE is_active = TRUE
)
INSERT INTO cost_regions (id, provider_id, region_code, region_name, data_residency_zone)
SELECT gen_random_uuid(), p.id, r.region_code, r.region_name, r.zone
FROM provider_ids p
CROSS JOIN LATERAL (
    VALUES 
        -- AWS Regions
        ('us-east-1',      'US East (N. Virginia)',     'US'),
        ('us-west-2',      'US West (Oregon)',          'US'),
        ('eu-west-1',      'EU West (Ireland)',         'EU'),
        ('eu-central-1',   'EU Central (Frankfurt)',    'EU'),
        ('eu-south-1',     'EU South (Milan)',          'EU'),
        ('ap-southeast-1', 'Asia Pacific (Singapore)',  'APAC'),
        ('ap-northeast-1', 'Asia Pacific (Tokyo)',      'APAC'),
        ('sa-east-1',      'South America (São Paulo)', 'GLOBAL')
) AS r(region_code, region_name, zone)
WHERE (p.name = 'AWS' AND r.region_code LIKE 'us-%' OR r.region_code LIKE 'eu-%' OR r.region_code LIKE 'ap-%' OR r.region_code LIKE 'sa-%')
   OR (p.name = 'Azure' AND r.region_code IN ('us-east-1', 'us-west-2', 'eu-west-1', 'eu-central-1', 'eu-south-1', 'ap-southeast-1', 'ap-northeast-1', 'sa-east-1'))
   OR (p.name = 'GCP' AND r.region_code IN ('us-east-1', 'us-west-2', 'eu-west-1', 'eu-central-1', 'eu-south-1', 'ap-southeast-1', 'ap-northeast-1', 'sa-east-1'))
   OR (p.name = 'OCI' AND r.region_code IN ('us-east-1', 'us-west-2', 'eu-west-1', 'eu-central-1', 'eu-south-1', 'ap-southeast-1', 'ap-northeast-1', 'sa-east-1'))
ON CONFLICT (provider_id, region_code) DO NOTHING;

-- More precise: Let's just seed key regions per provider explicitly
DELETE FROM cost_regions WHERE region_code IS NULL;

-- Actually seed explicitly per provider
INSERT INTO cost_regions (id, provider_id, region_code, region_name, data_residency_zone)
SELECT gen_random_uuid(), cp.id, 'us-east-1', 'US East (N. Virginia)', 'US'
FROM cost_providers cp WHERE cp.name = 'AWS'
ON CONFLICT (provider_id, region_code) DO NOTHING;

INSERT INTO cost_regions (id, provider_id, region_code, region_name, data_residency_zone)
SELECT gen_random_uuid(), cp.id, 'eu-west-1', 'EU West (Ireland)', 'EU'
FROM cost_providers cp WHERE cp.name = 'AWS'
ON CONFLICT (provider_id, region_code) DO NOTHING;

INSERT INTO cost_regions (id, provider_id, region_code, region_name, data_residency_zone)
SELECT gen_random_uuid(), cp.id, 'eu-central-1', 'EU Central (Frankfurt)', 'EU'
FROM cost_providers cp WHERE cp.name = 'AWS'
ON CONFLICT (provider_id, region_code) DO NOTHING;

INSERT INTO cost_regions (id, provider_id, region_code, region_name, data_residency_zone)
SELECT gen_random_uuid(), cp.id, 'ap-southeast-1', 'Asia Pacific (Singapore)', 'APAC'
FROM cost_providers cp WHERE cp.name = 'AWS'
ON CONFLICT (provider_id, region_code) DO NOTHING;

-- Azure regions
INSERT INTO cost_regions (id, provider_id, region_code, region_name, data_residency_zone)
SELECT gen_random_uuid(), cp.id, 'eastus', 'US East', 'US'
FROM cost_providers cp WHERE cp.name = 'Azure'
ON CONFLICT (provider_id, region_code) DO NOTHING;

INSERT INTO cost_regions (id, provider_id, region_code, region_name, data_residency_zone)
SELECT gen_random_uuid(), cp.id, 'westeurope', 'West Europe', 'EU'
FROM cost_providers cp WHERE cp.name = 'Azure'
ON CONFLICT (provider_id, region_code) DO NOTHING;

INSERT INTO cost_regions (id, provider_id, region_code, region_name, data_residency_zone)
SELECT gen_random_uuid(), cp.id, 'northeurope', 'North Europe', 'EU'
FROM cost_providers cp WHERE cp.name = 'Azure'
ON CONFLICT (provider_id, region_code) DO NOTHING;

-- GCP regions
INSERT INTO cost_regions (id, provider_id, region_code, region_name, data_residency_zone)
SELECT gen_random_uuid(), cp.id, 'us-central1', 'US Central (Iowa)', 'US'
FROM cost_providers cp WHERE cp.name = 'GCP'
ON CONFLICT (provider_id, region_code) DO NOTHING;

INSERT INTO cost_regions (id, provider_id, region_code, region_name, data_residency_zone)
SELECT gen_random_uuid(), cp.id, 'europe-west1', 'Europe West (St. Ghislain)', 'EU'
FROM cost_providers cp WHERE cp.name = 'GCP'
ON CONFLICT (provider_id, region_code) DO NOTHING;

INSERT INTO cost_regions (id, provider_id, region_code, region_name, data_residency_zone)
SELECT gen_random_uuid(), cp.id, 'europe-west4', 'Europe West (Netherlands)', 'EU'
FROM cost_providers cp WHERE cp.name = 'GCP'
ON CONFLICT (provider_id, region_code) DO NOTHING;

-- ==========================================================
-- 4. DATA RESIDENCY RULES
-- ==========================================================
INSERT INTO data_residency_rules (id, region_code_pattern, allowed_database_zone, description) VALUES
    (gen_random_uuid(), 'eu-%',      'eu-db', 'All EU-prefixed regions must be stored in EU database cluster'),
    (gen_random_uuid(), 'europe-%',  'eu-db', 'Azure/GCP European regions stored in EU database cluster'),
    (gen_random_uuid(), 'us-%',      'us-db', 'US regions stored in US database cluster'),
    (gen_random_uuid(), '%',         'global-db', 'Default: all other regions stored in global database cluster')
ON CONFLICT (region_code_pattern, allowed_database_zone) DO NOTHING;

-- ==========================================================
-- 5. COST ALLOCATION TAGS (known mappings)
-- ==========================================================
-- Map tags to teams (using team names for readability in seed)
INSERT INTO cost_allocation_tags (id, tag_key, tag_value, sre_team_id, service_id)
SELECT gen_random_uuid(), 'sre-team', 'cloud-sre', st.id, NULL
FROM sre_teams st WHERE st.name = 'CloudSRE-Squadron'
ON CONFLICT (tag_key, tag_value) DO NOTHING;

INSERT INTO cost_allocation_tags (id, tag_key, tag_value, sre_team_id, service_id)
SELECT gen_random_uuid(), 'sre-team', 'k8s-sre', st.id, NULL
FROM sre_teams st WHERE st.name = 'K8s-SRE'
ON CONFLICT (tag_key, tag_value) DO NOTHING;

INSERT INTO cost_allocation_tags (id, tag_key, tag_value, sre_team_id, service_id)
SELECT gen_random_uuid(), 'sre-team', 'data-sre', st.id, NULL
FROM sre_teams st WHERE st.name = 'DataSRE'
ON CONFLICT (tag_key, tag_value) DO NOTHING;

INSERT INTO cost_allocation_tags (id, tag_key, tag_value, sre_team_id, service_id)
SELECT gen_random_uuid(), 'cost-center', 'CC-CLOUD-001', st.id, NULL
FROM sre_teams st WHERE st.name = 'CloudSRE-Squadron'
ON CONFLICT (tag_key, tag_value) DO NOTHING;

INSERT INTO cost_allocation_tags (id, tag_key, tag_value, sre_team_id, service_id)
SELECT gen_random_uuid(), 'environment', 'production', NULL, NULL
ON CONFLICT (tag_key, tag_value) DO NOTHING;

INSERT INTO cost_allocation_tags (id, tag_key, tag_value, sre_team_id, service_id)
SELECT gen_random_uuid(), 'environment', 'staging', NULL, NULL
ON CONFLICT (tag_key, tag_value) DO NOTHING;

COMMIT;
