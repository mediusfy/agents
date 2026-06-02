

-- Seed data for CLUSTERCONNECT-01: Cluster Connections
-- Dependencies: pgcrypto extension, migration 010_clusterconnect_01_cluster_connections.sql
--
-- This seed script populates:
--   1. Cloud provider reference data (GKE, EKS, AKS, self-managed)
--   2. Sample cluster connections
--   3. Sample tags and groups
--   4. Sample health history entries
--   5. Sample audit log entries

BEGIN;

-- ============================================================
-- 1. Cloud Providers
-- ============================================================
INSERT INTO cloud_providers (id, name, display_name, description, is_active) VALUES
    ('a0000000-0000-4000-8000-000000000001', 'gke',  'Google Kubernetes Engine',     'Google Cloud GKE managed Kubernetes',                   TRUE),
    ('a0000000-0000-4000-8000-000000000002', 'eks',  'Amazon Elastic Kubernetes Service', 'AWS EKS managed Kubernetes',                        TRUE),
    ('a0000000-0000-4000-8000-000000000003', 'aks',  'Azure Kubernetes Service',     'Microsoft Azure AKS managed Kubernetes',                 TRUE),
    ('a0000000-0000-4000-8000-000000000004', 'self-managed', 'Self-Managed Kubernetes', 'On-premises or VM-based self-managed K8s cluster', TRUE),
    ('a0000000-0000-4000-8000-000000000005', 'other', 'Other / Custom',               'Custom or unsupported provider',                        TRUE)
ON CONFLICT (name) DO NOTHING;

-- ============================================================
-- 2. Cluster Connections
-- ============================================================
INSERT INTO cluster_connections (id, tenant_id, name, description, api_endpoint, connection_status, cloud_provider_id, cluster_version, region, environment, is_active, has_valid_credentials, metadata) VALUES
    (
        'b0000000-0000-4000-8000-000000000001',
        't0000000-0000-4000-8000-000000000001',
        'production-gke-uscentral1',
        'Primary production cluster hosting customer-facing workloads',
        'https://34.123.45.67',
        'connected',
        'a0000000-0000-4000-8000-000000000001',
        '1.28.5-gke.2000',
        'us-central1',
        'production',
        TRUE, TRUE,
        '{"project": "rufkis-prod", "cluster_name": "prod-cluster-1", "node_pool_count": 5}'
    ),
    (
        'b0000000-0000-4000-8000-000000000002',
        't0000000-0000-4000-8000-000000000001',
        'staging-eks-euwest1',
        'Staging cluster for pre-production validation',
        'https://api.eks.eu-west-1.amazonaws.com',
        'connected',
        'a0000000-0000-4000-8000-000000000002',
        '1.27.10-eks',
        'eu-west-1',
        'staging',
        TRUE, TRUE,
        '{"account_id": "123456789012", "cluster_name": "staging-cluster"}'
    ),
    (
        'b0000000-0000-4000-8000-000000000003',
        't0000000-0000-4000-8000-000000000001',
        'dev-aks-eastus',
        'Development cluster for engineering team',
        'https://dev-cluster.eastus.azmk8s.io',
        'connecting',
        'a0000000-0000-4000-8000-000000000003',
        '1.28.3',
        'eastus',
        'development',
        TRUE, FALSE,
        '{"subscription_id": "sub-abc-123", "resource_group": "rg-rufkis-dev"}'
    ),
    (
        'b0000000-0000-4000-8000-000000000004',
        't0000000-0000-4000-8000-000000000002',
        'on-prem-prod',
        'On-premises production cluster in DC-1',
        'https://k8s-api.dc1.example.com:6443',
        'disconnected',
        'a0000000-0000-4000-8000-000000000004',
        '1.26.7',
        'dc-1',
        'production',
        FALSE, FALSE,
        '{"datacenter": "DC-1", "rack": "R04", "provisioner": "kubespray"}'
    ),
    (
        'b0000000-0000-4000-8000-000000000005',
        't0000000-0000-4000-8000-000000000001',
        'prod-canary-gke',
        'Canary cluster for gradual production rollouts',
        'https://canary.k8s.rufkis.io',
        'unknown',
        'a0000000-0000-4000-8000-000000000001',
        '1.29.0-gke.1000',
        'us-west1',
        'production',
        TRUE, TRUE,
        '{"project": "rufkis-prod", "cluster_name": "canary-cluster"}'
    )
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- 3. Cluster Tags
-- ============================================================
INSERT INTO cluster_tags (cluster_id, tag_key, tag_value) VALUES
    ('b0000000-0000-4000-8000-000000000001', 'team',          'platform-eng'),
    ('b0000000-0000-4000-8000-000000000001', 'tier',          'critical'),
    ('b0000000-0000-4000-8000-000000000001', 'cost-center',   'cc-prod-001'),
    ('b0000000-0000-4000-8000-000000000002', 'team',          'platform-eng'),
    ('b0000000-0000-4000-8000-000000000002', 'tier',          'staging'),
    ('b0000000-0000-4000-8000-000000000003', 'team',          'backend-team'),
    ('b0000000-0000-4000-8000-000000000003', 'tier',          'dev'),
    ('b0000000-0000-4000-8000-000000000003', 'owner',         'alice@rufkis.io'),
    ('b0000000-0000-4000-8000-000000000004', 'team',          'infra-ops'),
    ('b0000000-0000-4000-8000-000000000004', 'tier',          'critical'),
    ('b0000000-0000-4000-8000-000000000005', 'team',          'sre-team'),
    ('b0000000-0000-4000-8000-000000000005', 'tier',          'canary')
