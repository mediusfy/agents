<script setup lang="ts">
import { computed, ref, onMounted, onUnmounted } from 'vue'

interface ActivityEvent {
  id: string
  agentName: string
  action: string
  resource: string
  summary: string
  severity: 'info' | 'warning' | 'critical' | 'success'
  timestamp: string
  autoResolved?: boolean
}

interface AgentActivityFeedProps {
  events: ActivityEvent[]
  loading?: boolean
  error?: string | null
  autoScroll?: boolean
}

const props = withDefaults(defineProps<AgentActivityFeedProps>(), {
  loading: false,
  error: null,
  autoScroll: true,
})

const emit = defineEmits<{
  (e: 'retry'): void
}>()

const feedRef = ref<HTMLElement | null>(null)
const paused = ref(false)
let observer: IntersectionObserver | null = null

onMounted(() => {
  if (feedRef.value && props.autoScroll) {
    observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting && !paused.value) {
          feedRef.value!.scrollTop = feedRef.value!.scrollHeight
        }
      },
      { root: feedRef.value }
    )
  }
})

onUnmounted(() => {
  observer?.disconnect()
})

const severityColor = (severity: string) => {
  switch (severity) {
    case 'critical': return '#D93025'
    case 'warning': return '#FFAD42'
    case 'success': return '#00C875'
    default: return '#6C31FF'
  }
}

function togglePause() {
  paused.value = !paused.value
}
</script>

<template>
  <div
    class="activity-feed"
    :data-testid="$attrs['data-testid'] || 'agent-activity-feed'"
    role="region"
    aria-label="Agent Activity Feed"
    aria-live="polite"
  >
    <div class="activity-feed__header">
      <h2 class="activity-feed__title">Autonomous Agent Activity</h2>
      <button
        class="activity-feed__pause-btn"
        :aria-label="paused ? 'Resume auto-scroll' : 'Pause auto-scroll'"
        :data-testid="'activity-feed-pause'"
        @click="togglePause"
      >
        {{ paused ? '▶ Resume' : '⏸ Pause' }}
      </button>
    </div>

    <!-- Loading State -->
    <div v-if="loading" class="activity-feed__loading">
      <div v-for="i in 4" :key="i" class="activity-feed__skeleton">
        <div class="skeleton-dot"></div>
        <div class="skeleton-content">
          <div class="skeleton-line skeleton-line--action"></div>
          <div class="skeleton-line skeleton-line--summary"></div>
        </div>
      </div>
    </div>

    <!-- Error State -->
    <div v-else-if="error" class="activity-feed__error" role="alert">
      <p>{{ error }}</p>
      <button class="activity-feed__retry-btn" @click="emit('retry')">Retry</button>
    </div>

    <!-- Empty State -->
    <div v-else-if="events.length === 0" class="activity-feed__empty">
      <p>No activity yet. Agents are idle.</p>
    </div>

    <!-- Feed -->
    <div
      v-else
      ref="feedRef"
      class="activity-feed__items"
      :style="{ overflowY: 'auto', maxHeight: '400px' }"
    >
      <div
        v-for="event in events"
        :key="event.id"
        class="activity-feed__item"
        :data-testid="`activity-event-${event.id}`"
        :class="{ 'activity-feed__item--auto': event.autoResolved }"
      >
        <div
          class="activity-feed__dot"
          :style="{ backgroundColor: severityColor(event.severity) }"
        />
        <div class="activity-feed__body">
          <div class="activity-feed__action">
            <strong>{{ event.agentName }}</strong>
            <span v-if="event.autoResolved" class="activity-feed__auto-badge">AUTO</span>
            — {{ event.action }}
            <span class="activity-feed__resource">{{ event.resource }}</span>
          </div>
          <div class="activity-feed__summary">{{ event.summary }}</div>
          <div class="activity-feed__time">{{ new Date(event.timestamp).toLocaleString() }}</div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.activity-feed {
  background: #fff;
  border: 1px solid #E8E8EC;
  border-radius: 10px;
  padding: 14px;
}

.activity-feed__header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 12px;
}

.activity-feed__title {
  font-size: 14px;
  font-weight: 600;
  color: #1A1A1A;
  margin: 0;
}

.activity-feed__pause-btn {
  font-size: 11px;
  color: #6C31FF;
  background: none;
  border: 1px solid #E8E8EC;
  border-radius: 6px;
  padding: 4px 10px;
  cursor: pointer;
}

.activity-feed__items {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.activity-feed__item {
  display: flex;
  gap: 10px;
  padding: 10px 8px;
  border-radius: 8px;
  transition: background 0.15s;
}

.activity-feed__item:hover {
  background: #FAFAFA;
}

.activity-feed__item--auto {
  border-left: 2px solid #6C31FF;
}

.activity-feed__dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  margin-top: 5px;
  flex-shrink: 0;
}

.activity-feed__body {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.activity-feed__action {
  font-size: 12px;
  color: #1A1A1A;
}

.activity-feed__auto-badge {
  font-size: 9px;
  font-weight: 600;
  color: #6C31FF;
  background: #F0EEFF;
  padding: 1px 4px;
  border-radius: 3px;
  margin: 0 4px;
}

.activity-feed__resource {
  font-family: 'SF Mono', monospace;
  font-size: 11px;
  color: #6C31FF;
  background: #F8F6FF;
  padding: 1px 6px;
  border-radius: 3px;
}

.activity-feed__summary {
  font-size: 11px;
  color: #7A7A80;
  line-height: 1.4;
}

.activity-feed__time {
  font-size: 10px;
  color: #999;
}

.activity-feed__loading,
.activity-feed__error,
.activity-feed__empty {
  padding: 24px;
  text-align: center;
}

.activity-feed__skeleton {
  display: flex;
  gap: 10px;
  margin-bottom: 12px;
}

.skeleton-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #E8E8EC;
  animation: pulse 1.5s infinite;
}

.skeleton-content {
  flex: 1;
}

.skeleton-line {
  background: #E8E8EC;
  border-radius: 6px;
  animation: pulse 1.5s infinite;
  margin-bottom: 6px;
}

.skeleton-line--action { height: 12px; width: 70%; }
.skeleton-line--summary { height: 10px; width: 90%; }

.activity-feed__error {
  background: #FFF0F0;
  border-radius: 8px;
  color: #D93025;
}

.activity-feed__retry-btn {
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
</style>
