<template>
  <div class="page">
    <TopBar title="Agents">
      <template #actions>
        <button class="btn btn--primary btn--small" aria-label="Create new agent" data-testid="create-agent-btn">
          + Create Agent
        </button>
      </template>
    </TopBar>

    <div class="content">
      <!-- Welcome Banner -->
      <div class="welcome-banner" data-testid="agents-welcome">
        <div class="welcome-banner__info">
          <h2 class="welcome-banner__title">Agent Fleet</h2>
          <p class="welcome-banner__subtitle">5 agents deployed · 4 healthy · 0 critical · 2 active today</p>
        </div>
        <div class="welcome-banner__pills">
          <span class="pill pill--green">4 Healthy</span>
          <span class="pill pill--orange">1 Running</span>
          <span class="pill pill--green">Idle</span>
        </div>
      </div>

      <!-- Metrics Bar -->
      <div class="metrics-bar" data-testid="agent-metrics">
        <div class="metric" data-testid="metric-agent-count">
          <span class="metric__value">5</span>
          <span class="metric__label">Agents</span>
        </div>
        <div class="metric" data-testid="metric-total-cpu">
          <span class="metric__value">2.4</span>
          <span class="metric__label">Total CPU</span>
        </div>
        <div class="metric" data-testid="metric-total-memory">
          <span class="metric__value">8.2Gi</span>
          <span class="metric__label">Total Memory</span>
        </div>
        <div class="metric" data-testid="metric-savings-month">
          <span class="metric__value">$1,240</span>
          <span class="metric__label">Savings / month</span>
        </div>
      </div>

      <!-- Tab Filter -->
      <div class="tab-bar" role="tablist" data-testid="agent-tab-bar">
        <button
          v-for="tab in agentTabs"
          :key="tab.id"
          class="tab"
          :class="{ 'tab--active': activeTab === tab.id }"
          role="tab"
          :aria-selected="activeTab === tab.id"
          :data-testid="`agent-tab-${tab.id}`"
          @click="activeTab = tab.id"
        >
          {{ tab.label }}
        </button>
      </div>

      <!-- Agent Cards Grid (3 columns) -->
      <div class="agent-grid" data-testid="agent-grid">
        <div
          v-for="agent in filteredAgents"
          :key="agent.name"
          class="agent-card"
          :data-testid="`agent-card-${agent.name}`"
        >
          <div class="agent-card__header">
            <div class="agent-card__avatar" :style="{ background: agent.avatarBg }">
              {{ agent.name.charAt(0).toUpperCase() }}
            </div>
            <div>
              <div class="agent-card__name">{{ agent.name }}</div>
              <span class="agent-card__status" :class="`agent-card__status--${agent.statusDot}`">
                <span class="sdot" :class="agent.statusDot"></span>
                {{ agent.statusLabel }}
              </span>
            </div>
          </div>
          <p class="agent-card__desc">{{ agent.description }}</p>
          <div class="agent-card__metrics">
            <div class="agent-card__metric">
              <span class="agent-card__metric-value">{{ agent.cpu }}</span>
              <span class="agent-card__metric-label">CPU</span>
            </div>
            <div class="agent-card__metric">
              <span class="agent-card__metric-value">{{ agent.memory }}</span>
              <span class="agent-card__metric-label">Memory</span>
            </div>
            <div class="agent-card__metric">
              <span class="agent-card__metric-value">{{ agent.scopeCount }}</span>
              <span class="agent-card__metric-label">Scope</span>
            </div>
          </div>
          <div class="agent-card__actions">
            <button class="btn btn--small" aria-label="Pause agent" :data-testid="`agent-pause-${agent.name}`">
              Pause
            </button>
            <button class="btn btn--small" aria-label="Restart agent" :data-testid="`agent-restart-${agent.name}`">
              Restart
            </button>
            <button class="btn btn--small" aria-label="View logs" :data-testid="`agent-logs-${agent.name}`">
              Logs
            </button>
          </div>
        </div>
      </div>

      <!-- STRATEGY THEME 3: Agent Activity Feed -->
      <div v-if="featureFlags.agentAutonomy.value" class="activity-section" data-testid="agent-activity-section">
        <h3 class="section-title">Recent Agent Activity</h3>
        <div class="activity-feed" data-testid="agent-activity-feed">
          <div v-for="item in agentActivity" :key="item.id" class="feed-item" :data-testid="`feed-${item.id}`">
            <div class="feed-item__dot" :class="item.severity"></div>
            <div class="feed-item__content">
              <div class="feed-item__header">
                <strong>{{ item.agent }}</strong> <span class="feed-item__action">{{ item.action }}</span>
                <span class="feed-item__time">{{ item.time }}</span>
              </div>
              <p class="feed-item__detail">{{ item.detail }}</p>
            </div>
          </div>
        </div>
      </div>

      <!-- Data & Privacy Footer -->
      <div class="privacy-bar" data-testid="privacy-bar">
        <span>🔒</span>
        <span>Data & Privacy: All agent actions are logged and auditable. Agent scopes are restricted to assigned namespaces.</span>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue';
