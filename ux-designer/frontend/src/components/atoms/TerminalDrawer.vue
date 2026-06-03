<script setup lang="ts">
import { ref, onMounted, nextTick, watch } from 'vue'
import type { ExecutionResult } from '../../../types/api'

interface TerminalDrawerProps {
  open?: boolean
  title?: string
  blockContent?: string
  executing?: boolean
  result?: ExecutionResult | null
  error?: string | null
}

const props = withDefaults(defineProps<TerminalDrawerProps>(), {
  open: false,
  title: 'Terminal',
  blockContent: '',
  executing: false,
  result: null,
  error: null,
})

const emit = defineEmits<{
  (e: 'close'): void
  (e: 'rerun'): void
  (e: 'copy'): void
  (e: 'toggle'): void
}>()

const terminalRef = ref<HTMLElement | null>(null)
const elapsed = ref(0)
let timer: ReturnType<typeof setInterval> | null = null

watch(() => props.executing, (val) => {
  if (val) {
    elapsed.value = 0
    timer = setInterval(() => { elapsed.value++ }, 1000)
  } else {
    if (timer) {
      clearInterval(timer)
      timer = null
    }
  }
})

onMounted(() => {
  window.addEventListener('keydown', handleKeydown)
})

// Key handler for Ctrl+`
function handleKeydown(e: KeyboardEvent) {
  if (e.ctrlKey && e.code === 'Backquote') {
    e.preventDefault()
    emit('toggle')
  }
}

function formatTime(seconds: number): string {
  const m = Math.floor(seconds / 60)
  const s = seconds % 60
  return `${m}:${s.toString().padStart(2, '0')}`
}
</script>

