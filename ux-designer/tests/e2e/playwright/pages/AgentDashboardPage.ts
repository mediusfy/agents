// Page Object Model for Agent Dashboard

import { type Page, type Locator } from '@playwright/test';

export class AgentDashboardPage {
  public readonly dashboard: Locator;
  public readonly metrics: Locator;

  constructor(private page: Page) {
    this.dashboard = page.getByTestId('agent-dashboard');
    this.metrics = page.getByTestId('agent-dashboard').locator('.agent-dashboard__metrics');
  }

  getAgentBadge(agentName: string): Locator {
    return this.page.getByTestId(`agent-badge-${agentName}`);
  }

  async getAgentBadges(): Promise<Locator[]> {
    return this.dashboard.locator('[data-testid^="agent-badge-"]').all();
  }

  getFeed(): Locator {
    return this.page.getByTestId('agent-dashboard-feed');
  }

  async selectAgent(agentName: string): Promise<void> {
    await this.getAgentBadge(agentName).click();
  }

  async getSelectedAgentName(): Promise<string | null> {
    const selected = this.dashboard.locator('.agent-badge--selected');
    return selected.isVisible().then(v => v ? selected.getByTestId(/agent-badge-/).getAttribute('data-testid') : null);
  }

  async isDashboardVisible(): Promise<boolean> {
    return this.dashboard.isVisible();
  }
}
