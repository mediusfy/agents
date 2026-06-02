

-- Seed: 012_board_01_board_view_seed
-- Description: Seed data for the monday.com-Style Board View schema
-- 
-- Creates sample boards for:
--   1. "Cluster Overview" - Main board showing all cluster resources
--   2. "Pod Health" - Board focused on pod status monitoring
--   3. "Deployment Pipeline" - Board for deployment tracking

-- =============================================================================
-- SAMPLE BOARDS
-- =============================================================================

INSERT INTO boards (id, name, description, board_kind, workspace_id, owner_id, filter_config, sort_order)
VALUES
    (
        'a0000000-0000-0000-0000-000000000001',
        'Cluster Overview',
        'High-level view of all Kubernetes resources across clusters',
        'main',
        NULL, -- workspace_id (FK, set if workspaces table exists)
        NULL, -- owner_id (FK, set if users table exists)
        '{"resource_types": ["pod", "deployment", "service", "ingress"]}'::jsonb,
        0
    ),
    (
        'a0000000-0000-0000-0000-000000000002',
        'Pod Health Dashboard',
        'Real-time pod health monitoring board with status groupings',
        'main',
        NULL,
        NULL,
        '{"resource_types": ["pod"], "namespaces": ["default", "kube-system", "production"]}'::jsonb,
        1
    ),
    (
        'a0000000-0000-0000-0000-000000000003',
        'Deployment Pipeline',
        'Track deployment rollouts across environments',
        'shared',
        NULL,
        NULL,
        '{"resource_types": ["deployment"], "namespaces": ["staging", "production"]}'::jsonb,
        2
    )
ON CONFLICT (id) DO NOTHING;

-- =============================================================================
-- SAMPLE BOARD GROUPS
-- =============================================================================

-- Groups for Board 1: Cluster Overview
INSERT INTO board_groups (id, board_id, title, color, icon, sort_order)
VALUES
    ('b0000000-0000-0000-0000-000000000101', 'a0000000-0000-0000-0000-000000000001', 'Running',     '#00c875', 'check-circle',  0),
    ('b0000000-0000-0000-0000-000000000102', 'a0000000-0000-0000-0000-000000000001', 'Pending',     '#ffcb00', 'clock',         1),
    ('b0000000-0000-0000-0000-000000000103', 'a0000000-0000-0000-0000-000000000001', 'Failed',      '#e2445c', 'alert-circle',  2),
    ('b0000000-0000-0000-0000-000000000104', 'a0000000-0000-0000-0000-000000000001', 'Unknown',     '#a9a9a9', 'help-circle',   3)
ON CONFLICT (id) DO NOTHING;

-- Groups for Board 2: Pod Health Dashboard
INSERT INTO board_groups (id, board_id, title, color, icon, sort_order)
VALUES
    ('b0000000-0000-0000-0000-000000000201', 'a0000000-0000-0000-0000-000000000002', 'Healthy',       '#00c875', 'heart',         0),
    ('b0000000-0000-0000-0000-000000000202', 'a0000000-0000-0000-0000-000000000002', 'Degraded',      '#ffcb00', 'alert-triangle',1),
    ('b0000000-0000-0000-0000-000000000203', 'a0000000-0000-0000-0000-000000000002', 'CrashLoop',     '#e2445c', 'skull',         2),
    ('b0000000-0000-0000-0000-000000000204', 'a0000000-0000-0000-0000-000000000002', 'Evicted',       '#a9a9a9', 'x-circle',      3)
ON CONFLICT (id) DO NOTHING;

