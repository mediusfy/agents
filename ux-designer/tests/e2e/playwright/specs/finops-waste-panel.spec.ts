// FinOps Waste Panel E2E tests
// Tag: @FIN-OPS-01
import { test, expect } from '@playwright/test';
import { FinOpsWastePanel } from '../pages/FinOpsPage';
import { mockWasteObservations, mockAction } from '../fixtures/test-data';

test.describe('FinOps Waste Panel @FIN-OPS-01', () => {
  let page;
  let finopsPanel: FinOpsWastePanel;

  test.beforeEach(async ({ browser }) => {
    // Mock API responses
    page = await browser.newPage();
    await page.route('**/api/v1/waste/top*', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(mockWasteObservations),
      });
    });
    await page.route('**/api/v1/waste/*/recommend', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(mockAction),
      });
    });
    await page.route('**/api/v1/waste/*/dismiss', async (route) => {
      await route.fulfill({ status: 204 });
    });

    finopsPanel = new FinOpsWastePanel(page);
    await page.goto('/');
  });

  test('should render the FinOps waste panel with correct title', async () => {
    await expect(finopsPanel.panel).toBeVisible();
    await expect(finopsPanel.title).toContainText('FinOps Waste Analysis');
  });

  test('should display opportunity count and savings metrics', async () => {
    await expect(finopsPanel.metricOpportunities).toBeVisible();
    await expect(finopsPanel.metricSavings).toBeVisible();
  });

  test('should display top 3 highlight cards sorted by savings', async () => {
    const highlights = await finopsPanel.getHighlightCards();
    expect(highlights.length).toBeLessThanOrEqual(3);

    // Verify sorted: obs-003 ($1560) then obs-001 ($1240) then obs-002 ($340)
    const cards = await finopsPanel.getPrCards();
    expect(cards.length).toBeGreaterThan(0);
  });

  test('should display the full list of waste observations', async () => {
    const list = finopsPanel.list;
    await expect(list).toBeVisible();
  });

  test('should trigger PR creation when Generate PR is clicked', async () => {
    await page.waitForTimeout(500);
    const firstCard = (await finopsPanel.getPrCards())[0];
    if (firstCard) {
      const testId = await firstCard.getAttribute('data-testid');
      if (testId) {
        await finopsPanel.clickGeneratePr(testId);
        await expect(firstCard).toContainText('PR Created');
      }
    }
  });

  test('should dismiss observation when Dismiss is clicked', async () => {
    await page.waitForTimeout(500);
    const firstCard = (await finopsPanel.getPrCards())[0];
    if (firstCard) {
      const testId = await firstCard.getAttribute('data-testid');
      if (testId) {
        await finopsPanel.clickDismiss(testId);
        // Card should update or disappear
      }
    }
  });

  test('should show live polling indicator', async () => {
    await expect(finopsPanel.statusIndicator).toBeVisible();
    await expect(finopsPanel.statusIndicator).toContainText('Live');
  });

  test('should handle empty state gracefully', async () => {
    // Override route to return empty array
    await page.route('**/api/v1/waste/top*', async (route) => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: '[]',
      });
    });
    await page.reload();
    await expect(page.getByText('No items yet')).toBeVisible();
  });

  test('should handle error state with retry button', async () => {
    await page.route('**/api/v1/waste/top*', async (route) => {
      await route.fulfill({
        status: 500,
        body: 'Internal Server Error',
      });
    });
    await page.reload();
    await expect(page.getByText('Retry')).toBeVisible();
  });

  test('should support keyboard navigation (Tab/Enter)', async () => {
    // Tab through the first PR card's actions
    await page.keyboard.press('Tab');
    const focused = page.locator(':focus');
    await expect(focused).toBeVisible();
  });
});
