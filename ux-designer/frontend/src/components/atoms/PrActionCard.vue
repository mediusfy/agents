<script setup lang="ts">
import { computed } from 'vue'

interface PrActionCardProps {
  title: string
  savingsCents: number
  status: 'open' | 'actioned' | 'dismissed' | 'resolved'
  description: string
  loading?: boolean
  disabled?: boolean
  error?: string | null
  'data-testid'?: string
}

const props = withDefaults(defineProps<PrActionCardProps>(), {
  loading: false,
  disabled: false,
  error: null,
})

const emit = defineEmits<{
  (e: 'generate-pr'): void
  (e: 'dismiss'): void
  (e: 'view-pr'): void
}>()

const formattedSavings = computed(() => {
  const dollars = props.savingsCents / 100
  if (dollars >= 1000) {
    return `$${(dollars / 1000).toFixed(1)}K`
  }
  return `$${dollars.toFixed(0)}`
})

const statusColor = computed(() => {
  switch (props.status) {
    case 'open': return '#6C31FF'
    case 'actioned': return '#00C875'
    case 'dismissed': return '#7A7A80'
    case 'resolved': return '#00C875'
    default: return '#7A7A80'
  }
})

const statusLabel = computed(() => {
  switch (props.status) {
    case 'open': return 'Savings Opportunity'
    case 'actioned': return 'PR Created'
    case 'dismissed': return 'Dismissed'
    case 'resolved': return 'Resolved'
    default: return props.status
  }
})
</script>

<template>
  <div
    class="pr-card"
    :class="{ 'pr-card--loading': loading, 'pr-card--disabled': disabled }"
    :data-testid="$attrs['data-testid'] || 'pr-card'"
    role="region"
    :aria-label="`PR Card: ${title}`"
  >
    <!-- Loading State -->
    <div v-if="loading" class="pr-card__skeleton">
      <div class="skeleton-line skeleton-line--title"></div>
      <div class="skeleton-line skeleton-line--desc"></div>
      <div class="skeleton-line skeleton-line--action"></div>
    </div>

    <!-- Error State -->
    <div v-else-if="error" class="pr-card__error" role="alert">
      <span class="pr-card__error-icon">⚠️</span>
      <span>{{ error }}</span>
    </div>

    <!-- Normal State -->
    <template v-else>
      <div class="pr-card__header">
        <div class="pr-card__badge" :style="{ backgroundColor: statusColor + '1A', color: statusColor }">
          ${{ formattedSavings }}/mo
        </div>
        <span class="pr-card__status" :style="{ color: statusColor }">
          {{ statusLabel }}
        </span>
      </div>

      <h3 class="pr-card__title">{{ title }}</h3>
      <p class="pr-card__desc">{{ description }}</p>

      <div class="pr-card__actions">
        <button
          v-if="status === 'open'"
          class="pr-card__btn pr-card__btn--primary"
          :disabled="disabled"
          :data-testid="$attrs['data-testid'] ? `${$attrs['data-testid']}-generate-pr` : 'generate-pr-btn'"
          :aria-label="`Generate PR for ${title}`"
          @click="emit('generate-pr')"
        >
          Generate PR →
        </button>

        <button
          v-if="status === 'actioned'"
          class="pr-card__btn pr-card__btn--secondary"
          :data-testid="$attrs['data-testid'] ? `${$attrs['data-testid']}-view-pr` : 'view-pr-btn'"
          :aria-label="`View PR for ${title}`"
          @click="emit('view-pr')"
        >
          View PR ↗
        </button>

        <button
          v-if="status === 'open'"
          class="pr-card__btn pr-card__btn--ghost"
          :disabled="disabled"
          :data-testid="$attrs['data-testid'] ? `${$attrs['data-testid']}-dismiss` : 'dismiss-btn'"
          :aria-label="`Dismiss ${title}`"
          @click="emit('dismiss')"
        >
          Dismiss
        </button>
      </div>
    </template>
  </div>
</template>

<style scoped>
.pr-card {
  background: #fff;
  border: 1px solid #E8E8EC;
  border-radius: 10px;
  padding: 14px;
  display: flex;
  flex-direction: column;
  gap: 10px;
  transition: box-shadow 0.2s;
}

.pr-card:hover {
  box-shadow: 0 2px 12px rgba(0,0,0,0.04);
}

.pr-card--disabled {
  opacity: 0.6;
  pointer-events: none;
}

.pr-card__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.pr-card__badge {
  font-size: 12px;
  font-weight: 600;
  padding: 2px 8px;
  border-radius: 6px;
}

.pr-card__status {
  font-size: 11px;
  font-weight: 500;
}

.pr-card__title {
  font-size: 13px;
  font-weight: 600;
  color: #1A1A1A;
  margin: 0;
  line-height: 1.4;
}

.pr-card__desc {
  font-size: 11px;
  color: #7A7A80;
  margin: 0;
  line-height: 1.5;
}

.pr-card__actions {
  display: flex;
  gap: 6px;
  margin-top: 4px;
}

.pr-card__btn {
  font-family: 'Inter', sans-serif;
  font-size: 11px;
  font-weight: 500;
  padding: 6px 12px;
  border-radius: 6px;
  border: none;
  cursor: pointer;
  transition: background 0.15s;
}

.pr-card__btn:focus-visible {
  outline: 2px solid #6C31FF;
  outline-offset: 2px;
}

.pr-card__btn--primary {
  background: #6C31FF;
  color: #fff;
}

.pr-card__btn--primary:hover:not(:disabled) {
  background: #5B28E0;
}

.pr-card__btn--secondary {
  background: #F0F0F5;
  color: #1A1A1A;
}

.pr-card__btn--secondary:hover {
  background: #E8E8EC;
}

.pr-card__btn--ghost {
  background: transparent;
  color: #7A7A80;
}

.pr-card__btn--ghost:hover {
  background: #F5F5F7;
}

.pr-card__error {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px;
  background: #FFF0F0;
  border-radius: 8px;
  color: #D93025;
  font-size: 12px;
}

.pr-card__skeleton {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.skeleton-line {
  background: #E8E8EC;
  border-radius: 6px;
  animation: pulse 1.5s ease-in-out infinite;
}

.skeleton-line--title {
  height: 16px;
  width: 60%;
}

.skeleton-line--desc {
  height: 12px;
  width: 90%;
}

.skeleton-line--action {
  height: 30px;
  width: 40%;
}

@keyframes pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.5; }
}
</style>
