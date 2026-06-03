<template>
  <div class="page">
    <TopBar title="Monitoring">
      <template #actions>
        <button class="btn btn--primary btn--small" data-testid="view-all-alerts">View All Alerts</button>
      </template>
    </TopBar>

    <div class="content">
      <!-- Alert Severity Summary Cards -->
      <div class="alert-summary" data-testid="alert-summary">
        <div class="alert-card alert-card--critical" data-testid="alert-critical">
          <div class="alert-card__severity">Critical</div>
          <div class="alert-card__count">3</div>
          <div class="alert-card__change">↑ 2 from yesterday</div>
        </div>
        <div class="alert-card alert-card--warning" data-testid="alert-warnings">
          <div class="alert-card__severity">Warnings</div>
          <div class="alert-card__count">12</div>
          <div class="alert-card__change">↑ 5 from yesterday</div>
        </div>
        <div class="alert-card alert-card--resolved" data-testid="alert-resolved">
          <div class="alert-card__severity">Resolved</div>
          <div class="alert-card__count">28</div>
          <div class="alert-card__change">Auto-resolved: 10</div>
        </div>
        <div class="alert-card alert-card--response" data-testid="alert-response">
          <div class="alert-card__severity">Avg Response</div>
          <div class="alert-card__count">2.4m</div>
          <div class="alert-card__change">↓ 12% from last week</div>
        </div>
      </div>

      <!-- Tabs -->
      <div class="tab-bar" role="tablist" data-testid="monitoring-tab-bar">
        <button
          v-for="tab in monitoringTabs"
          :key="tab.id"
          class="tab"
          :class="{ 'tab--active': activeTab === tab.id }"
          role="tab"
          :aria-selected="activeTab === tab.id"
          :data-testid="`monitoring-tab-${tab.id}`"
          @click="activeTab = tab.id"
        >
          {{ tab.label }}
        </button>
      </div>

      <!-- Alerts Table -->
      <div class="alerts-table" data-testid="alerts-table" v-if="activeTab === 'alerts'">
        <!-- Search/Filter Bar -->
        <div class="filter-bar">
          <div class="filter-bar__search">
            <svg viewBox="0 0 24 24" class="filter-bar__search-icon" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>
            </svg>
            <input v-model="alertSearch" type="text" class="filter-bar__input" placeholder="Search alerts..." data-testid="alert-search" />
          </div>
        </div>

        <div class="table-row table-row--header">
          <div class="table-cell table-cell--sev">Severity</div>
          <div class="table-cell table-cell--name">Name</div>
          <div class="table-cell table-cell--status">Status</div>
          <div class="table-cell table-cell--source">Source</div>
          <div class="table-cell table-cell--value">Value</div>
          <div class="table-cell table-cell--time">Time</div>
        </div>

        <div
          v-for="alert in filteredAlerts"
          :key="alert.id"
          class="table-row"
          :data-testid="`alert-row-${alert.id}`"
        >
          <div class="table-cell table-cell--sev">
            <span class="severity-badge" :class="`severity-badge--${alert.severity}`">
              <span class="sdot" :class="alert.severity === 'critical' ? 'red' : alert.severity === 'warning' ? 'orange' : 'green'"></span>
              {{ alert.severity }}
            </span>
          </div>
          <div class="table-cell"><strong>{{ alert.name }}</strong></div>
          <div class="table-cell">
            <span class="status-badge" :class="`status-badge--${alert.statusClass}`">{{ alert.status }}</span>
          </div>
          <div class="table-cell">{{ alert.source }}</div>
          <div class="table-cell">{{ alert.value }}</div>
          <div class="table-cell table-cell--muted">{{ alert.time }}</div>
        </div>
      </div>

      <!-- STRATEGY THEME 2: FinOps Tab -->
      <div v-if="activeTab === 'finops'" class="finops-section" data-testid="finops-tab-section">
        <FinOpsWastePanel />
      </div>

      <!-- STRATEGY THEME 1 + 3: AI Diagnostics -->
      <div v-if="featureFlags.agentAutonomy.value" class="ai-diagnostics" data-testid="ai-diagnostics">
        <div class="ai-diagnostics__header">
          <div class="ai-diagnostics__icon">🤖</div>
          <div>
            <h3 class="ai-diagnostics__title">AI Diagnostics</h3>
            <p class="ai-diagnostics__subtitle">Background watcher agents have already gathered these logs and diagnostics.</p>
          </div>
        </div>
        <div class="ai-diagnostics__items">
          <div class="diag-item" data-testid="diag-memory-pressure">
            <div class="diag-item__severity sdot red"></div>
            <div class="diag-item__content">
              <strong>Memory pressure in kube-system</strong>
              <p>Node ip-10-0-1-45 is at 94% memory utilization. Top consumer: fluentd (3.2Gi / 4Gi limit).</p>
              <div class="diag-item__actions">
                <button class="btn btn--small" data-testid="diagnose-btn">Diagnose</button>
                <button class="btn btn--primary btn--small" data-testid="generate-pr-btn">Generate PR →</button>
              </div>
            </div>
          </div>
          <div class="diag-item" data-testid="diag-cpu-throttling">
            <div class="diag-item__severity sdot orange"></div>
            <div class="diag-item__content">
              <strong>CPU throttling on api-gateway</strong>
              <p>Container api-gateway-7f8b9 is throttled 14% of the time. Actual CPU usage: 480m vs request: 2000m.</p>
              <div class="diag-item__actions">
                <button class="btn btn--small" data-testid="diagnose-btn">Diagnose</button>
                <button class="btn btn--primary btn--small" data-testid="generate-pr-btn">Generate PR →</button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue';
