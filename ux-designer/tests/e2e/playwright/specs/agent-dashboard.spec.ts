// Agent Dashboard E2E tests
// Tag: @AGENTS-01
import { test, expect } from '@playwright/test';
import { AgentDashboardPage } from '../pages/AgentDashboardPage';
import { mockWasteObservations } from '../fixtures/test-data';

test.describe('Agent Dashboard @AGENTS-01', () => {
  let page;
  let dashboard: AgentDashboardPage;

  test.beforeEach(async ({ browser }) => {
    page = await browser.newPage();
    await page.route('**/api/v1/agents', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify([
          {
            name: 'finops-analyzer',
            namespace: 'default',
            spec: {
              type: 'analyzer',
              triggers: [{ cron: '*/30 * * * *', manual: true }],
              action: { mcp_server: 'finops', capabilities: ['analyze', 'recommend'] },
              watch_scope: { namespaces: ['*'], resources: ['deployments', 'statefulsets'], labels: {} },
              max_retries: 3,
              timeout_seconds: 120,
            },
            status: {
              phase: 'running',
              last_triggered_at: '2026-06-03T13:45:00Z',
              execution_count: 142,
              failure_count: 3,
            },
          },
          {
            name: 'anomstack-watcher',
            namespace: 'default',
            spec: {
              type: 'watcher',
              triggers: [{ event: 'anomaly:critical', manual: false }],
              action: { mcp_server: 'agents', capabilities: ['describe', 'diagnose'] },
              watch_scope: { namespaces: ['*'], resources: ['pods', 'events'], labels: {'app': 'rufkis'} },
              max_retries: 5,
              timeout_seconds: 300,
            },
            status: {
              phase: 'idle',
              execution_count: 89,
              failure_count: 1,
            },
          },
        ]),
      });
    });

    await page.route('**/api/v1/agents/activity*', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify([
          {
            alert_id: 'evt-001',
            cluster: 'prod-eu-west-1',
            namespace: 'api',
            resource_kind: 'deployment',
            name: 'api-gateway',
            severity: 'warning',
            summary: 'CPU throttling detected — right-sizing recommended',
            timestamp: '2026-06-03T13:30:00Z',
          },
        ]),
      });
    });

    dashboard = new AgentDashboardPage(page);
    await page.goto('/agents');
  });

  test('should render agent dashboard with correct title', async () => {
    await expect(dashboard.dashboard).toBeVisible();
    await expect(dashboard.dashboard).toContainText('Autonomous Agents');
  });

  test('should display agent badge grid', async () => {
    const badges = await dashboard.getAgentBadges();
    expect(badges.length).toBeGreaterThanOrEqual(1);
  });

  test('should show specific agent badges', async () => {
    const finopsBadge = dashboard.getAgentBadge('finops-analyzer');
    await expect(finopsBadge).toBeVisible();
    await expect(finopsBadge).toContainText('finops-analyzer');
  });

  test('should display agent status indicators', async () => {
    const badge = dashboard.getAgentBadge('finops-analyzer');
    await expect(badge).toContainText('Analyzing');
  });

  test('should show agent metrics (total, running, failed, runs)', async () => {
    await expect(dashboard.metrics).toBeVisible();
    await expect(dashboard.metrics).toContainText('Total');
  });

  test('should select an agent on click', async () => {
    await dashboard.selectAgent('finops-analyzer');
    const selected = page.locator('.agent-badge--selected');
    await expect(selected).toBeVisible();
  });

  test('should show activity feed', async () => {
    await expect(dashboard.getFeed()).toBeVisible();
  });

  test('should handle empty agent list gracefully', async () => {
    await page.route('**/api/v1/agents', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: '[]',
      });
    });
    await page.reload();
    await expect(page.getByText('No agents configured')).toBeVisible();
  });

  test('should handle error state with retry', async () => {
    await page.route('**/api/v1/agents', async (route) => {
      await route.fulfill({
        status: 500,
        body: 'Internal Server Error',
      });
    });
    await page.reload();
    await expect(page.getByText('Retry')).toBeVisible();
  });
});
