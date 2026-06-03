<script setup lang="ts">
import { ref, onMounted, computed, watch, nextTick } from 'vue'
import { useRunbooksStore } from '../../../stores/runbooks'
import RunbookBlock from '../../atoms/RunbookBlock.vue'
import TerminalDrawer from '../../atoms/TerminalDrawer.vue'
import type { Runbook, RunbookBlock as RunbookBlockType } from '../../../types/api'

interface RunbookViewerProps {
  autoLoad?: boolean
}

const props = withDefaults(defineProps<RunbookViewerProps>(), {
  autoLoad: true,
})

const store = useRunbooksStore()
const tocRef = ref<HTMLElement | null>(null)
const contentRef = ref<HTMLElement | null>(null)
const terminalOpen = ref(false)
const terminalBlockId = ref<string | null>(null)
const activeSectionId = ref('')

onMounted(() => {
  if (props.autoLoad) {
    store.fetchRunbooks()
  }
})

// Extract TOC from first runbook block content
const toc = computed(() => {
  if (!store.currentRunbook) return []
  const lines = store.currentRunbook.blocks
    .filter(b => b.language === 'markdown' || b.language === '')
    .flatMap(b => b.content.split('\n'))
    .filter(l => l.startsWith('##'))
    .map(l => {
      const text = l.replace(/^##+\s*/, '')
      const id = text.toLowerCase().replace(/[^a-z0-9]+/g, '-')
      return { text, id, level: l.startsWith('###') ? 3 : 2 }
    })
  return lines
})

function selectRunbook(runbook: Runbook) {
  store.selectRunbook(runbook.path)
  terminalBlockId.value = null
  terminalOpen.value = false
}

function handleExecuteBlock(blockId: string) {
  terminalBlockId.value = blockId
  terminalOpen.value = true
  store.executeBlock(blockId)
}

function handleRerun() {
  if (terminalBlockId.value) {
    store.executeBlock(terminalBlockId.value)
  }
}

function handleCloseTerminal() {
  terminalOpen.value = false
  terminalBlockId.value = null
}

function toggleTerminal() {
  terminalOpen.value = !terminalOpen.value
}

const currentResult = computed(() => {
  if (!terminalBlockId.value) return null
  return store.getResult(terminalBlockId.value)
})

const currentBlockContent = computed(() => {
  if (!terminalBlockId.value) return ''
  const block = store.currentRunbook?.blocks.find(b => b.id === terminalBlockId.value)
  return block?.content || ''
})

const terminalTitle = computed(() => {
  if (!terminalBlockId.value) return 'Terminal'
  const block = store.currentRunbook?.blocks.find(b => b.id === terminalBlockId.value)
  return block ? `${block.language}: ${block.id}` : 'Terminal'
})
</script>

<template>
  <div
    class="runbook-viewer"
    :data-testid="$attrs['data-testid'] || 'runbook-viewer'"
    role="region"
    aria-label="Runbook Viewer"
  >
    <!-- Loading -->
    <div v-if="store.loading && !store.runbooks.length" class="runbook-viewer__loading">
      <div class="skeleton-line skeleton-line--h1"></div>
      <div class="skeleton-line skeleton-line--p"></div>
      <div class="skeleton-line skeleton-line--code"></div>
    </div>

    <!-- Error -->
    <div v-else-if="store.error && !store.runbooks.length" class="runbook-viewer__error" role="alert">
      <p>{{ store.error }}</p>
      <button class="runbook-viewer__retry-btn" @click="store.fetchRunbooks()">Retry</button>
    </div>

    <template v-else>
      <!-- Runbook selector -->
      <div v-if="store.runbooks.length > 0 && !store.currentRunbook" class="runbook-viewer__picker">
        <h2 class="runbook-viewer__title">Select a Runbook</h2>
        <div class="runbook-viewer__cards">
          <button
            v-for="rb in store.runbooks"
            :key="rb.path"
            class="runbook-viewer__card"
            :data-testid="`runbook-card-${rb.path}`"
            @click="selectRunbook(rb)"
          >
            <span class="runbook-viewer__card-icon">📖</span>
            <span class="runbook-viewer__card-title">{{ rb.title || rb.path }}</span>
            <span class="runbook-viewer__card-blocks">{{ rb.blocks.length }} steps</span>
          </button>
        </div>
      </div>

      <!-- Empty State -->
      <div v-else-if="!store.runbooks.length" class="runbook-viewer__empty">
        <p>No runbooks available</p>
      </div>

      <!-- Current Runbook -->
      <div v-if="store.currentRunbook" class="runbook-viewer__content">
        <!-- TOC sidebar -->
        <aside v-if="toc.length" class="runbook-viewer__toc" ref="tocRef">
          <h3 class="runbook-viewer__toc-title">Contents</h3>
          <a
            v-for="item in toc"
            :key="item.id"
            class="runbook-viewer__toc-link"
            :class="{ 'runbook-viewer__toc-link--h3': item.level === 3 }"
            :data-testid="`toc-link-${item.id}`"
            @click.prevent="activeSectionId = item.id"
          >
            {{ item.text }}
          </a>
          <div class="runbook-viewer__toc-runbooks">
            <button
              class="runbook-viewer__back-btn"
              :data-testid="'runbook-back'"
              @click="store.clearRunbooks()"
            >
              ← All Runbooks
            </button>
          </div>
        </aside>

        <!-- Main content -->
        <div class="runbook-viewer__body" ref="contentRef">
          <h1 class="runbook-viewer__rb-title">{{ store.currentRunbook.title || store.currentRunbook.path }}</h1>

          <div class="runbook-viewer__blocks">
            <template v-for="(block, i) in store.currentRunbook.blocks" :key="block.id">
              <RunbookBlock
                :block="block"
                :executing="store.isExecuting(block.id)"
                :result="store.getResult(block.id)"
                :error="null"
                :data-testid="`runbook-viewer-block-${block.id}`"
                @execute="handleExecuteBlock"
              />
            </template>
          </div>
        </div>
      </div>
    </template>

    <!-- Terminal Drawer -->
    <TerminalDrawer
      :open="terminalOpen"
      :title="terminalTitle"
      :block-content="currentBlockContent"
      :executing="terminalBlockId ? store.isExecuting(terminalBlockId) : false"
      :result="currentResult"
      :error="null"
      :data-testid="'runbook-terminal'"
      @close="handleCloseTerminal"
      @rerun="handleRerun"
      @toggle="toggleTerminal"
    />
  </div>
</template>

<style scoped>
.runbook-viewer {
  display: flex;
  flex-direction: column;
  gap: 16px;
  min-height: 300px;
}

.runbook-viewer__title {
  font-size: 16px;
  font-weight: 600;
  color: #1A1A1A;
  margin: 0 0 12px;
}

.runbook-viewer__cards {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
  gap: 10px;
}

.runbook-viewer__card {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 16px;
  background: #fff;
  border: 1px solid #E8E8EC;
  border-radius: 10px;
  cursor: pointer;
  text-align: left;
  font-family: 'Inter', sans-serif;
  transition: border-color 0.15s;
}

.runbook-viewer__card:hover {
  border-color: #6C31FF;
}

.runbook-viewer__card:focus-visible {
  outline: 2px solid #6C31FF;
  outline-offset: 2px;
}

.runbook-viewer__card-icon { font-size: 24px; }
.runbook-viewer__card-title { font-size: 13px; font-weight: 600; color: #1A1A1A; }
.runbook-viewer__card-blocks { font-size: 11px; color: #7A7A80; }

.runbook-viewer__content {
  display: flex;
  gap: 20px;
}

.runbook-viewer__toc {
  width: 200px;
  flex-shrink: 0;
  position: sticky;
  top: 0;
  align-self: flex-start;
}

.runbook-viewer__toc-title {
  font-size: 12px;
  font-weight: 600;
  color: #7A7A80;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  margin: 0 0 8px;
}

.runbook-viewer__toc-link {
  display: block;
  font-size: 12px;
  color: #555;
  padding: 4px 0 4px 8px;
  border-left: 2px solid transparent;
  cursor: pointer;
  text-decoration: none;
  transition: color 0.15s, border-color 0.15s;
}

.runbook-viewer__toc-link:hover {
  color: #6C31FF;
  border-left-color: #6C31FF;
}

.runbook-viewer__toc-link--h3 {
  padding-left: 20px;
  font-size: 11px;
}

.runbook-viewer__toc-runbooks {
  margin-top: 16px;
}

.runbook-viewer__back-btn {
  font-size: 11px;
  color: #6C31FF;
  background: none;
  border: none;
  cursor: pointer;
  font-family: 'Inter', sans-serif;
}

.runbook-viewer__body {
  flex: 1;
  min-width: 0;
}

.runbook-viewer__rb-title {
  font-size: 20px;
  font-weight: 600;
  color: #1A1A1A;
  margin: 0 0 16px;
}

.runbook-viewer__blocks {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.runbook-viewer__loading,
.runbook-viewer__error,
.runbook-viewer__empty {
  padding: 40px 24px;
  text-align: center;
}

.skeleton-line {
  background: #E8E8EC;
  border-radius: 6px;
  animation: pulse 1.5s infinite;
  margin-bottom: 12px;
}

.skeleton-line--h1 { height: 24px; width: 50%; }
.skeleton-line--p { height: 14px; width: 70%; }
.skeleton-line--code { height: 120px; width: 100%; }

.runbook-viewer__error {
  background: #FFF0F0;
  border-radius: 8px;
  color: #D93025;
}

.runbook-viewer__retry-btn {
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
