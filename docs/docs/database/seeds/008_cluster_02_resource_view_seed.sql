-- Seed data: 008_cluster_02_resource_view_seed.sql
-- CLUSTER-02: Unified Cross-Cluster Resource View
-- Populates lookup tables with standard Kubernetes resource types and categories

-- ============================================================================
-- Resource Categories
-- ============================================================================

INSERT INTO cluster_resource_categories (id, name, slug, description, icon, sort_order) VALUES
    (gen_random_uuid(), 'Workloads',       'workloads',       'Running containers and batch jobs',                'cpu',         1),
    (gen_random_uuid(), 'Networking',      'networking',      'Network configuration and connectivity resources',  'network',     2),
    (gen_random_uuid(), 'Storage',         'storage',         'Persistent and ephemeral storage resources',        'storage',     3),
    (gen_random_uuid(), 'Configuration',   'configuration',   'Application configuration and secrets',             'config',      4),
    (gen_random_uuid(), 'RBAC',            'rbac',            'Role-based access control resources',               'shield',      5),
    (gen_random_uuid(), 'Infrastructure',  'infrastructure',  'Cluster infrastructure and node resources',         'server',      6),
    (gen_random_uuid(), 'Autoscaling',     'autoscaling',     'Horizontal and vertical autoscaling resources',     'trending-up', 7),
    (gen_random_uuid(), 'Monitoring',      'monitoring',      'Monitoring, logging, and alerting resources',       'activity',    8),
    (gen_random_uuid(), 'Orchestration',   'orchestration',   'Top-level orchestration and policy resources',      'layers',      9),
    (gen_random_uuid(), 'Batch',           'batch',           'Batch processing and cron job resources',           'clock',      10)
ON CONFLICT (name) DO NOTHING;

-- ============================================================================
-- Resource Types (standard Kubernetes resource types)
-- ============================================================================

-- Insert categories first so we can reference them
WITH cats AS (
    SELECT id, slug FROM cluster_resource_categories
)
INSERT INTO cluster_resource_types (id, category_id, api_group, api_version, resource_kind, resource_name_plural, short_name, namespaced, scope, description)
SELECT
    gen_random_uuid(), c.id, api_group, api_version, kind, plural, short, namespaced, scope, descr
