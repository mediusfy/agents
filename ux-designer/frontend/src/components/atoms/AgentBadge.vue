<script setup lang="ts">
import { computed } from 'vue'

interface AgentBadgeProps {
  name: string
  status: 'idle' | 'running' | 'failed' | 'disabled'
  lastActivity?: string
  executionCount?: number
  selected?: boolean
}

const props = withDefaults(defineProps<AgentBadgeProps>(), {
  lastActivity: '',
  executionCount: 0,
  selected: false,
})

const emit = defineEmits<{
  (e: 'select'): void
}>()

const statusDotColor = computed(() => {
  switch (props.status) {
    case 'idle': return '#7A7A80'
    case 'running': return '#6C31FF'
    case 'failed': return '#D93025'
    case 'disabled': return '#E8E8EC'
    default: return '#7A7A80'
  }
})

const statusLabel = computed(() => {
  switch (props.status) {
    case 'idle': return 'Idle'
    case 'running': return 'Analyzing'
    case 'failed': return 'Failed'
    case 'disabled': return 'Disabled'
    default: return props.status
  }
})

const lastActivityFormatted = computed(() => {
  if (!props.lastActivity) return 'No activity'
  const d = new Date(props.lastActivity)
  return d.toLocaleTimeString()
})
</script>

<template>
  <button
    class="agent-badge"
    :class="{ 'agent-badge--selected': selected }"
    :data-testid="`agent-badge-${name}`"
    :aria-pressed="selected"
    :aria-label="`Agent: ${name}, status: ${statusLabel}`"
    @click="emit('select')"
  >
    <div class="agent-badge__dot" :style="{ backgroundColor: statusDotColor }" />
    <div class="agent-badge__info">
      <span class="agent-badge__name">{{ name }}</span>
      <span class="agent-badge__status">{{ statusLabel }}</span>
    </div>
    <div class="agent-badge__meta">
      <span class="agent-badge__time">{{ lastActivityFormatted }}</span>
      <span v-if="executionCount > 0" class="agent-badge__count">
        {{ executionCount }} runs
      </span>
    </div>
  </button>
</template>

<style scoped>
.agent-badge {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  padding: 10px 12px;
  background: #fff;
  border: 1px solid #E8E8EC;
  border-radius: 8px;
  cursor: pointer;
  font-family: 'Inter', sans-serif;
  text-align: left;
  transition: all 0.15s;
}

.agent-badge:hover {
  border-color: #6C31FF;
  box-shadow: 0 0 0 1px #6C31FF33;
}

.agent-badge--selected {
  border-color: #6C31FF;
  background: #F8F6FF;
}

.agent-badge:focus-visible {
  outline: 2px solid #6C31FF;
  outline-offset: 2px;
}

.agent-badge__dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  flex-shrink: 0;
}

.agent-badge__info {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.agent-badge__name {
  font-size: 12px;
  font-weight: 600;
  color: #1A1A1A;
}

.agent-badge__status {
  font-size: 10px;
  color: #7A7A80;
}

.agent-badge__meta {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 2px;
}

.agent-badge__time {
  font-size: 10px;
  color: #999;
}

.agent-badge__count {
  font-size: 10px;
  font-weight: 500;
  color: #6C31FF;
}
</style>
