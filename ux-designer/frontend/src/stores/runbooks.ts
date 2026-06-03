// Pinia store for executable runbooks (Theme 4)
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import type { Runbook, RunbookBlock, ExecutionResult } from '../types/api'
import * as runbooksApi from '../api/runbooks'

export const useRunbooksStore = defineStore('runbooks', () => {
  const runbooks = ref<Runbook[]>([])
  const currentRunbook = ref<Runbook | null>(null)
  const executionResults = ref<Map<string, ExecutionResult>>(new Map())
  const executingBlocks = ref<Set<string>>(new Set())
  const loading = ref(false)
  const error = ref<string | null>(null)

  const currentRunbookBlocks = computed(() =>
    currentRunbook.value?.blocks || []
  )

  const executableBlocks = computed(() =>
    currentRunbookBlocks.value.filter(b =>
      ['sh', 'bash', 'zsh', 'kubectl'].includes(b.language)
    )
  )

  async function fetchRunbooks() {
    loading.value = true
    error.value = null
    try {
      runbooks.value = await runbooksApi.fetchRunbooks()
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'Failed to fetch runbooks'
    } finally {
      loading.value = false
    }
  }

  async function selectRunbook(path: string) {
    loading.value = true
    error.value = null
    try {
      currentRunbook.value = await runbooksApi.fetchRunbook(path)
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'Failed to fetch runbook'
    } finally {
      loading.value = false
    }
  }

  async function executeBlock(blockId: string) {
    if (!currentRunbook.value) return

    executingBlocks.value.add(blockId)
    error.value = null

    try {
      const result = await runbooksApi.executeBlock(currentRunbook.value.path, blockId)
      executionResults.value.set(blockId, result)
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'Failed to execute block'
      executionResults.value.set(blockId, {
        stdout: '',
        stderr: error.value || '',
        exit_code: 1,
        validated: false,
      })
    } finally {
      executingBlocks.value.delete(blockId)
    }
  }

  function getResult(blockId: string): ExecutionResult | null {
    return executionResults.value.get(blockId) || null
  }

  function isExecuting(blockId: string): boolean {
    return executingBlocks.value.has(blockId)
  }

  function clearRunbooks() {
    runbooks.value = []
    currentRunbook.value = null
    executionResults.value.clear()
    executingBlocks.value.clear()
  }

  return {
    runbooks,
    currentRunbook,
    executionResults,
    executingBlocks,
    loading,
    error,
    currentRunbookBlocks,
    executableBlocks,
    fetchRunbooks,
    selectRunbook,
    executeBlock,
    getResult,
    isExecuting,
    clearRunbooks,
  }
})