<template>
  <Teleport to="body">
    <div
      v-if="open"
      class="terminal-drawer"
      :data-testid="$attrs['data-testid'] || 'terminal-drawer'"
      role="region"
      aria-label="Terminal execution drawer"
    >
      <!-- Overlay -->
      <div class="terminal-drawer__overlay" @click="emit('close')" />

      <!-- Drawer -->
      <div class="terminal-drawer__panel" role="dialog" aria-modal="true">
        <!-- Header -->
        <div class="terminal-drawer__header">
          <div class="terminal-drawer__tabs">
            <div class="terminal-drawer__tab terminal-drawer__tab--active">
              <span class="terminal-drawer__tab-icon">⏻</span>
              <span>{{ title }}</span>
              <span v-if="executing" class="terminal-drawer__timer">{{ formatTime(elapsed) }}</span>
            </div>
          </div>
          <div class="terminal-drawer__actions">
            <button
              class="terminal-drawer__action-btn"
              :data-testid="'terminal-rerun-btn'"
              :aria-label="'Re-run command'"
              @click="emit('rerun')"
            >
              ↻ Rerun
            </button>
            <button
              class="terminal-drawer__action-btn"
              :data-testid="'terminal-copy-btn'"
              :aria-label="'Copy output'"
              @click="emit('copy')"
            >
              📋 Copy
            </button>
            <button
              class="terminal-drawer__action-btn terminal-drawer__action-btn--close"
              :data-testid="'terminal-close-btn'"
              :aria-label="'Close terminal'"
              @click="emit('close')"
            >
              ✕
            </button>
          </div>
        </div>

        <!-- Body -->
        <div ref="terminalRef" class="terminal-drawer__body">
          <!-- Command header -->
          <div class="terminal-drawer__cmd-line">
            <span class="terminal-drawer__prompt">$</span>
            <span class="terminal-drawer__cmd">{{ blockContent }}</span>
          </div>

          <!-- Executing state -->
          <div v-if="executing" class="terminal-drawer__executing">
            <div class="terminal-drawer__spinner"></div>
            <span>Executing...</span>
          </div>

          <!-- Error state -->
          <div v-else-if="error" class="terminal-drawer__error-line">
            {{ error }}
          </div>

          <!-- Result output -->
          <div v-else-if="result" class="terminal-drawer__output">
            <div v-if="result.stdout" class="terminal-drawer__stdout">
              <pre>{{ result.stdout }}</pre>
            </div>
            <div v-if="result.stderr" class="terminal-drawer__stderr">
              <pre>{{ result.stderr }}</pre>
            </div>
            <div class="terminal-drawer__exit-line">
              <span>
                Exit code:
                <strong :class="{ 'text-green': result.exit_code === 0, 'text-red': result.exit_code !== 0 }">
                  {{ result.exit_code }}
                </strong>
              </span>
              <span v-if="result.validated" class="terminal-drawer__validated">
                ✅ Validated
              </span>
              <span v-if="result.explanation" class="terminal-drawer__explain">
                {{ result.explanation }}
              </span>
            </div>
          </div>

          <!-- Idle state -->
          <div v-else class="terminal-drawer__idle">
            <div class="terminal-drawer__idle-blocks">
              <div class="terminal-drawer__cursor-line">
                <span class="terminal-drawer__prompt">$</span>
                <span class="terminal-drawer__cursor">▊</span>
              </div>
            </div>
          </div>
        </div>

        <!-- Footer -->
        <div class="terminal-drawer__footer">
          <span class="terminal-drawer__shortcut">Ctrl+` to toggle</span>
          <button
            class="terminal-drawer__action-btn"
            :data-testid="'terminal-minimize-btn'"
            :aria-label="'Minimize terminal'"
            @click="emit('close')"
          >
            Minimize
          </button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.terminal-drawer {
  position: fixed;
  inset: 0;
  z-index: 1000;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
}

.terminal-drawer__overlay {
  position: absolute;
  inset: 0;
  background: rgba(0,0,0,0.3);
}

.terminal-drawer__panel {
  position: relative;
  z-index: 1;
  background: #1A1A1A;
  border-top-left-radius: 12px;
  border-top-right-radius: 12px;
  display: flex;
  flex-direction: column;
  max-height: 60vh;
  overflow: hidden;
}

.terminal-drawer__header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 8px 16px;
  background: #2A2A2E;
  border-bottom: 1px solid #3A3A3E;
}

.terminal-drawer__tabs {
  display: flex;
  gap: 4px;
}

.terminal-drawer__tab {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: #999;
  padding: 4px 12px;
  border-radius: 4px;
  cursor: pointer;
}

.terminal-drawer__tab--active {
  color: #fff;
  background: #3A3A3E;
}

.terminal-drawer__timer {
  font-family: 'SF Mono', monospace;
  font-size: 11px;
  color: #6C31FF;
}

.terminal-drawer__actions {
  display: flex;
  gap: 4px;
}

.terminal-drawer__action-btn {
  background: #3A3A3E;
  color: #ccc;
  border: none;
  padding: 4px 10px;
  border-radius: 4px;
  font-size: 11px;
  cursor: pointer;
  font-family: 'Inter', sans-serif;
}

.terminal-drawer__action-btn:hover {
  background: #4A4A4E;
  color: #fff;
}

.terminal-drawer__action-btn:focus-visible {
  outline: 2px solid #6C31FF;
  outline-offset: 2px;
}

.terminal-drawer__action-btn--close {
  font-size: 14px;
  padding: 4px 8px;
}

.terminal-drawer__body {
  flex: 1;
  overflow-y: auto;
  padding: 12px 16px;
  font-family: 'SF Mono', 'Menlo', monospace;
  font-size: 13px;
  line-height: 1.6;
  color: #E0E0E0;
}

.terminal-drawer__cmd-line {
  display: flex;
  gap: 8px;
  margin-bottom: 8px;
  color: #00FF88;
  word-break: break-all;
}

.terminal-drawer__prompt {
  color: #6C31FF;
  font-weight: 700;
}

.terminal-drawer__executing {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 0;
  color: #6C31FF;
}

.terminal-drawer__spinner {
  width: 12px;
  height: 12px;
  border: 2px solid #3A3A3E;
  border-top-color: #6C31FF;
  border-radius: 50%;
  animation: spin 0.6s linear infinite;
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

.terminal-drawer__error-line {
  color: #FF5555;
  padding: 4px 0;
}

.terminal-drawer__stdout { color: #00FF88; }
.terminal-drawer__stderr { color: #FF5555; }

.terminal-drawer__stdout pre,
.terminal-drawer__stderr pre {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-all;
}

.terminal-drawer__exit-line {
  display: flex;
  gap: 12px;
  margin-top: 8px;
  padding-top: 8px;
  border-top: 1px solid #3A3A3E;
  font-size: 12px;
  color: #999;
}

.terminal-drawer__validated {
  color: #00C875;
}

.terminal-drawer__explain {
  color: #7A7A80;
  font-style: italic;
}

.terminal-drawer__idle {
  padding: 8px 0;
}

.terminal-drawer__cursor-line {
  display: flex;
  gap: 8px;
}

.terminal-drawer__cursor {
  animation: blink 1s step-end infinite;
}

@keyframes blink {
  50% { opacity: 0; }
}

.terminal-drawer__footer {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 6px 16px;
  background: #2A2A2E;
  border-top: 1px solid #3A3A3E;
}

.terminal-drawer__shortcut {
  font-size: 10px;
  color: #7A7A80;
}

.text-green { color: #00C875; }
.text-red { color: #FF5555; }
</style>
