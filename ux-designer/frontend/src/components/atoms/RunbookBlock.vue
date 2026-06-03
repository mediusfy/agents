<script setup lang="ts">
import { computed, ref } from 'vue'
import type { RunbookBlock, ExecutionResult } from '../../../types/api'

interface RunbookBlockProps {
  block: RunbookBlock
  executing?: boolean
  result?: ExecutionResult | null
  error?: string | null
}

const props = withDefaults(defineProps<RunbookBlockProps>(), {
  executing: false,
  result: null,
  error: null,
})

const emit = defineEmits<{
  (e: 'execute', blockId: string): void
  (e: 'copy', blockId: string): void
}>()

const copied = ref(false)
const expanded = ref(false)

const isExecutable = computed(() => {
  return ['sh', 'bash', 'zsh', 'kubectl'].includes(props.block.language)
})

async function handleCopy() {
  await navigator.clipboard.writeText(props.block.content)
  copied.value = true
  setTimeout(() => { copied.value = false }, 2000)
}

const statusIcon = computed(() => {
  if (props.executing) return '⏳'
  if (props.result?.validated) return '✅'
  if (props.result && !props.result.validated) return '❌'
  if (props.error) return '⚠️'
  return '▶'
})
</script>

<template>
  <div
    class="runbook-block"
    :class="{
      'runbook-block--executable': isExecutable,
      'runbook-block--running': executing,
      'runbook-block--success': result?.validated,
      'runbook-block--failed': result && !result.validated
    }"
    :data-testid="`runbook-block-${block.id}`"
    role="region"
    :aria-label="`Code block: ${block.language}`"
  >
    <div class="runbook-block__header">
      <span class="runbook-block__lang">{{ block.language }}</span>
      <span v-if="block.description" class="runbook-block__desc">{{ block.description }}</span>
      <div class="runbook-block__actions">
        <button
          class="runbook-block__btn"
          :data-testid="`runbook-copy-${block.id}`"
          :aria-label="`Copy block ${block.id}`"
          @click="handleCopy"
        >
          {{ copied ? '✓ Copied' : '📋 Copy' }}
        </button>
        <button
          v-if="isExecutable"
          class="runbook-block__btn runbook-block__btn--execute"
          :disabled="executing"
          :data-testid="`runbook-execute-${block.id}`"
          :aria-label="`Execute block ${block.id}`"
          @click="emit('execute', block.id)"
        >
          {{ executing ? 'Running...' : '▶ Run' }}
        </button>
      </div>
    </div>

    <pre class="runbook-block__code"><code>{{ block.content }}</code></pre>

    <!-- Execution Result -->
    <div v-if="result || error || executing" class="runbook-block__output">
      <div class="runbook-block__output-header">
        <span>{{ statusIcon }} Output</span>
        <button
          class="runbook-block__btn runbook-block__btn--ghost"
          @click="expanded = !expanded"
        >
          {{ expanded ? 'Collapse' : 'Expand' }}
        </button>
      </div>

      <div v-if="executing" class="runbook-block__executing">
        <div class="spinner"></div>
        <span>Executing...</span>
      </div>

      <div v-else-if="error" class="runbook-block__output-error">
        {{ error }}
      </div>

      <div v-else-if="result" class="runbook-block__result">
        <div v-if="result.stdout" class="runbook-block__stdout" :class="{ truncated: !expanded }">
          <pre>{{ result.stdout }}</pre>
        </div>
        <div v-if="result.stderr" class="runbook-block__stderr">
          <pre>{{ result.stderr }}</pre>
        </div>
        <div class="runbook-block__exit">
          Exit code: <strong :class="{ 'text-green': result.exit_code === 0, 'text-red': result.exit_code !== 0 }">
            {{ result.exit_code }}
          </strong>
          <span v-if="result.explanation" class="runbook-block__explain">· {{ result.explanation }}</span>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.runbook-block {
  border: 1px solid #E8E8EC;
  border-radius: 8px;
  overflow: hidden;
  margin: 8px 0;
}

.runbook-block--executable {
  border-left: 3px solid #6C31FF;
}

.runbook-block--running {
  border-left-color: #6C31FF;
  background: #F8F6FF;
}

.runbook-block--success {
  border-left-color: #00C875;
}

.runbook-block--failed {
  border-left-color: #D93025;
}

.runbook-block__header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 12px;
  background: #F9F9FB;
  border-bottom: 1px solid #E8E8EC;
}

.runbook-block__lang {
  font-size: 11px;
  font-weight: 600;
  color: #6C31FF;
  background: #F0EEFF;
  padding: 1px 6px;
  border-radius: 3px;
}

.runbook-block__desc {
  font-size: 11px;
  color: #7A7A80;
  flex: 1;
}

.runbook-block__actions {
  display: flex;
  gap: 4px;
}

.runbook-block__btn {
  font-size: 10px;
  padding: 3px 8px;
  border: 1px solid #E8E8EC;
  border-radius: 4px;
  background: #fff;
  cursor: pointer;
  color: #555;
}

.runbook-block__btn:hover {
  background: #F0F0F5;
}

.runbook-block__btn:focus-visible {
  outline: 2px solid #6C31FF;
  outline-offset: 2px;
}

.runbook-block__btn--execute {
  background: #6C31FF;
  color: #fff;
  border-color: #6C31FF;
}

.runbook-block__btn--execute:hover:not(:disabled) {
  background: #5B28E0;
}

.runbook-block__btn--execute:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

.runbook-block__btn--ghost {
  border: none;
  background: none;
}

.runbook-block__code {
  background: #F5F5F7;
  padding: 12px;
  margin: 0;
  font-size: 11px;
  line-height: 1.5;
  overflow-x: auto;
}

.runbook-block__output {
  border-top: 1px solid #E8E8EC;
}

.runbook-block__output-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 6px 12px;
  font-size: 11px;
  color: #555;
  background: #FAFAFA;
}

.runbook-block__executing {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 16px;
}

.spinner {
  width: 14px;
  height: 14px;
  border: 2px solid #E8E8EC;
  border-top-color: #6C31FF;
  border-radius: 50%;
  animation: spin 0.6s linear infinite;
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

.runbook-block__stdout {
  background: #1A1A1A;
  color: #00FF88;
  padding: 8px 12px;
}

.runbook-block__stdout pre {
  margin: 0;
  font-size: 11px;
  line-height: 1.5;
}

.runbook-block__stdout.truncated {
  max-height: 120px;
  overflow-y: auto;
}

.runbook-block__stderr {
  background: #1A1A1A;
  color: #FF5555;
  padding: 8px 12px;
}

.runbook-block__stderr pre {
  margin: 0;
  font-size: 11px;
}

.runbook-block__exit {
  padding: 6px 12px;
  font-size: 11px;
  color: #555;
  background: #FAFAFA;
}

.runbook-block__explain {
  color: #7A7A80;
}

.text-green { color: #00C875; }
.text-red { color: #D93025; }
</style>
