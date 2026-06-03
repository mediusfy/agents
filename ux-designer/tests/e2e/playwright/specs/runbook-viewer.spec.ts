// Runbook Viewer + Terminal Drawer E2E tests
// Tag: @RUNBOOKS-01
import { test, expect } from '@playwright/test';
import { RunbookViewerPage } from '../pages/RunbookViewerPage';

test.describe('Runbook Viewer @RUNBOOKS-01', () => {
  let page;
  let runbookViewer: RunbookViewerPage;

  test.beforeEach(async ({ browser }) => {
    page = await browser.newPage();
    await page.route('**/api/v1/runbooks', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify([
          {
            path: 'runbooks/redis-failover.md',
            title: 'Redis Failover Procedure',
            blocks: [
              {
                id: 'step-1',
                language: 'sh',
                content: 'kubectl exec redis-0 -- redis-cli -a $REDIS_PASSWORD role',
                expected_output_pattern: '(master|slave)',
                description: 'Check current Redis role',
              },
              {
                id: 'step-2',
                language: 'markdown',
                content: '## Verification\nCheck that all replicas are synchronized.',
                description: '',
              },
            ],
          },
        ]),
      });
    });

    await page.route('**/api/v1/runbooks/*/blocks/*/execute', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          stdout: 'master',
          stderr: '',
          exit_code: 0,
          validated: true,
        }),
      });
    });

    runbookViewer = new RunbookViewerPage(page);
    await page.goto('/runbooks');
  });

  test('should render runbook picker with available runbooks', async () => {
    await expect(runbookViewer.viewer).toBeVisible();
    const card = runbookViewer.getRunbookCard('runbooks/redis-failover.md');
    await expect(card).toBeVisible();
    await expect(card).toContainText('Redis Failover Procedure');
  });

  test('should open a runbook on card click', async () => {
    await runbookViewer.openRunbook('runbooks/redis-failover.md');
    await expect(page.getByText('Redis Failover Procedure')).toBeVisible();
  });

  test('should display runbook blocks after opening', async () => {
    await runbookViewer.openRunbook('runbooks/redis-failover.md');
    const block = runbookViewer.getBlock('step-1');
    await expect(block).toBeVisible();
    await expect(block).toContainText('kubectl exec');
  });

  test('should execute an executable block', async () => {
    await runbookViewer.openRunbook('runbooks/redis-failover.md');
    await runbookViewer.executeBlock('step-1');
    // Terminal should open and show output
    await expect(page.getByText('master')).toBeVisible();
  });

  test('should open terminal drawer on execute', async () => {
    await runbookViewer.openRunbook('runbooks/redis-failover.md');
    await runbookViewer.executeBlock('step-1');
    const isOpen = await runbookViewer.isTerminalOpen();
    expect(isOpen).toBeTruthy();
  });

  test('should copy block content on copy button click', async () => {
    await runbookViewer.openRunbook('runbooks/redis-failover.md');
    await runbookViewer.copyBlock('step-1');
    await expect(page.getByText('✓ Copied')).toBeVisible();
  });

  test('should close terminal drawer', async () => {
    await runbookViewer.openRunbook('runbooks/redis-failover.md');
    await runbookViewer.executeBlock('step-1');
    // Close via close button
    const closeBtn = page.getByTestId('terminal-close-btn');
    await closeBtn.click();
    const isOpen = await runbookViewer.isTerminalOpen();
    expect(isOpen).toBeFalsy();
  });

  test('should support toggle terminal with Ctrl+`', async () => {
    await runbookViewer.openRunbook('runbooks/redis-failover.md');
    await runbookViewer.executeBlock('step-1');
    // Toggle via keyboard shortcut
    await page.keyboard.press('Control+`');
    const isOpen = await runbookViewer.isTerminalOpen();
    expect(isOpen).toBeFalsy();
  });

  test('should show empty state when no runbooks available', async () => {
    await page.route('**/api/v1/runbooks', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: '[]',
      });
    });
    await page.reload();
    await expect(page.getByText('No runbooks available')).toBeVisible();
  });

  test('should handle error state with retry button', async () => {
    await page.route('**/api/v1/runbooks', async (route) => {
      await route.fulfill({
        status: 500,
        body: 'Internal Server Error',
      });
    });
    await page.reload();
    await expect(page.getByText('Retry')).toBeVisible();
  });
});