import TopBar from '../components/atoms/TopBar.vue';
import FinOpsWastePanel from '../components/organisms/FinOpsWastePanel.vue';
import { useFeatureFlags } from '../composables/useFeatureFlags';

const featureFlags = useFeatureFlags();
const activeTab = ref('alerts');
const alertSearch = ref('');

const monitoringTabs = [
  { id: 'alerts', label: 'Alerts' },
  { id: 'finops', label: 'FinOps' },
  { id: 'events', label: 'Events' },
  { id: 'traces', label: 'Traces' },
];

const alerts = [
  { id: 'a1', severity: 'critical', name: 'High memory pressure kube-system', status: 'Active', statusClass: 'active', source: 'prometheus', value: '94.2%', time: '2m ago' },
  { id: 'a2', severity: 'critical', name: 'NodeNotReady ip-10-0-1-47', status: 'Active', statusClass: 'active', source: 'kubelet', value: '5m', time: '5m ago' },
  { id: 'a3', severity: 'critical', name: 'CrashLoopBackOff api-gateway', status: 'Active', statusClass: 'active', source: 'kube-state', value: '12 restarts', time: '8m ago' },
  { id: 'a4', severity: 'warning', name: 'CPU throttling api-gateway', status: 'Acknowledged', statusClass: 'acknowledged', source: 'prometheus', value: '14.2%', time: '12m ago' },
  { id: 'a5', severity: 'warning', name: 'Pod Pending kafka-broker-0', status: 'Acknowledged', statusClass: 'acknowledged', source: 'kube-state', value: '30m', time: '30m ago' },
  { id: 'a6', severity: 'info', name: 'Deployment rollout orders-svc', status: 'Resolved', statusClass: 'resolved', source: 'argo-cd', value: 'Success', time: '1h ago' },
];

const filteredAlerts = computed(() => {
  if (!alertSearch.value) return alerts;
  const q = alertSearch.value.toLowerCase();
  return alerts.filter((a) => a.name.toLowerCase().includes(q) || a.severity.includes(q));
});
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

/* Alert summary cards */
.alert-summary {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 12px;
  margin-bottom: 20px;
}

.alert-card {
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-lg);
  padding: 16px 20px;
}

.alert-card__severity {
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  margin-bottom: 4px;
}

.alert-card__count {
  font-size: 28px;
  font-weight: 700;
  color: var(--color-text-primary);
}

.alert-card__change {
  font-size: 10px;
  margin-top: 2px;
}