import TopBar from '../components/atoms/TopBar.vue';
import { useFeatureFlags } from '../composables/useFeatureFlags';

const featureFlags = useFeatureFlags();
const activeTab = ref('all');

const agentTabs = [
  { id: 'all', label: 'All Agents' },
  { id: 'watchers', label: 'Watchers' },
  { id: 'schedulers', label: 'Schedulers' },
  { id: 'analyzers', label: 'Analyzers' },
  { id: 'integrations', label: 'Integrations' },
];

const agents = [
  {
    name: 'SRE Agent',
    type: 'analyzers',
    avatarBg: 'linear-gradient(135deg, #6C31FF, #8A5CFF)',
    statusDot: 'green',
    statusLabel: 'Healthy',
    description: 'GitOps remediation, Terraform apply, infrastructure drift detection.',
    cpu: '480m',
    memory: '1.6Gi',
    scopeCount: 8,
  },
  {
    name: 'Backend Agent',
    type: 'analyzers',
    avatarBg: 'linear-gradient(135deg, #00C875, #34C759)',
    statusDot: 'green',
    statusLabel: 'Healthy',
    description: 'Go hexagonal architecture, gRPC scaffolding, database migration generation.',
    cpu: '320m',
    memory: '2.1Gi',
    scopeCount: 12,
  },
  {
    name: 'Frontend Agent',
    type: 'integrations',
    avatarBg: 'linear-gradient(135deg, #FFAD42, #FF9500)',
    statusDot: 'orange',
    statusLabel: 'Running',
    description: 'Vue 3 Composition API, Tailwind component generation, Storybook stories.',
    cpu: '560m',
    memory: '1.8Gi',
    scopeCount: 6,
  },
  {
    name: 'DevOps Agent',
    type: 'schedulers',
    avatarBg: 'linear-gradient(135deg, #D93025, #C5221F)',
    statusDot: 'green',
    statusLabel: 'Healthy',
    description: 'GitHub Actions, Docker Compose, ArgoCD sync, Helm chart generation.',
    cpu: '240m',
    memory: '1.2Gi',
    scopeCount: 10,
  },
  {
    name: 'Security Agent',
    type: 'watchers',
    avatarBg: 'linear-gradient(135deg, #6C31FF, #4A1FBF)',
    statusDot: 'green',
    statusLabel: 'Idle',
    description: 'CVE scanning, secrets detection, dependency auditing, compliance checks.',
    cpu: '800m',
    memory: '1.5Gi',
    scopeCount: 14,
  },
];

const filteredAgents = computed(() => {
  if (activeTab.value === 'all') return agents;
  return agents.filter((a) => a.type === activeTab.value);
});

const agentActivity = [
  {
    id: 'act-1',
    agent: 'SRE Agent',
    action: 'auto-triaged alert: Memory pressure kube-system',
    detail: '→ pulled logs, checked recent sync → placed root-cause summary → generated remediation PR (#247)',
    time: '2m ago',
    severity: 'purple',
  },
  {
    id: 'act-2',
    agent: 'Backend Agent',
    action: 'scaffolded orders-svc (Go hexagonal)',
    detail: '→ generated 6 files, passed go vet, PR #248 opened',
    time: '4m ago',
    severity: 'green',
  },
  {
    id: 'act-3',
    agent: 'Security Agent',
    action: 'completed scheduled vulnerability scan',
    detail: '→ 14 services scanned, 0 critical, 3 medium (all in known CVEs list)',
    time: '2h ago',
    severity: 'purple',
  },
  {
    id: 'act-4',
    agent: 'DevOps Agent',
    action: 'published pipeline for api-gateway',
    detail: '→ build #1291: Go test pass, Docker push pass, image tag: abc1234',
    time: '12m ago',
    severity: 'green',
  },
];
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

