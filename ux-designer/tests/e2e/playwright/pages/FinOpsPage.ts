// Page Object Model for FinOps Waste Panel

import { type Page, type Locator, expect } from '@playwright/test';

export class FinOpsWastePanel {
  public readonly panel: Locator;
  public readonly title: Locator;
  public readonly metricOpportunities: Locator;
  public readonly metricSavings: Locator;
  public readonly highlightCards: Locator[];
  public readonly list: Locator; // PrActionList
  public readonly statusIndicator: Locator;

  constructor(private page: Page) {
    this.panel = page.getByTestId('finops-waste-panel');
    this.title = page.getByTestId('finops-waste-panel').getByRole('heading');
    this.metricOpportunities = page.getByTestId('finops-waste-panel').locator('.finops-panel__metric').first();
    this.metricSavings = page.getByTestId('finops-waste-panel').locator('.finops-panel__metric--accent');
    this.list = page.getByTestId('finops-panel-list');
    this.statusIndicator = page.getByTestId('finops-waste-panel').locator('.finops-panel__status');
    this.highlightCards = [];
  }

  async getHighlightCards(): Promise<Locator[]> {
    return page.getByTestId('finops-waste-panel').locator('[data-testid^="finops-highlight-"]').all();
  }

  async getPrCards(): Promise<Locator[]> {
    return page.getByTestId('finops-panel-list').locator('[data-testid^="pr-card-"]').all();
  }

  getGeneratePrBtn(cardTestId: string): Locator {
    return this.page.getByTestId(`${cardTestId}-generate-pr`);
  }

  getDismissBtn(cardTestId: string): Locator {
    return this.page.getByTestId(`${cardTestId}-dismiss`);
  }

  async clickGeneratePr(cardTestId: string): Promise<void> {
    await this.getGeneratePrBtn(cardTestId).click();
  }

  async clickDismiss(cardTestId: string): Promise<void> {
    await this.getDismissBtn(cardTestId).click();
  }

  getPullDownGroup(namespace: string): Locator {
    return this.page.getByTestId(`pr-card-group-${namespace}`);
  }

  async isPanelVisible(): Promise<boolean> {
    return this.panel.isVisible();
  }
}
