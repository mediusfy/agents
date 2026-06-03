<template>
  <div class="page">
    <TopBar title="Automations">
      <template #actions>
        <button class="btn btn--primary btn--small" data-testid="new-automation-btn">+ New Automation</button>
      </template>
    </TopBar>
    <div class="content">
      <div class="automations-grid" data-testid="automations-grid">
        <div class="automation-card" data-testid="automation-sync-watcher">
          <div class="automation-card__icon" style="background: var(--color-accent-light);">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="color: var(--color-accent); width: 18px; height: 18px;">
              <polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/>
            </svg>
          </div>
          <div class="automation-card__body">
            <h3>ArgoCD Sync Watcher</h3>
            <p>Monitors application sync status and exposes Prometheus metrics with app, namespace, and health labels.</p>
            <div class="automation-card__meta">
              <span class="pill pill--green">Active</span>
              <span class="pill pill--green">4 apps sync'd</span>
            </div>
          </div>
          <div class="automation-card__actions">
            <button class="btn btn--small">Edit</button>
            <button class="btn btn--small">Disable</button>
          </div>
        </div>

        <div class="automation-card" data-testid="automation-finops-scan">
          <div class="automation-card__icon" style="background: var(--color-success-bg);">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="color: var(--color-success-text); width: 18px; height: 18px;">
              <line x1="12" y1="1" x2="12" y2="23"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>
            </svg>
          </div>
          <div class="automation-card__body">
            <h3>FinOps Waste Scan</h3>
            <p>Every 30 minutes, scans Prometheus for over-provisioned workloads and generates right-sizing PRs.</p>
            <div class="automation-card__meta">
              <span class="pill pill--green">Auto</span>
              <span class="pill pill--orange">Schedule: */30 * * * *</span>
            </div>
          </div>
          <div class="automation-card__actions">
            <button class="btn btn--small">Edit</button>
            <button class="btn btn--small">Run Now</button>
          </div>
        </div>

        <div class="automation-card" data-testid="automation-anomstack-triage">
          <div class="automation-card__icon" style="background: var(--color-warning-bg);">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="color: var(--color-warning-text); width: 18px; height: 18px;">
              <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/>
            </svg>
          </div>
          <div class="automation-card__body">
            <h3>Anomstack Auto-Triage</h3>
            <p>Listens for anomaly alerts, deduplicates within 5m window, and dispatches agent triage commands.</p>
            <div class="automation-card__meta">
              <span class="pill pill--green">Active</span>
              <span class="pill pill--orange">23 alerts triaged today</span>
            </div>
          </div>
          <div class="automation-card__actions">
            <button class="btn btn--small">Edit</button>
            <button class="btn btn--small">Pause</button>
          </div>
        </div>
      </div>

      <div class="empty-state" style="margin-top: 24px;">
        <div class="empty-state__heading">Create custom automations</div>
        <div class="empty-state__body">Define new triggers and actions using the automation builder.</div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import TopBar from '../components/atoms/TopBar.vue';
</script>

<style scoped>
.page {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
}

.content {
  flex: 1;
  overflow-y: auto;
  padding: 24px;
  background: var(--color-surface-subtle);
}

.automations-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 16px;
}

.automation-card {
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-lg);
  padding: 20px;
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.automation-card__icon {
  width: 36px;
  height: 36px;
  border-radius: var(--radius-md);
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.automation-card__body h3 {
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary);
  margin-bottom: 4px;
}

.automation-card__body p {
  font-size: 12px;
  color: var(--color-text-tertiary);
  line-height: 1.4;
  margin-bottom: 8px;
}

.automation-card__meta {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}

.pill {
  display: inline-flex;
  align-items: center;
  font-size: 10px;
  padding: 2px 8px;
  border-radius: var(--radius-full);
  font-weight: 500;
}

.pill--green { background: var(--color-success-bg); color: var(--color-success-text); }
.pill--orange { background: var(--color-warning-bg); color: var(--color-warning-text); }

.automation-card__actions {
  display: flex;
  gap: 6px;
  margin-top: auto;
}
</style>
