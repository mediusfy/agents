<script setup lang="ts">
import { onMounted, onUnmounted, computed } from 'vue'
import { useFinopsStore } from '../../stores/finops'
import PrActionList from '../molecules/PrActionList.vue'
import PrActionCard from '../atoms/PrActionCard.vue'

interface FinOpsWastePanelProps {
  limit?: number
  autoPoll?: boolean
  pollIntervalMs?: number
  title?: string
}

const props = withDefaults(defineProps<FinOpsWastePanelProps>(), {
  limit: 10,
  autoPoll: true,
  pollIntervalMs: 30000,
  title: 'FinOps Waste Analysis',
})

const store = useFinopsStore()

onMounted(() => {
  store.fetchTopWaste(props.limit)
  if (props.autoPoll) {
    store.startPolling(props.pollIntervalMs)
  }
})

onUnmounted(() => {
  if (props.autoPoll) {
    store.stopPolling()
  }
})

const topThree = computed(() => store.topWaste.slice(0, 3))

async function handleGeneratePR(observationId: string) {
  await store.generateRecommendation(observationId)
}

async function handleDismiss(observationId: string) {
  await store.dismissObservation(observationId)
}

function handleRetry() {
  store.fetchTopWaste(props.limit)
}
</script>

<template>
  <div
    class="finops-panel"
    :data-testid="$attrs['data-testid'] || 'finops-waste-panel'"
    role="region"
    aria-label="FinOps Waste Analysis Panel"
  >
    <!-- Header -->
    <div class="finops-panel__header">
      <h2 class="finops-panel__title">{{ title }}</h2>
      <div class="finops-panel__metrics">
        <div class="finops-panel__metric">
          <span class="finops-panel__metric-value">{{ store.openObservations.length }}</span>
          <span class="finops-panel__metric-label">Opportunities</span>
        </div>
        <div class="finops-panel__metric finops-panel__metric--accent">
          <span class="finops-panel__metric-value">{{ store.totalMonthlyWasteFormatted }}</span>
          <span class="finops-panel__metric-label">Potential Savings/mo</span>
        </div>
      </div>
    </div>

    <!-- Top 3 Highlight Cards -->
    <div v-if="!store.loading && !store.error && topThree.length" class="finops-panel__highlights">
      <PrActionCard
        v-for="obs in topThree"
        :key="obs.id"
        :title="`${obs.namespace}/${obs.workload_name}`"
        :savings-cents="obs.monthly_waste_usd_cents"
        :status="obs.status"
        :description="`${obs.cluster} · ${obs.current_requests_cpu} CPU / ${obs.current_requests_memory} mem → ${obs.recommended_requests_cpu} CPU / ${obs.recommended_requests_memory} mem`"
        :data-testid="`finops-highlight-${obs.id}`"
        @generate-pr="handleGeneratePR(obs.id)"
        @dismiss="handleDismiss(obs.id)"
      />
    </div>

    <!-- Full List -->
    <PrActionList
      :observations="store.observations"
      :loading="store.loading"
      :error="store.error"
      empty-message="All workloads are optimally sized — no waste detected"
      :data-testid="'finops-panel-list'"
      @generate-pr="handleGeneratePR"
      @dismiss="handleDismiss"
      @retry="handleRetry"
    />

    <!-- Status Indicator -->
    <div v-if="store.polling" class="finops-panel__status">
      <span class="finops-panel__live-dot"></span>
      <span class="finops-panel__live-text">Live — polling every {{ props.pollIntervalMs / 1000 }}s</span>
    </div>
  </div>
</template>

<style scoped>
.finops-panel {
  background: #fff;
  border: 1px solid #E8E8EC;
  border-radius: 12px;
  overflow: hidden;
}

.finops-panel__header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  padding: 16px 16px 0;
}

.finops-panel__title {
  font-size: 16px;
  font-weight: 600;
  color: #1A1A1A;
  margin: 0;
}

.finops-panel__metrics {
  display: flex;
  gap: 16px;
}

.finops-panel__metric {
  text-align: right;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.finops-panel__metric-value {
  font-size: 18px;
  font-weight: 700;
  color: #1A1A1A;
  line-height: 1;
}

.finops-panel__metric--accent .finops-panel__metric-value {
  color: #6C31FF;
}

.finops-panel__metric-label {
  font-size: 10px;
  color: #7A7A80;
}

.finops-panel__highlights {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 10px;
  padding: 12px 16px;
}

.finops-panel__status {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 16px;
  border-top: 1px solid #E8E8EC;
  background: #FAFAFA;
}

.finops-panel__live-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: #00C875;
  animation: pulse-dot 2s ease-in-out infinite;
}

.finops-panel__live-text {
  font-size: 10px;
  color: #7A7A80;
}

@keyframes pulse-dot {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.4; }
}

@media (max-width: 960px) {
  .finops-panel__highlights {
    grid-template-columns: 1fr;
  }
  .finops-panel__header {
    flex-direction: column;
    gap: 8px;
  }
}
</style>
