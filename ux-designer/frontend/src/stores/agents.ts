// Pinia store for autonomous agents (Theme 3)
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import type { Agent, AnomstackEvent } from '../types/api'

export const useAgentsStore = defineStore('agents', () => {
  const agents = ref<Agent[]>([])
  const activityFeed = ref<AnomstackEvent[]>([])
  const selectedAgentId = ref<string | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)

  const selectedAgent = computed(() =>
    selectedAgentId.value
      ? agents.value.find(a => a.name === selectedAgentId.value) || null
      : null
  )

  const activeAgentCount = computed(() =>
    agents.value.filter(a => a.status.phase === 'running').length
  )

  const failedAgentCount = computed(() =>
    agents.value.filter(a => a.status.phase === 'failed').length
  )

  const totalExecutions = computed(() =>
    agents.value.reduce((sum, a) => sum + a.status.execution_count, 0)
  )

  function addAgent(agent: Agent) {
    const idx = agents.value.findIndex(a => a.name === agent.name)
    if (idx >= 0) {
      agents.value[idx] = agent
    } else {
      agents.value.push(agent)
    }
  }

  function addActivityEvent(event: AnomstackEvent) {
    activityFeed.value.unshift(event)
    // Keep last 100 events
    if (activityFeed.value.length > 100) {
      activityFeed.value = activityFeed.value.slice(0, 100)
    }
  }

  function selectAgent(agentId: string | null) {
    selectedAgentId.value = agentId
  }

  async function fetchAgents() {
    loading.value = true
    error.value = null
    try {
      const res = await fetch('/api/v1/agents')
      if (!res.ok) throw new Error(`Failed to fetch agents: ${res.statusText}`)
      const data: Agent[] = await res.json()
      agents.value = data
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'Failed to fetch agents'
    } finally {
      loading.value = false
    }
  }

  async function fetchActivityFeed(limit = 50) {
    try {
      const res = await fetch(`/api/v1/agents/activity?limit=${limit}`)
      if (!res.ok) throw new Error(`Failed to fetch activity: ${res.statusText}`)
      const data: AnomstackEvent[] = await res.json()
      activityFeed.value = data
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'Failed to fetch activity feed'
    }
  }

  return {
    agents,
    activityFeed,
    selectedAgentId,
    selectedAgent,
    loading,
    error,
    activeAgentCount,
    failedAgentCount,
    totalExecutions,
    addAgent,
    addActivityEvent,
    selectAgent,
    fetchAgents,
    fetchActivityFeed,
  }
})
