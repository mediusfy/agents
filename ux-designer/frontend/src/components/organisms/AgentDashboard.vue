<script setup lang="ts">
import { onMounted } from 'vue'
import { useAgentsStore } from '../../../stores/agents'
import AgentBadge from '../../atoms/AgentBadge.vue'
import AgentActivityFeed from '../../molecules/AgentActivityFeed.vue'

interface AgentDashboardProps {
  autoLoad?: boolean
}

const props = withDefaults(defineProps<AgentDashboardProps>(), {
  autoLoad: true,
})

const store = useAgentsStore()

onMounted(() => {
  if (props.autoLoad) {
    store.fetchAgents()
    store.fetchActivityFeed()
  }
})

function handleAgentSelect(agentId: string) {
  store.selectAgent(agentId === store.selectedAgentId ? null : agentId)
}

function handleRetry() {
  store.fetchAgents()
  store.fetchActivityFeed()
}
</script>

<template>
  <div
    class="agent-dashboard"
    :data-testid="$attrs['data-testid'] || 'agent-dashboard'"
    role="region"
    aria-label="Autonomous Agent Dashboard"
  >
    <!-- Header -->
    <div class="agent-dashboard__header">
      <h2 class="agent-dashboard__title">Autonomous Agents</h2>
      <div class="agent-dashboard__metrics">
        <div class="agent-dashboard__metric">
          <span class="agent-dashboard__metric-value">{{ store.agents.length }}</span>
          <span class="agent-dashboard__metric-label">Total</span>
        </div>
        <div class="agent-dashboard__metric agent-dashboard__metric--running">
          <span class="agent-dashboard__metric-value">{{ store.activeAgentCount }}</span>
          <span class="agent-dashboard__metric-label">Running</span>
        </div>
        <div v-if="store.failedAgentCount > 0" class="agent-dashboard__metric agent-dashboard__metric--failed">
          <span class="agent-dashboard__metric-value">{{ store.failedAgentCount }}</span>
          <span class="agent-dashboard__metric-label">Failed</span>
        </div>
        <div class="agent-dashboard__metric">
          <span class="agent-dashboard__metric-value">{{ store.totalExecutions }}</span>
          <span class="agent-dashboard__metric-label">Total Runs</span>
        </div>
      </div>
    </div>

    <!-- Loading State -->
    <div v-if="store.loading" class="agent-dashboard__loading">
      <div class="agent-dashboard__skeleton-grid">
        <div v-for="i in 4" :key="i" class="agent-dashboard__skeleton-card">
          <div class="skeleton-line skeleton-line--name"></div>
          <div class="skeleton-line skeleton-line--status"></div>
        </div>
      </div>
    </div>

    <!-- Error State -->
    <div v-else-if="store.error" class="agent-dashboard__error" role="alert">
      <p>{{ store.error }}</p>
      <button class="agent-dashboard__retry-btn" @click="handleRetry">Retry</button>
    </div>

    <!-- Agent Badge Grid -->
    <div v-else-if="store.agents.length > 0" class="agent-dashboard__grid">
      <AgentBadge
        v-for="agent in store.agents"
        :key="agent.name"
        :name="agent.name"
        :status="agent.status.phase"
        :last-activity="agent.status.last_triggered_at"
        :execution-count="agent.status.execution_count"
        :selected="store.selectedAgentId === agent.name"
        :data-testid="`agent-badge-${agent.name}`"
        @select="handleAgentSelect(agent.name)"
      />
    </div>

    <!-- Empty State -->
    <div v-else class="agent-dashboard__empty">
      <p>No agents configured. Deploy an Agent CRD to get started.</p>
    </div>

    <!-- Activity Feed -->
    <div class="agent-dashboard__feed">
      <AgentActivityFeed
        :events="store.activityFeed.map(e => ({
          id: e.alert_id,
          agentName: e.name,
          action: e.severity === 'critical' ? 'Triaged' : 'Analyzed',
          resource: `${e.namespace}/${e.name}`,
          summary: e.summary,
          severity: e.severity as 'info' | 'warning' | 'critical' | 'success',
          timestamp: e.timestamp,
        }))"
        :loading="store.loading && store.activityFeed.length === 0"
        :error="null"
        :data-testid="'agent-dashboard-feed'"
        @retry="handleRetry"
      />
    </div>
  </div>
</template>

<style scoped>
.agent-dashboard {
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.agent-dashboard__header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
}

.agent-dashboard__title {
  font-size: 16px;
  font-weight: 600;
  color: #1A1A1A;
  margin: 0;
}

.agent-dashboard__metrics {
  display: flex;
  gap: 14px;
}

.agent-dashboard__metric {
  text-align: right;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.agent-dashboard__metric-value {
  font-size: 16px;
  font-weight: 700;
  color: #1A1A1A;
  line-height: 1;
}

.agent-dashboard__metric--running .agent-dashboard__metric-value {
  color: #6C31FF;
}

.agent-dashboard__metric--failed .agent-dashboard__metric-value {
  color: #D93025;
}

.agent-dashboard__metric-label {
  font-size: 10px;
  color: #7A7A80;
}

.agent-dashboard__grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 8px;
}

.agent-dashboard__feed {
  margin-top: 8px;
}

.agent-dashboard__loading,
.agent-dashboard__error,
.agent-dashboard__empty {
  padding: 24px;
  text-align: center;
}

.agent-dashboard__skeleton-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 8px;
}

.agent-dashboard__skeleton-card {
  padding: 16px;
  border: 1px solid #E8E8EC;
  border-radius: 8px;
}

.skeleton-line {
  background: #E8E8EC;
  border-radius: 6px;
  animation: pulse 1.5s infinite;
  margin-bottom: 8px;
}

.skeleton-line--name { height: 14px; width: 60%; }
.skeleton-line--status { height: 10px; width: 40%; }

.agent-dashboard__error {
  background: #FFF0F0;
  border-radius: 8px;
  color: #D93025;
}

.agent-dashboard__retry-btn {
  margin-top: 8px;
  padding: 6px 16px;
  background: #6C31FF;
  color: #fff;
  border: none;
  border-radius: 6px;
  font-size: 12px;
  cursor: pointer;
}

@keyframes pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.5; }
}

@media (max-width: 720px) {
  .agent-dashboard__header {
    flex-direction: column;
    gap: 8px;
  }
  .agent-dashboard__grid {
    grid-template-columns: 1fr;
  }
}
</style>