ON CONFLICT (cluster_id, tag_key) DO NOTHING;

-- ============================================================
-- 4. Cluster Groups
-- ============================================================
INSERT INTO cluster_groups (id, tenant_id, name, description, color) VALUES
    ('c0000000-0000-4000-8000-000000000001', 't0000000-0000-4000-8000-000000000001', 'Production Fleet',    'All production clusters',       '#E53935'),
    ('c0000000-0000-4000-8000-000000000002', 't0000000-0000-4000-8000-000000000001', 'Non-Prod',            'Staging and development clusters', '#43A047'),
    ('c0000000-0000-4000-8000-000000000003', 't0000000-0000-4000-8000-000000000001', 'GKE Clusters',        'All Google Kubernetes Engine clusters', '#1A73E8'),
    ('c0000000-0000-4000-8000-000000000004', 't0000000-0000-4000-8000-000000000002', 'On-Prem Critical',    'On-premises clusters requiring immediate attention', '#FB8C00')
ON CONFLICT (tenant_id, name) DO NOTHING;

-- ============================================================
-- 5. Cluster Group Members
-- ============================================================
INSERT INTO cluster_group_members (cluster_id, group_id) VALUES
    ('b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001'),  -- prod-gke → Production Fleet
    ('b0000000-0000-4000-8000-000000000005', 'c0000000-0000-4000-8000-000000000001'),  -- prod-canary → Production Fleet
    ('b0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000003'),  -- prod-gke → GKE Clusters
    ('b0000000-0000-4000-8000-000000000005', 'c0000000-0000-4000-8000-000000000003'),  -- prod-canary → GKE Clusters
    ('b0000000-0000-4000-8000-000000000002', 'c0000000-0000-4000-8000-000000000002'),  -- staging-eks → Non-Prod
    ('b0000000-0000-4000-8000-000000000003', 'c0000000-0000-4000-8000-000000000002'),  -- dev-aks → Non-Prod
    ('b0000000-0000-4000-8000-000000000004', 'c0000000-0000-4000-8000-000000000004')   -- on-prem-prod → On-Prem Critical
ON CONFLICT DO NOTHING;

-- ============================================================
-- 6. Cluster Health History
-- ============================================================
INSERT INTO cluster_health_history (cluster_id, connection_status, latency_ms, checked_at) VALUES
    ('b0000000-0000-4000-8000-000000000001', 'connected',    12,  NOW() - INTERVAL '10 minutes'),
    ('b0000000-0000-4000-8000-000000000001', 'connected',    14,  NOW() - INTERVAL '5 minutes'),
    ('b0000000-0000-4000-8000-000000000001', 'connected',    11,  NOW()),
    ('b0000000-0000-4000-8000-000000000002', 'connected',    28,  NOW() - INTERVAL '2 minutes'),
    ('b0000000-0000-4000-8000-000000000002', 'connected',    31,  NOW()),
    ('b0000000-0000-4000-8000-000000000003', 'connecting',   NULL, NOW() - INTERVAL '1 minute'),
    ('b0000000-0000-4000-8000-000000000004', 'disconnected', NULL, NOW() - INTERVAL '30 minutes'),
    ('b0000000-0000-4000-8000-000000000004', 'error',        NULL, NOW() - INTERVAL '1 hour'),
    ('b0000000-0000-4000-8000-000000000005', 'unknown',      NULL, NOW() - INTERVAL '15 minutes');

-- ============================================================
-- 7. Audit Log
-- ============================================================
INSERT INTO cluster_connection_audit_log (cluster_id, tenant_id, action, actor_id, actor_type, changes, ip_address, occurred_at) VALUES
    ('b0000000-0000-4000-8000-000000000001', 't0000000-0000-4000-8000-000000000001',
     'cluster_created',   'a0000000-0000-4000-8000-0000000000aa', 'user',
     '{"name": "production-gke-uscentral1", "api_endpoint": "https://34.123.45.67", "region": "us-central1"}',
     '10.0.0.1'::inet, NOW() - INTERVAL '7 days'),
    ('b0000000-0000-4000-8000-000000000001', 't0000000-0000-4000-8000-000000000001',
     'credentials_rotated', 'a0000000-0000-4000-8000-0000000000bb', 'user',
     '{"action": "rotate_kubeconfig", "previous_key_id": "key-abc", "new_key_id": "key-def"}',
     '10.0.0.2'::inet, NOW() - INTERVAL '2 days'),
    ('b0000000-0000-4000-8000-000000000001', 't0000000-0000-4000-8000-000000000001',
     'connection_tested', 'a0000000-0000-4000-8000-0000000000cc', 'system',
     '{"result": "success", "latency_ms": 12}',
     '10.0.0.3'::inet, NOW() - INTERVAL '10 minutes'),
    ('b0000000-0000-4000-8000-000000000003', 't0000000-0000-4000-8000-000000000001',
     'cluster_created',   'a0000000-0000-4000-8000-0000000000aa', 'user',
     '{"name": "dev-aks-eastus", "api_endpoint": "https://dev-cluster.eastus.azmk8s.io"}',
     '10.0.0.1'::inet, NOW() - INTERVAL '1 day'),
    ('b0000000-0000-4000-8000-000000000004', 't0000000-0000-4000-8000-000000000002',
     'cluster_created',   'a0000000-0000-4000-8000-0000000000dd', 'user',
     '{"name": "on-prem-prod", "api_endpoint": "https://k8s-api.dc1.example.com:6443"}',
     '10.0.1.1'::inet, NOW() - INTERVAL '30 days');

COMMIT;