-- Groups for Board 3: Deployment Pipeline
INSERT INTO board_groups (id, board_id, title, color, icon, sort_order)
VALUES
    ('b0000000-0000-0000-0000-000000000301', 'a0000000-0000-0000-0000-000000000003', 'Staging',       '#0086c0', 'cloud',         0),
    ('b0000000-0000-0000-0000-000000000302', 'a0000000-0000-0000-0000-000000000003', 'Canary',        '#ffcb00', 'flask',         1),
    ('b0000000-0000-0000-0000-000000000303', 'a0000000-0000-0000-0000-000000000003', 'Production',    '#00c875', 'globe',         2),
    ('b0000000-0000-0000-0000-000000000304', 'a0000000-0000-0000-0000-000000000003', 'Rolled Back',   '#e2445c', 'rotate-ccw',    3)
ON CONFLICT (id) DO NOTHING;

-- =============================================================================
-- SAMPLE BOARD COLUMNS (Supplemental seed for board_columns from 009)
-- =============================================================================

INSERT INTO board_columns (id, board_id, title, column_type, settings, width, sort_order)
VALUES
    -- Board 1: Cluster Overview columns
    ('c0000000-0000-0000-0000-000000000101', 'a0000000-0000-0000-0000-000000000001', 'Status',       'status',   '{"labels": ["Running", "Pending", "Failed", "Unknown"]}'::jsonb, 120, 0),
    ('c0000000-0000-0000-0000-000000000102', 'a0000000-0000-0000-0000-000000000001', 'Name',         'text',     '{}'::jsonb, 250, 1),
    ('c0000000-0000-0000-0000-000000000103', 'a0000000-0000-0000-0000-000000000001', 'Namespace',    'text',     '{}'::jsonb, 150, 2),
    ('c0000000-0000-0000-0000-000000000104', 'a0000000-0000-0000-0000-000000000001', 'Type',         'text',     '{}'::jsonb, 120, 3),
    ('c0000000-0000-0000-0000-000000000105', 'a0000000-0000-0000-0000-000000000001', 'CPU Usage',    'numeric',  '{"unit": "cores", "precision": 3}'::jsonb, 120, 4),
    ('c0000000-0000-0000-0000-000000000106', 'a0000000-0000-0000-0000-000000000001', 'Memory',       'numeric',  '{"unit": "MiB", "precision": 0}'::jsonb, 120, 5),
    ('c0000000-0000-0000-0000-000000000107', 'a0000000-0000-0000-0000-000000000001', 'Age',          'text',     '{}'::jsonb, 100, 6),
    ('c0000000-0000-0000-0000-000000000108', 'a0000000-0000-0000-0000-000000000001', 'Assigned To',  'person',   '{}'::jsonb, 180, 7),
    ('c0000000-0000-0000-0000-000000000109', 'a0000000-0000-0000-0000-000000000001', 'Notes',        'long_text','{}'::jsonb, 200, 8),
    
    -- Board 2: Pod Health Dashboard columns
    ('c0000000-0000-0000-0000-000000000201', 'a0000000-0000-0000-0000-000000000002', 'Status',       'status',   '{"labels": ["Healthy", "Degraded", "CrashLoop", "Evicted"]}'::jsonb, 120, 0),
    ('c0000000-0000-0000-0000-000000000202', 'a0000000-0000-0000-0000-000000000002', 'Pod Name',     'text',     '{}'::jsonb, 250, 1),
    ('c0000000-0000-0000-0000-000000000203', 'a0000000-0000-0000-0000-000000000002', 'Namespace',    'text',     '{}'::jsonb, 150, 2),
    ('c0000000-0000-0000-0000-000000000204', 'a0000000-0000-0000-0000-000000000002', 'Restarts',     'numeric',  '{"precision": 0}'::jsonb, 100, 3),
    ('c0000000-0000-0000-0000-000000000205', 'a0000000-0000-0000-0000-000000000002', 'CPU Request',  'numeric',  '{"unit": "cores", "precision": 3}'::jsonb, 120, 4),
    ('c0000000-0000-0000-0000-000000000206', 'a0000000-0000-0000-0000-000000000002', 'Memory Request','numeric', '{"unit": "MiB", "precision": 0}'::jsonb, 130, 5),
    ('c0000000-0000-0000-0000-000000000207', 'a0000000-0000-0000-0000-000000000002', 'Node',         'text',     '{}'::jsonb, 180, 6),
    ('c0000000-0000-0000-0000-000000000208', 'a0000000-0000-0000-0000-000000000002', 'QoS Class',    'text',     '{}'::jsonb, 120, 7),
    
    -- Board 3: Deployment Pipeline columns
    ('c0000000-0000-0000-0000-000000000301', 'a0000000-0000-0000-0000-000000000003', 'Status',       'status',   '{"labels": ["Staging", "Canary", "Production", "Rolled Back"]}'::jsonb, 120, 0),
    ('c0000000-0000-0000-0000-000000000302', 'a0000000-0000-0000-0000-000000000003', 'Deployment',   'text',     '{}'::jsonb, 250, 1),
    ('c0000000-0000-0000-0000-000000000303', 'a0000000-0000-0000-0000-000000000003', 'Image',        'text',     '{}'::jsonb, 250, 2),
    ('c0000000-0000-0000-0000-000000000304', 'a0000000-0000-0000-0000-000000000003', 'Replicas',     'numeric',  '{"precision": 0}'::jsonb, 100, 3),
    ('c0000000-0000-0000-0000-000000000305', 'a0000000-0000-0000-0000-000000000003', 'Rollout Date', 'date',     '{}'::jsonb, 150, 4),
    ('c0000000-0000-0000-0000-000000000306', 'a0000000-0000-0000-0000-000000000003', 'Deployed By',  'person',   '{}'::jsonb, 180, 5)
