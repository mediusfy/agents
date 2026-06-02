

-- =============================================================================
-- Seed Data: CLUSTER-01 ClusterConnect
-- Description: Inserts reference data and sample cluster connections for
--   development and testing environments.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Seed cloud_providers (idempotent)
-- ---------------------------------------------------------------------------
INSERT INTO cloud_providers (id, name, display_name, logo_url) VALUES
    (1,  'AWS',       'Amazon Web Services',   NULL),
    (2,  'GCP',       'Google Cloud Platform', NULL),
    (3,  'Azure',     'Microsoft Azure',       NULL),
    (4,  'On-Prem',   'On-Premises / Self-Managed', NULL),
    (5,  'Other',     'Other Provider',        NULL)
ON CONFLICT (name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Seed cluster_groups (idempotent)
-- ---------------------------------------------------------------------------
INSERT INTO cluster_groups (id, name, description, color, region) VALUES
    (gen_random_uuid(), 'Production',  'Production workloads',       '#E53935', NULL),
    (gen_random_uuid(), 'Staging',     'Staging / pre-prod',         '#FB8C00', NULL),
    (gen_random_uuid(), 'Development', 'Development environments',   '#43A047', NULL),
    (gen_random_uuid(), 'EU-West',     'European west region',       '#1E88E5', 'eu-west-1'),
    (gen_random_uuid(), 'US-East',     'US east coast region',       '#3949AB', 'us-east-1'),
    (gen_random_uuid(), 'US-West',     'US west coast region',       '#8E24AA', 'us-west-2')
ON CONFLICT (name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Seed sample cluster_connections (for development)
-- ---------------------------------------------------------------------------
-- These are example clusters. In production, SREs add their own clusters.
-- Example entries demonstrating multi-cloud setup:

-- AWS EKS
INSERT INTO cluster_connections (id, cluster_name, display_name, cloud_provider_id, region,
    api_server_endpoint, kubernetes_version, connection_status, notes, metadata)
VALUES
    (gen_random_uuid(), 'eks-prod-us-east-1', 'EKS Production (US-East)', 1, 'us-east-1',
     'https://XXXXXXXXXXXX.gr7.us-east-1.eks.amazonaws.com', '1.29',
     'disconnected',
     'Primary production cluster for customer-facing services',
     '{"environment": "production", "node_count": 12, "instance_type": "m5.xlarge"}'::jsonb),
    (gen_random_uuid(), 'eks-staging-eu-west-1', 'EKS Staging (EU-West)', 1, 'eu-west-1',
     'https://XXXXXXXXXXXX.gr7.eu-west-1.eks.amazonaws.com', '1.28',
     'disconnected',
     'Staging environment for European region testing',
     '{"environment": "staging", "node_count": 4, "instance_type": "t3.medium"}'::jsonb)
ON CONFLICT (cloud_provider_id, cluster_name) DO NOTHING;

-- GCP GKE
INSERT INTO cluster_connections (id, cluster_name, display_name, cloud_provider_id, region,
    api_server_endpoint, kubernetes_version, connection_status, notes, metadata)
VALUES
    (gen_random_uuid(), 'gke-prod-us-central1', 'GKE Production (US-Central)', 2, 'us-central1',
     'https://XXXXXXXXXXXX.us-central1.gke.googleapis.com', '1.29',
     'disconnected',
     'GKE cluster for ML workloads',
     '{"environment": "production", "node_count": 8, "instance_type": "n2-standard-8"}'::jsonb)
ON CONFLICT (cloud_provider_id, cluster_name) DO NOTHING;

-- Azure AKS
INSERT INTO cluster_connections (id, cluster_name, display_name, cloud_provider_id, region,
    api_server_endpoint, kubernetes_version, connection_status, notes, metadata)
VALUES
    (gen_random_uuid(), 'aks-dev-westus2', 'AKS Development (West US 2)', 3, 'westus2',
     'https://XXXXXXXXXXXX.westus2.azmk8s.io', '1.28',
     'disconnected',
     'Development cluster for Azure-based services',
     '{"environment": "development", "node_count": 3, "instance_type": "Standard_D4s_v3"}'::jsonb)
ON CONFLICT (cloud_provider_id, cluster_name) DO NOTHING;

-- On-Prem
INSERT INTO cluster_connections (id, cluster_name, display_name, cloud_provider_id, region,
    api_server_endpoint, kubernetes_version, connection_status, notes, metadata)
VALUES
    (gen_random_uuid(), 'onprem-dc1-prod', 'On-Prem DataCenter 1', 4, 'us-east-1',
     'https://k8s-api.dc1.example.com:6443', '1.27',
     'disconnected',
     'On-premises cluster in primary datacenter',
     '{"environment": "production", "node_count": 6, "provider": "vmware"}'::jsonb)
ON CONFLICT (cloud_provider_id, cluster_name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Seed sample cluster_tags
-- ---------------------------------------------------------------------------
-- Tags are added by the application layer via the API. Seed data is for dev.
-- Example tags would include:
--   key='team', value='platform-engineering'
--   key='tier', value='critical'
--   key='compliance', value='PCI-DSS'

-- ---------------------------------------------------------------------------
-- Seed sample health history
-- ---------------------------------------------------------------------------
-- Health history is populated by the health-check scheduler, not seeded.

COMMIT;
