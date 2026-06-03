# Playwright E2E Tests

Covers three frontend feature areas:
- `@FIN-OPS-01` — FinOps Waste Panel (PR cards, cost display, generate/dismiss actions)
- `@AGENTS-01` — Agent Dashboard (badge grid, status, activity feed, selection)
- `@RUNBOOKS-01` — Runbook Viewer (block display, execution, terminal drawer, copy)

## Running Tests

```bash
# Install dependencies
npm install -D @playwright/test
npx playwright install chromium

# Run all tests
npx playwright test

# Run specific tag
npx playwright test --grep @FIN-OPS-01

# Run with UI mode
npx playwright test --ui

# Run with trace on failure
npx playwright test --trace on
```

## Test Architecture

- **Page Object Model** in `pages/` — one POM per feature area
- **Test specs** in `specs/` — one spec per feature area
- **Fixtures/mock data** in `fixtures/` — reusable test data
- **Route interception** for all API calls — no backend required
- **data-testid** selectors throughout — no CSS class dependencies

## Test Patterns

All tests follow these conventions:
1. Route interception for API mocking in `beforeEach`
2. Page Object Model methods for all interactions
3. `data-testid` selectors only (never CSS classes)
4. Playwright auto-waiting — no `waitForTimeout`
5. Tests are independent and parallelizable
