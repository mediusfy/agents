

-- ============================================================================
-- BOARD-02 Seed Data
-- Provides starter templates and a sample board for development / QA.
-- ============================================================================

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- Sample board templates
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO public.board_templates (id, name, description, columns_definition, created_by, scope)
VALUES
    (public.gen_uuid_v7(), 'Standard Pipeline', 'Classic dev→staging→prod pipeline board',
     '[{"name":"Backlog","width_px":320,"color_hex":"#F1F5F9","filter_expression":{"status":"pending"},"sort_order":[{"field":"name","dir":"asc"}]},{"name":"In Progress","width_px":320,"color_hex":"#DBEAFE","filter_expression":{"status":"in_progress"},"sort_order":[{"field":"name","dir":"asc"}]},{"name":"Review","width_px":320,"color_hex":"#FEF3C7","filter_expression":{"status":"review"},"sort_order":[{"field":"name","dir":"asc"}]},{"name":"Done","width_px":320,"color_hex":"#D1FAE5","filter_expression":{"status":"done"},"sort_order":[{"field":"name","dir":"asc"}]}]'::jsonb,
     'system', 'org'),
    (public.gen_uuid_v7(), 'Cluster Health', 'Per-cluster health monitoring board',
     '[{"name":"Healthy","width_px":360,"color_hex":"#D1FAE5","filter_expression":{"status.phase":"Running"},"sort_order":[{"field":"resource_name","dir":"asc"}]},{"name":"Degraded","width_px":360,"color_hex":"#FEF3C7","filter_expression":{"status.phase":"Degraded"},"sort_order":[{"field":"resource_name","dir":"asc"}]},{"name":"Down","width_px":360,"color_hex":"#FEE2E2","filter_expression":{"status.phase":"Down"},"sort_order":[{"field":"resource_name","dir":"asc"}]}]'::jsonb,
     'system', 'org')
ON CONFLICT (id) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
── Sample board for development / e2e testing
-- ────────────────────────────────────────────────────────────────────────────
WITH board AS (
    INSERT INTO public.boards (id, name, description, owner_team, region, filter_criteria, version)
    VALUES (public.gen_uuid_v7(), 'Team Sigma Dashboard', 'Monitor all Sigma team resources', 'sigma', 'us-east-1',
            '{"cluster":"sigma-cluster","namespace":"sigma-*"}'::jsonb, 1)
    RETURNING id
)
INSERT INTO public.board_columns (id, board_id, name, position, width_px, color_hex, card_limit, filter_expression, sort_order)
SELECT public.gen_uuid_v7(), board.id, 'Running',    0, 340, '#D1FAE5', 50, '{"status.phase":"Running"}'::jsonb,  '[{"field":"name","dir":"asc"}]'::jsonb
FROM board
UNION ALL
SELECT public.gen_uuid_v7(), board.id, 'Pending',    1, 340, '#FEF3C7', 50, '{"status.phase":"Pending"}'::jsonb,  '[{"field":"name","dir":"asc"}]'::jsonb
FROM board
UNION ALL
SELECT public.gen_uuid_v7(), board.id, 'Failed',     2, 340, '#FEE2E2', 20, '{"status.phase":"Failed"}'::jsonb,   '[{"field":"name","dir":"asc"}]'::jsonb
FROM board;

-- ────────────────────────────────────────────────────────────────────────────
-- Region-cluster mapping seeds
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO public.region_cluster_mapping (region, cluster_id, cluster_name, status)
VALUES
    ('us-east-1', 'clus-001', 'sigma-cluster',    'active'),
    ('us-east-1', 'clus-002', 'omega-cluster',    'active'),
    ('us-west-2', 'clus-003', 'gamma-cluster',    'active'),
    ('eu-west-1', 'clus-004', 'lambda-cluster',   'degraded'),
    ('global',    'clus-000', 'control-plane',    'active')
ON CONFLICT (region, cluster_id) DO NOTHING;

COMMIT;