FROM cats c
CROSS JOIN (VALUES
    -- Workloads
    ('Workloads',       '',                   'v1',     'Pod',                  'pods',              'po', TRUE,  'Namespaced',         'A pod is the smallest deployable unit in Kubernetes'),
    ('Workloads',       'apps',               'v1',     'Deployment',           'deployments',       'deploy', TRUE,  'Namespaced',         'Deployment provides declarative updates for Pods'),
    ('Workloads',       'apps',               'v1',     'StatefulSet',          'statefulsets',      'sts', TRUE,  'Namespaced',         'StatefulSet manages stateful applications'),
    ('Workloads',       'apps',               'v1',     'DaemonSet',            'daemonsets',        'ds', TRUE,  'Namespaced',         'DaemonSet ensures all nodes run a copy of a Pod'),
    ('Workloads',       'apps',               'v1',     'ReplicaSet',           'replicasets',       'rs', TRUE,  'Namespaced',         'ReplicaSet maintains a stable set of replica Pods'),
    ('Workloads',       '',                   'v1',     'ReplicationController','replicationcontrollers', 'rc', TRUE,  'Namespaced',    'Ensures a specified number of pod replicas are running'),

    -- Networking
    ('Networking',      '',                   'v1',     'Service',              'services',          'svc', TRUE,  'Namespaced',         'Exposes a network application running in the cluster'),
    ('Networking',      'networking.k8s.io',  'v1',     'Ingress',              'ingresses',         'ing', TRUE,  'Namespaced',         'Manages external access to services'),
    ('Networking',      'networking.k8s.io',  'v1',     'NetworkPolicy',        'networkpolicies',   'netpol', TRUE,  'Namespaced',      'Specifies how groups of pods communicate'),
    ('Networking',      'discovery.k8s.io',   'v1',     'EndpointSlice',        'endpointslices',    NULL, TRUE,  'Namespaced',         'Network endpoints associated with a Service'),
    ('Networking',      '',                   'v1',     'Endpoints',            'endpoints',         'ep', TRUE,  'Namespaced',         'Tracks IP addresses for services'),

    -- Storage
    ('Storage',         '',                   'v1',     'PersistentVolume',     'persistentvolumes', 'pv', FALSE, 'Cluster',             'Provisioned storage in the cluster'),
    ('Storage',         '',                   'v1',     'PersistentVolumeClaim','persistentvolumeclaims', 'pvc', TRUE, 'Namespaced',    'Request for storage by a user'),
    ('Storage',         'storage.k8s.io',     'v1',     'StorageClass',         'storageclasses',    'sc', FALSE, 'Cluster',             'Describes classes of storage'),
    ('Storage',         'snapshot.storage.k8s.io', 'v1', 'VolumeSnapshot',      'volumesnapshots',   'vs', TRUE,  'Namespaced',         'Snapshot of a volume'),
    ('Storage',         'snapshot.storage.k8s.io', 'v1', 'VolumeSnapshotClass', 'volumesnapshotclasses', NULL, FALSE, 'Cluster',       'Describes classes of volume snapshots'),
    ('Storage',         'storage.k8s.io',     'v1',     'CSIDriver',            'csidrivers',        NULL, FALSE, 'Cluster',             'CSI driver installed in the cluster'),

    -- Configuration
    ('Configuration',   '',                   'v1',     'ConfigMap',            'configmaps',        'cm', TRUE,  'Namespaced',         'Configuration data key-value pairs'),
    ('Configuration',   '',                   'v1',     'Secret',               'secrets',           NULL, TRUE,  'Namespaced',         'Sensitive data storage'),
    ('Configuration',   '',                   'v1',     'ServiceAccount',       'serviceaccounts',   'sa', TRUE,  'Namespaced',         'Identity for processes running in a pod'),

    -- RBAC
    ('RBAC',            'rbac.authorization.k8s.io', 'v1', 'Role',               'roles',             NULL, TRUE,  'Namespaced',         'Set of permissions within a namespace'),
    ('RBAC',            'rbac.authorization.k8s.io', 'v1', 'RoleBinding',        'rolebindings',      NULL, TRUE,  'Namespaced',         'Binds roles to users/groups within a namespace'),
    ('RBAC',            'rbac.authorization.k8s.io', 'v1', 'ClusterRole',        'clusterroles',      NULL, FALSE, 'Cluster',             'Cluster-wide set of permissions'),
    ('RBAC',            'rbac.authorization.k8s.io', 'v1', 'ClusterRoleBinding', 'clusterrolebindings', NULL, FALSE, 'Cluster',          'Binds roles cluster-wide'),
    ('RBAC',            '',                   'v1',     'PodSecurityPolicy',     'podsecuritypolicies', 'psp', FALSE, 'Cluster',          'Pod security controls'),

    -- Infrastructure
    ('Infrastructure',  '',                   'v1',     'Node',                 'nodes',             'no', FALSE, 'Cluster',             'A worker machine in the cluster'),
    ('Infrastructure',  '',                   'v1',     'Namespace',            'namespaces',        'ns', FALSE, 'Cluster',             'Virtual cluster within the physical cluster'),
    ('Infrastructure',  'coordination.k8s.io', 'v1',   'Lease',                 'leases',            NULL, TRUE,  'Namespaced',         'Distributed coordination leases'),

    -- Autoscaling
    ('Autoscaling',     'autoscaling',        'v2',     'HorizontalPodAutoscaler', 'horizontalpodautoscalers', 'hpa', TRUE, 'Namespaced', 'Autoscale pods based on metrics'),
    ('Autoscaling',     'autoscaling',        'v1',     'VerticalPodAutoscaler',   'verticalpodautoscalers', 'vpa', TRUE,  'Namespaced', 'Autoscale pod resource requests'),
    ('Autoscaling',     'policy',             'v1',     'PodDisruptionBudget',     'poddisruptionbudgets', 'pdb', TRUE,  'Namespaced', 'Limits disruptions to pods'),

    -- Batch
    ('Batch',           'batch',              'v1',     'Job',                  'jobs',              NULL, TRUE,  'Namespaced',         'Run a batch job to completion'),
    ('Batch',           'batch',              'v1',     'CronJob',              'cronjobs',          'cj', TRUE,  'Namespaced',         'Run jobs on a schedule'),

    -- Orchestration
    ('Orchestration',   'apiextensions.k8s.io', 'v1',  'CustomResourceDefinition', 'customresourcedefinitions', 'crd', FALSE, 'Cluster', 'Extend the Kubernetes API'),
    ('Orchestration',   '',                   'v1',     'APIService',           'apiservices',       NULL, FALSE, 'Cluster',             'API aggregation layer service'),
    ('Orchestration',   'flowcontrol.apiserver.k8s.io', 'v1beta3', 'FlowSchema', 'flowschemas', NULL, FALSE, 'Cluster',             'API priority and fairness'),
    ('Orchestration',   'gateway.networking.k8s.io', 'v1', 'Gateway',           'gateways',          'gw', TRUE,  'Namespaced',         'Gateway API gateway resource'),
    ('Orchestration',   'gateway.networking.k8s.io', 'v1', 'HTTPRoute',         'httproutes',        NULL, TRUE,  'Namespaced',         'Gateway API HTTP route')
) AS t(cat_name, api_group, api_version, kind, plural, short, namespaced, scope, descr)
WHERE c.slug = LOWER(REPLACE(t.cat_name, ' ', '-'))
ON CONFLICT (api_group, api_version, resource_kind) DO NOTHING;

