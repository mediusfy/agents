// Pinia store for FinOps waste observations
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import type { WasteObservation, CostSavingAction } from '../types/api'
import * as finopsApi from '../api/finops'

export const useFinopsStore = defineStore('finops', () => {
  const observations = ref<WasteObservation[]>([])
  const actions = ref<Map<string, CostSavingAction>>(new Map())
  const loading = ref(false)
  const error = ref<string | null>(null)
  const polling = ref(false)
  let pollTimer: ReturnType<typeof setInterval> | null = null

  const totalMonthlyWasteCents = computed(() =>
    observations.value.reduce((sum, o) => sum + o.monthly_waste_usd_cents, 0)
  )

  const totalMonthlyWasteFormatted = computed(() => {
    const dollars = totalMonthlyWasteCents.value / 100
    if (dollars >= 1000) return `$${(dollars / 1000).toFixed(1)}K`
    return `$${dollars.toFixed(0)}`
  })

  const openObservations = computed(() =>
    observations.value.filter(o => o.status === 'open')
  )

  const topWaste = computed(() =>
    [...observations.value].sort((a, b) =>
      b.monthly_waste_usd_cents - a.monthly_waste_usd_cents
    )
  )

  async function fetchTopWaste(limit = 10) {
    loading.value = true
    error.value = null
    try {
      observations.value = await finopsApi.fetchTopWaste(limit)
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'Failed to fetch waste observations'
    } finally {
      loading.value = false
    }
  }

  async function generateRecommendation(observationId: string): Promise<CostSavingAction | null> {
    try {
      const action = await finopsApi.generateRecommendation(observationId)
      actions.value.set(observationId, action)
      const obs = observations.value.find(o => o.id === observationId)
      if (obs) obs.status = 'actioned'
      return action
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'Failed to generate recommendation'
      return null
    }
  }

  async function dismissObservation(observationId: string, reason?: string) {
    try {
      await finopsApi.dismissObservation(observationId, reason)
      const obs = observations.value.find(o => o.id === observationId)
      if (obs) obs.status = 'dismissed'
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'Failed to dismiss observation'
    }
  }

  function startPolling(intervalMs = 30000) {
    if (pollTimer) return
    polling.value = true
    fetchTopWaste()
    pollTimer = setInterval(() => fetchTopWaste(), intervalMs)
  }

  function stopPolling() {
    if (pollTimer) {
      clearInterval(pollTimer)
      pollTimer = null
    }
    polling.value = false
  }

  return {
    observations,
    actions,
    loading,
    error,
    polling,
    totalMonthlyWasteCents,
    totalMonthlyWasteFormatted,
    openObservations,
    topWaste,
    fetchTopWaste,
    generateRecommendation,
    dismissObservation,
    startPolling,
    stopPolling,
  }
})
