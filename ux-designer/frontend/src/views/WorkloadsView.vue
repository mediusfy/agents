<template>
  <div class="page">
    <TopBar title="Workloads">
      <template #actions>
        <button class="btn btn--primary btn--small" aria-label="Create new Deployment" data-testid="create-deployment-btn">
          + Create
        </button>
      </template>
    </TopBar>

    <div class="content">
      <!-- Tab Bar: Resource Types -->
      <div class="tab-bar" role="tablist" data-testid="workload-tab-bar">
        <button
          v-for="tab in resourceTabs"
          :key="tab.id"
          class="tab"
          :class="{ 'tab--active': activeResourceTab === tab.id }"
          role="tab"
          :aria-selected="activeResourceTab === tab.id"
          :data-testid="`workload-tab-${tab.id}`"
          @click="activeResourceTab = tab.id"
        >
          {{ tab.label }}
        </button>
      </div>

      <!-- Filter Bar -->
      <div class="filter-bar" data-testid="filter-bar">
        <div class="filter-bar__search">
          <svg viewBox="0 0 24 24" class="filter-bar__search-icon" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>
          </svg>
          <input
            v-model="searchQuery"
            type="text"
            class="filter-bar__input"
            placeholder="Search workloads..."
            aria-label="Search workloads"
            data-testid="workload-search"
          />
        </div>
        <select v-model="namespaceFilter" class="filter-bar__select" aria-label="Filter by namespace" data-testid="workload-namespace-filter">
          <option value="">All Namespaces</option>
          <option v-for="ns in namespaces" :key="ns" :value="ns">{{ ns }}</option>
        </select>
        <select v-model="statusFilter" class="filter-bar__select" aria-label="Filter by status" data-testid="workload-status-filter">
          <option value="">All Statuses</option>
          <option value="running">Running</option>
          <option value="pending">Pending</option>
          <option value="failed">Failed</option>
          <option value="crashloop">CrashLoopBackOff</option>
        </select>
      </div>

      <!-- Workloads Table -->
      <div class="workloads-table" data-testid="workloads-table">
        <!-- Table Header -->
        <div class="table-row table-row--header" data-testid="table-header">
          <div class="table-cell table-cell--name" @click="sortBy('name')">Name</div>
          <div class="table-cell table-cell--ns" @click="sortBy('namespace')">Namespace</div>
          <div class="table-cell table-cell--status" @click="sortBy('status')">Status</div>
          <div class="table-cell table-cell--cpu" @click="sortBy('cpu')">CPU</div>
          <div class="table-cell table-cell--memory" @click="sortBy('memory')">Memory</div>
          <div class="table-cell table-cell--restarts">Restarts</div>
          <div class="table-cell table-cell--age">Age</div>
          <div class="table-cell table-cell--actions">Actions</div>
        </div>

        <!-- Loading -->
        <div v-if="loading" class="table-loading" data-testid="table-loading">
          <div v-for="i in 4" :key="i" class="skeleton skeleton--text" style="width: 90%; margin: 12px auto;"></div>
        </div>

        <!-- Empty State -->
        <div v-else-if="filteredWorkloads.length === 0" class="empty-state" data-testid="table-empty">
          <div class="empty-state__heading">No workloads found</div>
          <div class="empty-state__body">Try adjusting your search or filter criteria.</div>
        </div>

        <!-- Error State -->
        <div v-else-if="error" class="error-state" data-testid="table-error">
          <div class="error-state__message">Failed to load workloads</div>
          <button class="btn btn--small" @click="loadWorkloads" data-testid="retry-btn">Retry</button>
        </div>

        <!-- Table Body -->
        <div v-else class="table-body">
          <div
            v-for="wl in filteredWorkloads"
            :key="wl.name"
            class="table-row"
            :data-testid="`workload-row-${wl.name}`"
          >
            <div class="table-cell table-cell--name">
              <strong>{{ wl.name }}</strong>
            </div>
            <div class="table-cell table-cell--ns">
              <span class="ns-badge">{{ wl.namespace }}</span>
            </div>
            <div class="table-cell table-cell--status">
              <span class="status-badge" :class="`status-badge--${wl.statusClass}`">
                <span class="sdot" :class="wl.statusDot"></span>
                {{ wl.status }}
              </span>
            </div>
            <div class="table-cell table-cell--cpu">{{ wl.cpu }}</div>
            <div class="table-cell table-cell--memory">{{ wl.memory }}</div>
            <div class="table-cell table-cell--restarts">{{ wl.restarts }}</div>
            <div class="table-cell table-cell--age">{{ wl.age }}</div>
            <div class="table-cell table-cell--actions">
              <button class="btn btn--small" :aria-label="`Diagnose ${wl.name}`" :data-testid="`diagnose-${wl.name}`">Diagnose</button>
              <button class="btn btn--small" :aria-label="`Debug ${wl.name}`" :data-testid="`debug-${wl.name}`">Debug</button>
            </div>
          </div>
        </div>
      </div>

      <!-- STRATEGY THEME 1: Inline GitOps PR Card (shown for problem pods) -->
      <div v-if="featureFlags.gitopsPrs.value" class="strategy-section" data-testid="gitops-prs-section">
        <h3 class="section-title">Remediation Candidates</h3>
        <FinOpsWastePanel v-if="isFinOpsMounted" />
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
const isFinOpsMounted = ref(true);