.alert-card--critical .alert-card__severity { color: var(--color-danger); }
.alert-card--critical .alert-card__change { color: var(--color-danger-text); }
.alert-card--warning .alert-card__severity { color: var(--color-warning-text); }
.alert-card--warning .alert-card__change { color: var(--color-warning-text); }
.alert-card--resolved .alert-card__severity { color: var(--color-success-text); }
.alert-card--resolved .alert-card__change { color: var(--color-success-text); }
.alert-card--response .alert-card__severity { color: var(--color-accent); }
.alert-card--response .alert-card__change { color: var(--color-accent); }

/* Tab bar */
.tab-bar {
  display: flex;
  margin-bottom: 16px;
  border-bottom: 1px solid var(--color-border-light);
}

.tab {
  padding: 8px 16px;
  font-size: 12px;
  font-weight: 500;
  color: var(--color-text-tertiary);
  background: none;
  border: none;
  cursor: pointer;
  font-family: inherit;
  position: relative;
}

.tab:hover { color: var(--color-text-primary); }
.tab--active { color: var(--color-accent); font-weight: 600; }
.tab--active::after {
  content: '';
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 2px;
  background: var(--color-accent);
}
.tab:focus-visible { outline: 2px solid var(--color-accent); outline-offset: -2px; }

/* Filter bar */
.filter-bar {
  display: flex;
  gap: 8px;
  margin-bottom: 12px;
}

.filter-bar__search {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 12px;
  border: 1px solid var(--color-border-input);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  flex: 1;
  max-width: 280px;
}

.filter-bar__search-icon { color: var(--color-text-muted); }

.filter-bar__input {
  border: none;
  background: none;
  font-size: 12px;
  font-family: inherit;
  color: var(--color-text-primary);
  outline: none;
  width: 100%;
}

/* Table */
.alerts-table {
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-lg);
  overflow: hidden;
  margin-bottom: 20px;
}

.table-row {
  display: grid;
  grid-template-columns: 90px minmax(200px, 1fr) 110px 100px 100px 80px;
  align-items: center;
  padding: 0 16px;
  border-bottom: 1px solid #F3F3F5;
  font-size: 12px;
}

.table-row:last-child { border-bottom: none; }

.table-row--header {
  background: var(--color-surface-subtle);
  font-size: 11px;
  font-weight: 600;
  color: var(--color-text-tertiary);
  text-transform: uppercase;
}

.table-row--header .table-cell { padding: 10px 4px; }

.table-cell { padding: 8px 4px; }
.table-cell--muted { color: var(--color-text-muted); }

.severity-badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 11px;
  font-weight: 500;
  text-transform: capitalize;
}

.severity-badge--critical { color: var(--color-danger-text); }
.severity-badge--warning { color: var(--color-warning-text); }
.severity-badge--info { color: var(--color-success-text); }

.status-badge {
  font-size: 11px;
  font-weight: 500;
  padding: 2px 8px;
  border-radius: 4px;
}

.status-badge--active { background: var(--color-danger-bg); color: var(--color-danger-text); }
.status-badge--acknowledged { background: var(--color-warning-bg); color: var(--color-warning-text); }
.status-badge--resolved { background: var(--color-success-bg); color: var(--color-success-text); }

/* FinOps tab section */
.finops-section {
  margin-bottom: 20px;
}

/* AI Diagnostics */
.ai-diagnostics {
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-lg);
  padding: 20px;
  margin-bottom: 20px;
}

.ai-diagnostics__header {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  margin-bottom: 16px;
}

.ai-diagnostics__icon {
  font-size: 24px;
  flex-shrink: 0;
}

.ai-diagnostics__title {
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary);
}

.ai-diagnostics__subtitle {
  font-size: 11px;
  color: var(--color-text-tertiary);
  margin-top: 2px;
}

.diag-item {
  display: flex;
  gap: 10px;
  padding: 12px 0;
  border-bottom: 1px solid #F3F3F5;
}

.diag-item:last-child { border-bottom: none; }

.diag-item__severity {
  margin-top: 4px;
  flex-shrink: 0;
}

.diag-item__content {
  flex: 1;
  font-size: 12px;
  color: var(--color-text-secondary);
  line-height: 1.5;
}

.diag-item__content p {
  font-size: 11px;
  color: var(--color-text-tertiary);
  margin-top: 2px;
}

.diag-item__actions {
  display: flex;
  gap: 6px;
  margin-top: 8px;
}
</style>
