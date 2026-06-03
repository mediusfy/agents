// Page Object Model for Runbook Viewer + Terminal Drawer

import { type Page, type Locator } from '@playwright/test';

export class RunbookViewerPage {
  public readonly viewer: Locator;

  constructor(private page: Page) {
    this.viewer = page.getByTestId('runbook-viewer');
  }

  getRunbookCard(runbookPath: string): Locator {
    return this.page.getByTestId(`runbook-card-${runbookPath}`);
  }

  getBlock(blockId: string): Locator {
    return this.page.getByTestId(`runbook-block-${blockId}`);
  }

  getExecuteBtn(blockId: string): Locator {
    return this.page.getByTestId(`runbook-execute-${blockId}`);
  }

  getCopyBtn(blockId: string): Locator {
    return this.page.getByTestId(`runbook-copy-${blockId}`);
  }

  getTerminal(): Locator {
    return this.page.getByTestId('runbook-terminal');
  }

  async openRunbook(path: string): Promise<void> {
    await this.getRunbookCard(path).click();
  }

  async executeBlock(blockId: string): Promise<void> {
    await this.getExecuteBtn(blockId).click();
  }

  async copyBlock(blockId: string): Promise<void> {
    await this.getCopyBtn(blockId).click();
  }

  async isTerminalOpen(): Promise<boolean> {
    return this.getTerminal().isVisible();
  }

  async selectRunbook(blockId: string): Promise<void> {
    await this.getBlock(blockId).click();
  }

  async isViewerVisible(): Promise<boolean> {
    return this.viewer.isVisible();
  }
}