/* Welcome */
.welcome-banner {
  display: flex;
  align-items: center;
  background: var(--color-surface);
  border-radius: var(--radius-xl);
  border: 1px solid var(--color-border);
  padding: 16px 24px;
  margin-bottom: 20px;
  gap: 16px;
}

.welcome-banner__info {
  flex: 1;
}

.welcome-banner__title {
  font-size: 16px;
  font-weight: 600;
  color: var(--color-text-primary);
}

.welcome-banner__subtitle {
  font-size: 12px;
  color: #888;
  margin-top: 2px;
}

.welcome-banner__pills {
  display: flex;
  gap: 6px;
}

.pill {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 3px 10px;
  border-radius: var(--radius-full);
  font-size: 11px;
  font-weight: 500;
}

.pill--green { background: var(--color-success-bg); color: var(--color-success-text); }
.pill--orange { background: var(--color-warning-bg); color: var(--color-warning-text); }

/* Metrics */
.metrics-bar {
  display: flex;
  gap: 12px;
  margin-bottom: 20px;
}

.metric {
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 10px 16px;
  border-radius: var(--radius-md);
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  flex: 1;
}

.metric__value {
  font-size: 20px;
  font-weight: 700;
  color: var(--color-text-primary);
}

.metric__label {
  font-size: 11px;
  color: var(--color-text-tertiary);
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

.tab:hover {
  color: var(--color-text-primary);
}

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

/* Agent card grid */
.agent-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 16px;
  margin-bottom: 24px;
}

.agent-card {
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-lg);
  padding: 20px;
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.agent-card__header {
  display: flex;
  align-items: center;
  gap: 12px;
}

.agent-card__avatar {
  width: 36px;
  height: 36px;
  border-radius: var(--radius-md);
  display: flex;
  align-items: center;
  justify-content: center;
  color: #fff;
  font-weight: 700;
  font-size: 14px;
  flex-shrink: 0;
}

.agent-card__name {
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary);
}

.agent-card__status {
  display: flex;
  align-items: center;
  gap: 4px;
  font-size: 11px;
}

.agent-card__status--green { color: var(--color-success-text); }
.agent-card__status--orange { color: var(--color-warning-text); }

.agent-card__desc {
  font-size: 12px;
  color: var(--color-text-tertiary);
  line-height: 1.4;
}

.agent-card__metrics {
  display: flex;
  gap: 8px;
}

.agent-card__metric {
  flex: 1;
  padding: 8px;
  background: var(--color-surface-subtle);
  border-radius: var(--radius-sm);
  text-align: center;
}

.agent-card__metric-value {
  display: block;
  font-size: 13px;
  font-weight: 600;
  color: var(--color-text-primary);
}

.agent-card__metric-label {
  display: block;
  font-size: 10px;
  color: var(--color-text-muted);
  margin-top: 1px;
}

.agent-card__actions {
  display: flex;
  gap: 6px;
  margin-top: auto;
}

/* Activity section */
.activity-section {
  margin-bottom: 20px;
}

.section-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--color-text-primary);
  margin-bottom: 8px;
}

.activity-feed {
  background: var(--color-surface);
  border-radius: var(--radius-lg);
  border: 1px solid var(--color-border);
  padding: 12px 16px;
}

.feed-item {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 8px 0;
  border-bottom: 1px solid #F3F3F5;
}

.feed-item:last-child {
  border-bottom: none;
}

.feed-item__dot {
  width: 8px;
  height: 8px;
  border-radius: var(--radius-full);
  margin-top: 4px;
  flex-shrink: 0;
}

.feed-item__dot.green { background: var(--color-success); }
.feed-item__dot.purple { background: var(--color-accent); }
.feed-item__dot.orange { background: var(--color-warning); }

.feed-item__content {
  flex: 1;
}

.feed-item__header {
  font-size: 12px;
  color: var(--color-text-secondary);
  margin-bottom: 2px;
}

.feed-item__action {
  color: var(--color-text-tertiary);
}

.feed-item__time {
  float: right;
  font-size: 10px;
  color: var(--color-text-muted);
}

.feed-item__detail {
  font-size: 11px;
  color: var(--color-text-tertiary);
  line-height: 1.4;
}

/* Privacy bar */
.privacy-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 12px 16px;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-lg);
  font-size: 11px;
  color: var(--color-text-tertiary);
}
</style>