const activeResourceTab = ref('pods');
const searchQuery = ref('');
const namespaceFilter = ref('');
const statusFilter = ref('');
const sortField = ref('');
const sortDir = ref<'asc' | 'desc'>('asc');
const loading = ref(false);
const error = ref(false);

const resourceTabs = [
  { id: 'pods', label: 'Pods' },
  { id: 'deployments', label: 'Deployments' },
  { id: 'statefulsets', label: 'StatefulSets' },
  { id: 'daemonsets', label: 'DaemonSets' },
  { id: 'jobs', label: 'Jobs' },
  { id: 'cronjobs', label: 'Cron Jobs' },
];

const namespaces = ['default', 'kube-system', 'api', 'data', 'logging', 'monitoring'];

const workloads = [
  { name: 'api-gateway-7f8b9', namespace: 'api', status: 'Running', statusClass: 'running', statusDot: 'green', cpu: '1.2', memory: '512Mi', restarts: 0, age: '12d' },
  { name: 'api-gateway-6e3a1', namespace: 'api', status: 'CrashLoopBackOff', statusClass: 'crashloop', statusDot: 'red', cpu: '0.5', memory: '256Mi', restarts: 12, age: '3h' },
  { name: 'redis-cache-0', namespace: 'data', status: 'Running', statusClass: 'running', statusDot: 'green', cpu: '0.8', memory: '3.2Gi', restarts: 0, age: '45d' },
  { name: 'redis-cache-1', namespace: 'data', status: 'Running', statusClass: 'running', statusDot: 'green', cpu: '0.7', memory: '2.8Gi', restarts: 1, age: '45d' },
  { name: 'fluentd-5j8k2', namespace: 'logging', status: 'Running', statusClass: 'running', statusDot: 'green', cpu: '0.3', memory: '1.8Gi', restarts: 0, age: '7d' },
  { name: 'kafka-broker-0', namespace: 'data', status: 'Pending', statusClass: 'pending', statusDot: 'orange', cpu: '4.0', memory: '16Gi', restarts: 0, age: '2h' },
  { name: 'nginx-ingress-2x4n9', namespace: 'default', status: 'Running', statusClass: 'running', statusDot: 'green', cpu: '0.6', memory: '384Mi', restarts: 0, age: '30d' },
];