ON CONFLICT (id) DO NOTHING;

-- =============================================================================
-- SAMPLE BOARD ITEMS
-- =============================================================================

-- Items for Board 1: Cluster Overview (Running group)
INSERT INTO board_items (id, board_id, group_id, title, resource_type, resource_name, resource_namespace, cluster_id, sort_order)
VALUES
    ('d0000000-0000-0000-0000-000000000101', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000101', 'nginx-ingress-controller-7d8b9c', 'pod', 'nginx-ingress-controller-7d8b9c', 'kube-system', NULL, 0),
    ('d0000000-0000-0000-0000-000000000102', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000101', 'api-server-6f4d8', 'pod', 'api-server-6f4d8', 'default', NULL, 1),
    ('d0000000-0000-0000-0000-000000000103', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000101', 'web-app-deployment', 'deployment', 'web-app', 'production', NULL, 2),
    ('d0000000-0000-0000-0000-000000000104', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000101', 'redis-service', 'service', 'redis', 'default', NULL, 3),
    
    -- Items for Board 1 (Pending group)
    ('d0000000-0000-0000-0000-000000000105', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000102', 'sidecar-injector-9f8d2', 'pod', 'sidecar-injector-9f8d2', 'kube-system', NULL, 0),
    ('d0000000-0000-0000-0000-000000000106', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000102', 'new-batch-job', 'pod', 'new-batch-job-4f8a1', 'default', NULL, 1),
    
    -- Items for Board 1 (Failed group)
    ('d0000000-0000-0000-0000-000000000107', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000103', 'analytics-worker-g7h3j', 'pod', 'analytics-worker-g7h3j', 'data-plane', NULL, 0),
    ('d0000000-0000-0000-0000-000000000108', 'a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000103', 'old-cronjob-migrate', 'pod', 'old-cronjob-migrate-2k9l0', 'default', NULL, 1)
ON CONFLICT (id) DO NOTHING;

-- Items for Board 2: Pod Health Dashboard (Healthy group)
INSERT INTO board_items (id, board_id, group_id, title, resource_type, resource_name, resource_namespace, cluster_id, icon, sort_order)
VALUES
    ('d0000000-0000-0000-0000-000000000201', 'a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000201', 'core-api-7d9c8', 'pod', 'core-api-7d9c8', 'production', NULL, 'cpu', 0),
    ('d0000000-0000-0000-0000-000000000202', 'a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000201', 'auth-service-6k4l2', 'pod', 'auth-service-6k4l2', 'production', NULL, 'shield', 1),
    ('d0000000-0000-0000-0000-000000000203', 'a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000201', 'frontend-8f3a1', 'pod', 'frontend-8f3a1', 'production', NULL, 'layout', 2),
    
    -- Items for Board 2 (Degraded group)
    ('d0000000-0000-0000-0000-000000000204', 'a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000202', 'recommendation-svc-9g7h5', 'pod', 'recommendation-svc-9g7h5', 'production', NULL, 'trending-up', 0),
    ('d0000000-0000-0000-0000-000000000205', 'a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000202', 'ml-inference-4j8k2', 'pod', 'ml-inference-4j8k2', 'ml-ops', NULL, 'brain', 1),
    
    -- Items for Board 2 (CrashLoop group)
    ('d0000000-0000-0000-0000-000000000206', 'a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000203', 'legacy-worker-3f6h9', 'pod', 'legacy-worker-3f6h9', 'default', NULL, 'alert-octagon', 0)
ON CONFLICT (id) DO NOTHING;

-- Items for Board 3: Deployment Pipeline (Staging group)
INSERT INTO board_items (id, board_id, group_id, title, resource_type, resource_name, resource_namespace, sort_order)
VALUES
    ('d0000000-0000-0000-0000-000000000301', 'a0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000301', 'web-app v2.3.1', 'deployment', 'web-app', 'staging', 0),
    ('d0000000-0000-0000-0000-000000000302', 'a0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000301', 'api-gateway v1.8.0', 'deployment', 'api-gateway', 'staging', 1),
    
    -- Items for Board 3 (Canary group)
    ('d0000000-0000-0000-0000-000000000303', 'a0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000302', 'web-app v2.3.1-canary', 'deployment', 'web-app-canary', 'staging', 0),
    
    -- Items for Board 3 (Production group)
    ('d0000000-0000-0000-0000-000000000304', 'a0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000303', 'web-app v2.3.0', 'deployment', 'web-app', 'production', 0),
    ('d0000000-0000-0000-0000-000000000305', 'a0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000303', 'api-gateway v1.7.5', 'deployment', 'api-gateway', 'production', 1),
    
    -- Items for Board 3 (Rolled Back group)
    ('d0000000-0000-0000-0000-000000000306', 'a0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000304', 'cache-layer v2.0.0', 'deployment', 'cache-layer', 'production', 0)
ON CONFLICT (id) DO NOTHING;

-- =============================================================================
-- SAMPLE COLUMN VALUES
-- =============================================================================

-- Board 1 Column Values
INSERT INTO board_item_column_values (id, item_id, column_id, value, status_value)
VALUES
    -- nginx-ingress (Running group, Status column)
    ('e0000000-0000-0000-0000-000000000101', 'd0000000-0000-0000-0000-000000000101', 'c0000000-0000-0000-0000-000000000101', 'Running', 'Running'),
    -- api-server (Running group, Status column)
    ('e0000000-0000-0000-0000-000000000102', 'd0000000-0000-0000-0000-000000000102', 'c0000000-0000-0000-0000-000000000101', 'Running', 'Running'),
    -- sidecar-injector (Pending group, Status column)
    ('e0000000-0000-0000-0000-000000000103', 'd0000000-0000-0000-0000-000000000105', 'c0000000-0000-0000-0000-000000000101', 'Pending', 'Pending'),
    -- analytics-worker (Failed group, Status column)
    ('e0000000-0000-0000-0000-000000000104', 'd0000000-0000-0000-0000-000000000107', 'c0000000-0000-0000-0000-000000000101', 'Failed', 'Failed')
ON CONFLICT (item_id, column_id) DO NOTHING;

-- Board 1: Name column values
INSERT INTO board_item_column_values (id, item_id, column_id, value)
VALUES
    ('e0000000-0000-0000-0000-000000000111', 'd0000000-0000-0000-0000-000000000101', 'c0000000-0000-0000-0000-000000000102', 'nginx-ingress-controller-7d8b9c'),
    ('e0000000-0000-0000-0000-000000000112', 'd0000000-0000-0000-0000-000000000102', 'c0000000-0000-0000-0000-000000000102', 'api-server-6f4d8'),
    ('e0000000-0000-0000-0000-000000000115', 'd0000000-0000-0000-0000-000000000105', 'c0000000-0000-0000-0000-000000000102', 'sidecar-injector-9f8d2'),
    ('e0000000-0000-0000-0000-000000000117', 'd0000000-0000-0000-0000-000000000107', 'c0000000-0000-0000-0000-000000000102', 'analytics-worker-g7h3j')
ON CONFLICT (item_id, column_id) DO NOTHING;

-- Board 1: Namespace column values
INSERT INTO board_item_column_values (id, item_id, column_id, value)
VALUES
    ('e0000000-0000-0000-0000-000000000121', 'd0000000-0000-0000-0000-000000000101', 'c0000000-0000-0000-0000-000000000103', 'kube-system'),
    ('e0000000-0000-0000-0000-000000000122', 'd0000000-0000-0000-0000-000000000102', 'c0000000-0000-0000-0000-000000000103', 'default'),
    ('e0000000-0000-0000-0000-000000000125', 'd0000000-0000-0000-0000-000000000105', 'c0000000-0000-0000-0000-000000000103', 'kube-system'),
    ('e0000000-0000-0000-0000-000000000127', 'd0000000-0000-0000-0000-000000000107', 'c0000000-0000-0000-0000-000000000103', 'data-plane')
ON CONFLICT (item_id, column_id) DO NOTHING;

-- Board 1: Type column values
INSERT INTO board_item_column_values (id, item_id, column_id, value)
VALUES
    ('e0000000-0000-0000-0000-000000000131', 'd0000000-0000-0000-0000-000000000101', 'c0000000-0000-0000-0000-000000000104', 'Pod'),
    ('e0000000-0000-0000-0000-000000000132', 'd0000000-0000-0000-0000-000000000102', 'c0000000-0000-0000-0000-000000000104', 'Pod'),
    ('e0000000-0000-0000-0000-000000000133', 'd0000000-0000-0000-0000-000000000103', 'c0000000-0000-0000-0000-000000000104', 'Deployment'),
    ('e0000000-0000-0000-0000-000000000134', 'd0000000-0000-0000-0000-000000000104', 'c0000000-0000-0000-0000-000000000104', 'Service')
ON CONFLICT (item_id, column_id) DO NOTHING;

-- Board 1: CPU Usage numeric values
INSERT INTO board_item_column_values (id, item_id, column_id, value, numeric_value)
VALUES
    ('e0000000-0000-0000-0000-000000000141', 'd0000000-0000-0000-0000-000000000101', 'c0000000-0000-0000-0000-000000000105', '0.25', 0.25),
    ('e0000000-0000-0000-0000-000000000142', 'd0000000-0000-0000-0000-000000000102', 'c0000000-0000-0000-0000-000000000105', '0.50', 0.50)
ON CONFLICT (item_id, column_id) DO NOTHING;

-- Board 1: Memory numeric values
INSERT INTO board_item_column_values (id, item_id, column_id, value, numeric_value)
VALUES
    ('e0000000-0000-0000-0000-000000000151', 'd0000000-0000-0000-0000-000000000101', 'c0000000-0000-0000-0000-000000000106', '128', 128),
    ('e0000000-0000-0000-0000-000000000152', 'd0000000-0000-0000-0000-000000000102', 'c0000000-0000-0000-0000-000000000106', '256', 256)
ON CONFLICT (item_id, column_id) DO NOTHING;