-- ============================================================================
-- Default saved views (pre-configured views for common use cases)
-- ============================================================================

-- Note: owner_id would be a system/robot user UUID in production
-- These are template placeholders
INSERT INTO saved_resource_views (id, owner_id, name, description, visibility, filters, columns_config, is_default, is_shared)
SELECT
    gen_random_uuid() AS id,
    '00000000-0000-0000-0000-000000000000'::UUID AS owner_id,
    name, description, visibility, filters, columns_config, is_default, is_shared
FROM (VALUES
    ('All Resources',
     'Complete view of all resources across all clusters with health status',
     'organization',
     '{}'::JSONB,
     '[{"field":"name","visible":true},{"field":"cluster","visible":true},{"field":"kind","visible":true},{"field":"namespace","visible":true},{"field":"health","visible":true},{"field":"phase","visible":true},{"field":"last_seen","visible":true}]'::JSONB,
     FALSE, TRUE),

    ('Unhealthy Resources',
     'Focus on degraded and unhealthy resources requiring attention',
     'organization',
     '{"health":["degraded","unhealthy"]}'::JSONB,
     '[{"field":"name","visible":true},{"field":"cluster","visible":true},{"field":"kind","visible":true},{"field":"namespace","visible":true},{"field":"health","visible":true},{"field":"phase","visible":true},{"field":"last_synced","visible":true}]'::JSONB,
     FALSE, TRUE),

    ('Workload Overview',
     'All deployments, statefulsets, and daemonsets across clusters',
     'organization',
     '{"resource_kinds":["Deployment","StatefulSet","DaemonSet"]}'::JSONB,
     '[{"field":"name","visible":true},{"field":"cluster","visible":true},{"field":"kind","visible":true},{"field":"namespace","visible":true},{"field":"health","visible":true},{"field":"labels.app","visible":true,"label":"App"}]'::JSONB,
     FALSE, TRUE),

    ('Pods View',
     'All pods sorted by health status',
     'organization',
     '{"resource_kinds":["Pod"]}'::JSONB,
     '[{"field":"name","visible":true},{"field":"cluster","visible":true},{"field":"namespace","visible":true},{"field":"phase","visible":true},{"field":"health","visible":true},{"field":"node","visible":true},{"field":"age","visible":true}]'::JSONB,
     FALSE, TRUE),

    ('Sync Issues',
     'Resources with synchronization failures or stale data',
     'organization',
     '{"sync_statuses":["sync_failed","stale","orphaned"]}'::JSONB,
     '[{"field":"name","visible":true},{"field":"cluster","visible":true},{"field":"kind","visible":true},{"field":"sync_status","visible":true},{"field":"last_synced","visible":true}]'::JSONB,
     FALSE, TRUE)
) AS v(name, description, visibility, filters, columns_config, is_default, is_shared)
WHERE NOT EXISTS (
    SELECT 1 FROM saved_resource_views sv
    WHERE sv.owner_id = '00000000-0000-0000-0000-000000000000'
      AND sv.name = v.name
);