const filteredWorkloads = computed(() => {
  let result = [...workloads];

  if (searchQuery.value) {
    const q = searchQuery.value.toLowerCase();
    result = result.filter((w) => w.name.toLowerCase().includes(q));
  }
  if (namespaceFilter.value) {
    result = result.filter((w) => w.namespace === namespaceFilter.value);
  }
  if (statusFilter.value) {
    result = result.filter((w) => w.statusClass === statusFilter.value);
  }

  if (sortField.value) {
    result.sort((a, b) => {
      const aVal = (a as any)[sortField.value];
      const bVal = (b as any)[sortField.value];
      const cmp = typeof aVal === 'string' ? aVal.localeCompare(bVal) : aVal - bVal;
      return sortDir.value === 'asc' ? cmp : -cmp;
    });
  }

  return result;
});

function sortBy(field: string) {
  if (sortField.value === field) {
    sortDir.value = sortDir.value === 'asc' ? 'desc' : 'asc';
  } else {
    sortField.value = field;
    sortDir.value = 'asc';
  }
}

function loadWorkloads() {
  // Reset for real usage
  error.value = false;
}
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

/* Tab bar */
.tab-bar {
  display: flex;
  gap: 0;
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
  transition: color var(--transition-fast);
}

.tab:hover { color: var(--color-text-primary); }

.tab--active {
  color: var(--color-accent);
  font-weight: 600;
}

.tab--active::after {
  content: '';
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 2px;
  background: var(--color-accent);
}

.tab:focus-visible {
  outline: 2px solid var(--color-accent);
  outline-offset: -2px;
}

/* Filter bar */
.filter-bar {
  display: flex;
  gap: 8px;
  margin-bottom: 16px;
  align-items: center;
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

.filter-bar__search-icon {
  color: var(--color-text-muted);
  flex-shrink: 0;
}

.filter-bar__input {
  border: none;
  background: none;
  font-size: 12px;
  font-family: inherit;
  color: var(--color-text-primary);
  outline: none;
  width: 100%;
}

.filter-bar__input::placeholder {
  color: var(--color-text-muted);
}

.filter-bar__select {
  padding: 6px 10px;
  border: 1px solid var(--color-border-input);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  font-size: 12px;
  font-family: inherit;
  color: var(--color-text-secondary);
  cursor: pointer;
}

.filter-bar__select:focus-visible {
  outline: 2px solid var(--color-accent);
  outline-offset: 2px;
}

/* Table */
.workloads-table {
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-lg);
  overflow: hidden;
  margin-bottom: 20px;
}

.table-row {
  display: grid;
  grid-template-columns: minmax(180px, 2fr) 120px 120px 80px 100px 70px 80px auto;
  align-items: center;
  gap: 0;
  padding: 0 16px;
  border-bottom: 1px solid #F3F3F5;
  font-size: 12px;
}

.table-row:last-child {
  border-bottom: none;
}

.table-row--header {
  background: var(--color-surface-subtle);
  font-size: 11px;
  font-weight: 600;
  color: var(--color-text-tertiary);
  text-transform: uppercase;
  letter-spacing: 0.03em;
}

.table-row--header .table-cell {
  padding: 10px 4px;
  cursor: pointer;
  user-select: none;
}

.table-row--header .table-cell:hover {
  color: var(--color-text-primary);
}

.table-cell {
  padding: 8px 4px;
}

.table-cell--actions {
  display: flex;
  gap: 4px;
}

/* Status badges */
.status-badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 11px;
  font-weight: 500;
}

.status-badge--running { color: var(--color-success-text); }
.status-badge--pending { color: var(--color-warning-text); }
.status-badge--failed { color: var(--color-danger-text); }
.status-badge--crashloop { color: var(--color-danger-text); }

.ns-badge {
  font-size: 10px;
  padding: 2px 6px;
  border-radius: 4px;
  background: var(--color-surface-subtle);
  color: var(--color-text-tertiary);
  font-weight: 500;
}

/* Strategy section */
.strategy-section {
  margin-bottom: 20px;
}

.section-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--color-text-primary);
  margin-bottom: 8px;
}

/* Skeleton */
.skeleton {
  background: var(--color-border);
  border-radius: var(--radius-sm);
  animation: pulse 1.5s ease-in-out infinite;
}

@keyframes pulse {
  0%, 100% { opacity: 0.6; }
  50% { opacity: 1; }
}
</style>
