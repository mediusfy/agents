<script setup lang="ts">
import { computed, ref } from 'vue'
import PrActionCard from '../atoms/PrActionCard.vue'
import type { WasteObservation } from '../../../types/api'

interface PrActionListProps {
  observations: WasteObservation[]
  loading?: boolean
  emptyMessage?: string
  error?: string | null
}

const props = withDefaults(defineProps<PrActionListProps>(), {
  loading: false,
  emptyMessage: 'No waste observations found',
  error: null,
})

const emit = defineEmits<{
  (e: 'generate-pr', observationId: string): void
  (e: 'dismiss', observationId: string): void
  (e: 'view-pr', prUrl: string): void
  (e: 'retry'): void
}>()

const expandedId = ref<string | null>(null)

const sortedObservations = computed(() => {
  return [...props.observations].sort((a, b) =>
    b.monthly_waste_usd_cents - a.monthly_waste_usd_cents
  )
})

function toggleExpand(id: string) {
  expandedId.value = expandedId.value === id ? null : id
}
</script>

<template>
  <div
    class="pr-list"
    :data-testid="$attrs['data-testid'] || 'pr-action-list'"
    role="region"
    aria-label="PR Action List"
  >
    <div class="pr-list__header">
      <h2 class="pr-list__title">GitOps Remediation Opportunities</h2>
      <span class="pr-list__badge" v-if="observations.length">
        {{ observations.length }} open
      </span>
    </div>

    <!-- Loading State -->
    <div v-if="loading" class="pr-list__loading">
      <PrActionCard
        v-for="i in 3"
        :key="i"
        title=""
        :savings-cents="0"
        status="open"
        description=""
        :loading="true"
        :data-testid="`pr-card-skeleton-${i}`"
      />
    </div>

    <!-- Error State -->
    <div v-else-if="error" class="pr-list__error" role="alert">
      <p>{{ error }}</p>
      <button class="pr-list__retry-btn" @click="emit('retry')">
        Retry
      </button>
    </div>

    <!-- Empty State -->
    <div v-else-if="observations.length === 0" class="pr-list__empty">
      <h3 class="pr-list__empty-title">No items yet</h3>
      <p class="pr-list__empty-desc">No waste observations found. All workloads are optimally sized.</p>
    </div>

    <!-- List -->
    <div v-else class="pr-list__items">
      <template v-for="obs in sortedObservations" :key="obs.id">
        <div
          class="pr-list__group"
          :class="{ 'pr-list__group--expanded': expandedId === obs.id }"
        >
          <button
            class="pr-list__group-header"
            @click="toggleExpand(obs.id)"
            :aria-expanded="expandedId === obs.id"
            :data-testid="`pr-card-group-${obs.id}`"
          >
            <span class="pr-list__ns">{{ obs.namespace }}/{{ obs.workload_name }}</span>
            <span class="pr-list__waste">${{ (obs.monthly_waste_usd_cents / 100).toFixed(0) }}/mo</span>
          </button>

          <div v-if="expandedId === obs.id" class="pr-list__card-wrapper">
            <PrActionCard
              :title="`${obs.resource_type}/${obs.workload_name}`"
              :savings-cents="obs.monthly_waste_usd_cents"
              :status="obs.status"
              :description="`${obs.cluster} · Current: ${obs.current_requests_cpu} CPU, ${obs.current_requests_memory} mem · Recommended: ${obs.recommended_requests_cpu} CPU, ${obs.recommended_requests_memory} mem`"
              :data-testid="`pr-card-${obs.id}`"
              @generate-pr="emit('generate-pr', obs.id)"
              @dismiss="emit('dismiss', obs.id)"
            />
          </div>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
.pr-list {
  background: #fff;
  border-radius: 10px;
  border: 1px solid #E8E8EC;
  padding: 16px;
}

.pr-list__header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 14px;
}

.pr-list__title {
  font-size: 14px;
  font-weight: 600;
  color: #1A1A1A;
  margin: 0;
}

.pr-list__badge {
  font-size: 10px;
  font-weight: 500;
  color: #6C31FF;
  background: #F0EEFF;
  padding: 2px 6px;
  border-radius: 999px;
}

.pr-list__items {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.pr-list__group {
  border: 1px solid #E8E8EC;
  border-radius: 8px;
  overflow: hidden;
}

.pr-list__group-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  width: 100%;
  padding: 10px 12px;
  background: #FAFAFA;
  border: none;
  font-family: 'Inter', sans-serif;
  font-size: 12px;
  cursor: pointer;
  transition: background 0.15s;
}

.pr-list__group-header:hover {
  background: #F0F0F5;
}

.pr-list__group-header:focus-visible {
  outline: 2px solid #6C31FF;
  outline-offset: -2px;
}

.pr-list__ns {
  font-weight: 500;
  color: #1A1A1A;
}

.pr-list__waste {
  font-weight: 600;
  color: #6C31FF;
}

.pr-list__card-wrapper {
  padding: 8px 10px 10px;
}

.pr-list__loading,
.pr-list__error,
.pr-list__empty {
  padding: 24px;
  text-align: center;
}

.pr-list__error {
  background: #FFF0F0;
  border-radius: 8px;
  color: #D93025;
}

.pr-list__retry-btn {
  margin-top: 8px;
  padding: 6px 16px;
  background: #6C31FF;
  color: #fff;
  border: none;
  border-radius: 6px;
  font-size: 12px;
  cursor: pointer;
}

.pr-list__empty-title {
  font-size: 14px;
  font-weight: 500;
  color: #1A1A1A;
  margin: 0 0 4px;
}

.pr-list__empty-desc {
  font-size: 12px;
  color: #7A7A80;
  margin: 0;
}
</style>
