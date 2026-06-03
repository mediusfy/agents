<template>
  <div class="page">
    <TopBar title="Home" />

    <div class="content">
      <!-- Welcome Card -->
      <div class="welcome-card" data-testid="welcome-card">
        <div class="welcome-card__icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>
          </svg>
        </div>
        <div class="welcome-card__text">
          <h2 class="welcome-card__title">OpenClaw Agent Platform</h2>
          <p class="welcome-card__subtitle">minikube · 5 agents deployed · 4 healthy · 1 running</p>
        </div>
        <div class="welcome-card__actions">
          <span class="pill pill--green">4 Healthy</span>
          <span class="pill pill--orange">1 Running</span>
          <button class="btn btn--primary" aria-label="Create new agent" data-testid="create-agent-btn">
            + Create Agent
          </button>
        </div>
      </div>

      <!-- Metrics Bar -->
      <div class="metrics-bar" data-testid="metrics-bar">
        <div class="metric" data-testid="metric-active-agents">
          <span class="metric__value">5</span>
          <span class="metric__label">Active Agents</span>
        </div>
        <div class="metric" data-testid="metric-avg-cpu">
          <span class="metric__value">180m</span>
          <span class="metric__label">Avg CPU</span>
        </div>
        <div class="metric" data-testid="metric-avg-memory">
          <span class="metric__value">652Mi</span>
          <span class="metric__label">Avg Memory</span>
        </div>
        <div class="metric" data-testid="metric-artifacts-today">
          <span class="metric__value">15</span>
          <span class="metric__label">Artifacts Today</span>
        </div>
      </div>

      <!-- Activity + Quick Actions Grid -->
      <div class="grid-2col">
        <!-- Recent Activity -->
        <div class="card" data-testid="recent-activity">
          <h3 class="card__title">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>
            </svg>
            Recent Activity
          </h3>
          <div class="activity-list">
            <div
              v-for="item in recentActivity"
              :key="item.label"
              class="activity-item"
              :data-testid="`activity-${item.id}`"
            >
              <div class="activity-item__dot" :style="{ background: item.color }"></div>
              <span class="activity-item__text">{{ item.label }}</span>
              <span class="activity-item__time">{{ item.time }}</span>
            </div>
          </div>
        </div>

        <!-- Quick Actions -->
        <div class="card" data-testid="quick-actions">
          <h3 class="card__title">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/>
            </svg>
            Quick Actions
            <span class="badge-count">⌘K</span>
          </h3>
          <div class="quick-action-list">
            <button
              v-for="action in quickActions"
              :key="action.label"
              class="quick-action"
              :data-testid="`quick-action-${action.id}`"
              :aria-label="action.label"
            >
              <div class="quick-action__icon" :style="{ background: action.bg, color: action.fg }">
                {{ action.shortcut }}
              </div>
              <span>{{ action.label }}</span>
              <span class="quick-action__key">{{ action.kb }}</span>
            </button>
          </div>
        </div>
      </div>

      <!-- Agents + Artifacts Grid -->
      <div class="grid-2col">
        <!-- Active Agents -->
        <div class="card" data-testid="active-agents-card">
          <h3 class="card__title">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="3" y="3" width="18" height="18" rx="2"/><line x1="3" y1="9" x2="21" y2="9"/>
            </svg>
            Active Agents
          </h3>
          <div class="agent-row" v-for="a in activeAgents" :key="a.name" :data-testid="`agent-row-${a.name.toLowerCase()}`">
            <span class="sdot" :class="a.statusDot"></span>
            <strong class="agent-row__name">{{ a.name }}</strong>
            <span class="agent-row__caps">{{ a.capabilities }}</span>
            <span class="agent-row__time">{{ a.lastActive }}</span>
          </div>
        </div>

        <!-- Today's Artifacts -->
        <div class="card" data-testid="artifacts-card">
          <h3 class="card__title">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polyline points="18 8 22 12 18 16"/><polyline points="6 8 2 12 6 16"/><line x1="2" y1="12" x2="22" y2="12"/>
            </svg>
            Today's Artifacts
          </h3>
          <div class="artifact-list">
            <div v-for="a in artifacts" :key="a.name" class="artifact-item" :data-testid="`artifact-${a.id}`">
              <span class="artifact-item__dot" :style="{ background: a.color }"></span>
              <span class="artifact-item__text">{{ a.name }}</span>
              <span class="artifact-item__tag">{{ a.tag }}</span>
            </div>
          </div>
        </div>
      </div>

      <!-- STRATEGY THEME 2: FinOps ROI Card -->
      <div v-if="featureFlags.finopsROI.value" class="strategy-card strategy-card--finops" data-testid="finops-savings-card">
        <div class="strategy-card__content">
          <div class="strategy-card__emoji">💰</div>
          <div class="strategy-card__body">
            <div class="strategy-card__header">
              <h3 class="strategy-card__title">Potential Savings</h3>
              <span class="pill-small pill-small--finops">FinOps</span>
            </div>
            <div class="strategy-card__metric">
              $1,240<span class="strategy-card__metric-period"> /mo</span>
            </div>
            <p class="strategy-card__desc">2 deployments over-provisioned · 1 PVC underutilized (67% free)</p>
            <div class="strategy-card__items">
              <div class="strategy-card__item" data-testid="finops-item-api-gateway">
                <div class="strategy-card__item-header">
                  <span>api-gateway</span>
                  <span class="strategy-card__saving">-$240/mo</span>
                </div>
                <div class="strategy-card__item-detail">CPU request: 2 → 1 core</div>
              </div>
              <div class="strategy-card__item" data-testid="finops-item-redis-cache">
                <div class="strategy-card__item-header">
                  <span>redis-cache</span>
                  <span class="strategy-card__saving">-$400/mo</span>
                </div>
                <div class="strategy-card__item-detail">Memory limit: 4Gi → 2Gi</div>
              </div>
              <div class="strategy-card__item" data-testid="finops-item-pvc-logs">
                <div class="strategy-card__item-header">
                  <span>pvc-logs</span>
                  <span class="strategy-card__saving strategy-card__saving--warn">-$600/mo</span>
                </div>
                <div class="strategy-card__item-detail">Reduce from 50Gi to 20Gi</div>
              </div>
            </div>
            <div class="strategy-card__actions">
              <button class="btn btn--primary btn--small" data-testid="generate-prs-btn">Generate Remediation PRs</button>
              <button class="btn btn--small" data-testid="view-details-btn">View Details →</button>
            </div>
          </div>
          <span class="pill-small pill-small--coming-soon">Coming Soon</span>
        </div>
      </div>

      <!-- STRATEGY THEME 3: Agent Activity -->
      <div v-if="featureFlags.agentAutonomy.value" class="strategy-card strategy-card--agent" data-testid="agent-activity-card">
        <div class="strategy-card__content">
          <div class="strategy-card__emoji">🤖</div>
          <div class="strategy-card__body">
            <div class="strategy-card__header">
              <h3 class="strategy-card__title">Agent Activity</h3>
              <span class="pill-small pill-small--finops">Autonomous</span>
            </div>
            <div class="agent-activity-feed">
              <div class="agent-activity-item" data-testid="agent-activity-1">
                <div class="agent-activity-item__dot sdot purple"></div>
                <div class="agent-activity-item__text">
                  <strong>SRE Agent</strong> auto-triaged alert:
                  <span class="agent-activity-item__detail">"Memory pressure kube-system"</span>
                  <span class="agent-activity-item__sub">→ pulled logs, checked recent sync → placed root-cause summary → generated remediation PR (#247)</span>
                </div>
                <span class="agent-activity-item__time">2m ago</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import TopBar from '../components/atoms/TopBar.vue';
import { useFeatureFlags } from '../composables/useFeatureFlags';

const featureFlags = useFeatureFlags();

const recentActivity = [
  { id: '1', label: 'Applied Terraform diff for staging cluster', time: '2m', color: '#1B8A2F' },
  { id: '2', label: 'Generated orders-svc scaffolding (6 files)', time: '4m', color: '#E57800' },
  { id: '3', label: 'Scanned 14 services, 0 critical CVE findings', time: '2h', color: '#6C31FF' },
  { id: '4', label: 'Published pipeline for api-gateway', time: '12m', color: '#1B8A2F' },
];

const quickActions = [
  { id: 'sre', label: 'Create new SRE agent', shortcut: 'S', kb: '⌘⇧S', bg: '#E3F5E5', fg: '#1B8A2F' },
  { id: 'backend', label: 'Deploy Backend service', shortcut: 'B', kb: '⌘⇧B', bg: '#FFF1E0', fg: '#E57800' },
  { id: 'frontend', label: 'Generate Frontend component', shortcut: 'F', kb: '⌘⇧F', bg: '#E8E6FF', fg: '#6C31FF' },
  { id: 'security', label: 'Run Security Audit', shortcut: 'A', kb: '⌘⇧A', bg: '#FFE8E8', fg: '#C5221F' },
];

const activeAgents = [
  { name: 'SRE', statusDot: 'green', capabilities: 'GitOps · Terraform · Helm', lastActive: '3m ago' },
  { name: 'Backend', statusDot: 'green', capabilities: 'Go hexagonal · gRPC · NATS', lastActive: '4m ago' },
  { name: 'Frontend', statusDot: 'orange', capabilities: 'Vue 3 · Composition API', lastActive: 'Deploying' },
  { name: 'DevOps', statusDot: 'green', capabilities: 'CI/CD · Docker · Makefiles', lastActive: '12m ago' },
  { name: 'Security', statusDot: 'purple', capabilities: 'OWASP · CVE · Secrets', lastActive: 'Idle' },
];

const artifacts = [
  { id: '1', name: 'orders-svc — Go hexagonal service scaffold', color: '#6C31FF', tag: 'Backend' },
  { id: '2', name: 'staging-terraform — EKS cluster config diff', color: '#00C875', tag: 'SRE' },
  { id: '3', name: 'api-pipeline — GitHub Actions workflow', color: '#FFAD42', tag: 'DevOps' },
  { id: '4', name: 'security-report — 14 services scanned', color: '#D93025', tag: 'Security' },
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

/* Welcome card */
.welcome-card {
  background: var(--color-surface);
  border-radius: var(--radius-xl);
  border: 1px solid var(--color-border);
  padding: 20px 24px;
  display: flex;
  align-items: center;
  gap: 16px;
  margin-bottom: 20px;
}

.welcome-card__icon {
  width: 40px;
  height: 40px;
  border-radius: 10px;
  background: linear-gradient(135deg, var(--color-accent), #8A5CFF);
  display: flex;
  align-items: center;
  justify-content: center;
  color: #fff;
  flex-shrink: 0;
}

.welcome-card__icon svg {
  width: 22px;
  height: 22px;
}

.welcome-card__title {
  font-size: 16px;
  font-weight: 600;
  color: var(--color-text-primary);
}

.welcome-card__subtitle {
  font-size: 12px;
  color: #888;
  margin-top: 2px;
}

.welcome-card__actions {
  margin-left: auto;
  display: flex;
  gap: 8px;
  align-items: center;
}

/* Metrics bar */
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
  min-width: 0;
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

/* Grid */
.grid-2col {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 16px;
  margin-bottom: 20px;
}

/* Activity */
.activity-list {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.activity-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 0;
  border-bottom: 1px solid #F3F3F5;
  font-size: 12px;
  color: var(--color-text-secondary);
}

.activity-item:last-child {
  border-bottom: none;
}

.activity-item__dot {
  width: 6px;
  height: 6px;
  border-radius: var(--radius-full);
  flex-shrink: 0;
}

.activity-item__time {
  font-size: 10px;
  color: #BBB;
  margin-left: auto;
  flex-shrink: 0;
}

/* Quick actions */
.quick-action-list {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.quick-action {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 8px;
  border-radius: var(--radius-sm);
  cursor: pointer;
  font-size: 12px;
  color: var(--color-text-secondary);
  background: none;
  border: none;
  font-family: inherit;
  width: 100%;
  text-align: left;
  transition: background var(--transition-fast);
}

.quick-action:hover {
  background: var(--color-surface-subtle);
}

.quick-action:focus-visible {
  outline: 2px solid var(--color-accent);
  outline-offset: -2px;
}

.quick-action__icon {
  width: 14px;
  height: 14px;
  border-radius: 4px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 9px;
  font-weight: 600;
  flex-shrink: 0;
}

.quick-action__key {
  font-size: 9px;
  color: #BBB;
  font-weight: 500;
  margin-left: auto;
}

/* Agent rows */
.agent-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 0;
  font-size: 12px;
  border-bottom: 1px solid #F3F3F5;
}

.agent-row:last-child {
  border-bottom: none;
}

.agent-row__name {
  color: var(--color-text-primary);
  min-width: 70px;
  font-weight: 600;
}

.agent-row__caps {
  color: #888;
  flex: 1;
}

.agent-row__time {
  font-size: 10px;
  color: var(--color-text-muted);
  flex-shrink: 0;
}

/* Artifacts */
.artifact-list {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.artifact-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 8px;
  border-radius: var(--radius-sm);
  font-size: 12px;
  color: var(--color-text-secondary);
  transition: background var(--transition-fast);
}

.artifact-item:hover {
  background: var(--color-surface-subtle);
}

.artifact-item__dot {
  width: 6px;
  height: 6px;
  border-radius: var(--radius-full);
  flex-shrink: 0;
}

.artifact-item__tag {
  font-size: 10px;
  color: var(--color-text-muted);
  margin-left: auto;
  font-weight: 500;
}

/* Strategy cards */
.strategy-card {
  border-radius: var(--radius-lg);
  border: 1px solid var(--color-border);
  position: relative;
  overflow: hidden;
  margin-bottom: 20px;
}

.strategy-card--finops {
  border-left: 3px solid var(--color-accent);
}

.strategy-card--agent {
  border-left: 3px solid var(--color-accent);
}

.strategy-card__content {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  padding: 20px;
  background: var(--color-surface);
}

.strategy-card__emoji {
  font-size: 20px;
  flex-shrink: 0;
}

.strategy-card__body {
  flex: 1;
}

.strategy-card__header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 4px;
}

.strategy-card__title {
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary);
  margin: 0;
}

.strategy-card__metric {
  font-size: 28px;
  font-weight: 700;
  color: var(--color-text-primary);
  margin-bottom: 2px;
}

.strategy-card__metric-period {
  font-size: 14px;
  font-weight: 400;
  color: var(--color-text-muted);
}

.strategy-card__desc {
  font-size: 11px;
  color: #888;
  margin-bottom: 12px;
}

.strategy-card__items {
  display: flex;
  gap: 6px;
  margin-bottom: 10px;
}

.strategy-card__item {
  flex: 1;
  background: #F9F9FB;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 8px 10px;
  font-size: 11px;
}

.strategy-card__item-header {
  display: flex;
  justify-content: space-between;
  color: var(--color-text-primary);
  font-weight: 500;
  margin-bottom: 2px;
}

.strategy-card__saving {
  color: #34C759;
}

.strategy-card__saving--warn {
  color: #FF9500;
}

.strategy-card__item-detail {
  color: #888;
}

.strategy-card__actions {
  margin-top: 10px;
  display: flex;
  gap: 6px;
}

/* Agent activity feed in strategy card */
.agent-activity-feed {
  margin-top: 8px;
}

.agent-activity-item {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  padding: 8px 0;
  font-size: 12px;
  color: var(--color-text-secondary);
}

.agent-activity-item__dot {
  margin-top: 4px;
}

.agent-activity-item__text {
  flex: 1;
  line-height: 1.5;
}

.agent-activity-item__detail {
  display: block;
  color: var(--color-text-primary);
  font-weight: 500;
  margin-top: 2px;
}

.agent-activity-item__sub {
  display: block;
  font-size: 11px;
  color: var(--color-text-tertiary);
  margin-top: 2px;
}

.agent-activity-item__time {
  font-size: 10px;
  color: var(--color-text-muted);
  flex-shrink: 0;
  margin-left: auto;
}

/* Pill inline */
.pill {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 3px 10px;
  border-radius: var(--radius-full);
  font-size: 11px;
  font-weight: 500;
}

.pill--green {
  background: var(--color-success-bg);
  color: var(--color-success-text);
}

.pill--orange {
  background: var(--color-warning-bg);
  color: var(--color-warning-text);
}
</style>
