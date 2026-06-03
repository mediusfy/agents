<template>
  <div class="page">
    <TopBar title="Notes">
      <template #actions>
        <button class="btn btn--small" aria-label="New runbook" data-testid="new-runbook-btn">+ New Runbook</button>
      </template>
    </TopBar>

    <div class="content">
      <!-- Split: Runbook picker (left) + Runbook viewer (right) -->
      <div class="notes-layout" data-testid="notes-layout">
        <!-- Runbook List / Picker -->
        <aside class="notes-sidebar" data-testid="notes-sidebar">
          <div class="notes-sidebar__header">
            <h3 class="notes-sidebar__title">Runbooks</h3>
          </div>
          <div class="notes-sidebar__search">
            <input
              v-model="runbookSearch"
              type="text"
              class="notes-sidebar__input"
              placeholder="Search runbooks..."
              aria-label="Search runbooks"
              data-testid="runbook-search"
            />
          </div>

          <div v-if="loading" class="notes-sidebar__loading" data-testid="runbook-list-loading">
            <div v-for="i in 3" :key="i" class="skeleton skeleton--card" style="margin-bottom: 8px;"></div>
          </div>

          <div v-else-if="filteredRunbooks.length === 0" class="empty-state" data-testid="runbook-list-empty">
            <div class="empty-state__heading">No runbooks found</div>
          </div>

          <div v-else class="notes-sidebar__list">
            <button
              v-for="rb in filteredRunbooks"
              :key="rb.path"
              class="runbook-entry"
              :class="{ 'runbook-entry--active': selectedRunbook === rb.path }"
              :data-testid="`runbook-entry-${rb.id}`"
              @click="selectedRunbook = rb.path"
            >
              <div class="runbook-entry__icon">📖</div>
              <div class="runbook-entry__info">
                <div class="runbook-entry__title">{{ rb.title }}</div>
                <div class="runbook-entry__meta">{{ rb.blocks }} blocks · {{ rb.executable }} executable</div>
              </div>
            </button>
          </div>
        </aside>

        <!-- Runbook Viewer -->
        <main class="notes-viewer" data-testid="runbook-viewer-area">
          <div v-if="!selectedRunbook" class="empty-state" style="padding-top: 80px;">
            <div class="empty-state__heading">Select a runbook</div>
            <div class="empty-state__body">Choose a runbook from the sidebar to view its contents.</div>
          </div>

          <RunbookViewer
            v-else-if="featureFlags.executableRunbooks.value"
            :runbook-path="selectedRunbook"
            data-testid="runbook-viewer-component"
          />

          <!-- Fallback if feature flag off -->
          <div v-else class="empty-state">
            <div class="empty-state__heading">Runbook Viewer</div>
            <div class="empty-state__body">Executable runbooks are currently disabled. Enable via feature flags.</div>
          </div>
        </main>
      </div>

      <!-- Terminal Drawer (global, toggled by RunbookBlock execution) -->
      <TerminalDrawer
        v-if="featureFlags.executableRunbooks.value"
        ref="terminalDrawer"
        data-testid="global-terminal-drawer"
      />
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue';
import TopBar from '../components/atoms/TopBar.vue';
import RunbookViewer from '../components/molecules/RunbookViewer.vue';
import TerminalDrawer from '../components/atoms/TerminalDrawer.vue';
import { useFeatureFlags } from '../composables/useFeatureFlags';

const featureFlags = useFeatureFlags();

const selectedRunbook = ref('');
const runbookSearch = ref('');
const loading = ref(false);

const runbooks = [
  {
    id: 'redis-failover',
    path: 'runbooks/redis-failover.md',
    title: 'Redis Failover Procedure',
    blocks: 4,
    executable: 3,
  },
  {
    id: 'cert-rotation',
    path: 'runbooks/cert-rotation.md',
    title: 'Certificate Rotation',
    blocks: 6,
    executable: 4,
  },
  {
    id: 'incident-response',
    path: 'runbooks/incident-response.md',
    title: 'Incident Response',
    blocks: 8,
    executable: 5,
  },
  {
    id: 'node-drain',
    path: 'runbooks/node-drain.md',
    title: 'Node Drain Procedure',
    blocks: 5,
    executable: 3,
  },
];

const filteredRunbooks = computed(() => {
  if (!runbookSearch.value) return runbooks;
  const q = runbookSearch.value.toLowerCase();
  return runbooks.filter((rb) => rb.title.toLowerCase().includes(q));
});
</script>

<style scoped>
.page {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
}

.content {
  flex: 1;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  padding: 0;
  background: var(--color-surface-subtle);
}

.notes-layout {
  flex: 1;
  display: flex;
  overflow: hidden;
}

/* Sidebar */
.notes-sidebar {
  width: 280px;
  border-right: 1px solid var(--color-border);
  background: var(--color-surface);
  display: flex;
  flex-direction: column;
  flex-shrink: 0;
}

.notes-sidebar__header {
  padding: 16px 16px 8px;
}

.notes-sidebar__title {
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary);
}

.notes-sidebar__search {
  padding: 8px 16px;
}

.notes-sidebar__input {
  width: 100%;
  padding: 6px 10px;
  border: 1px solid var(--color-border-input);
  border-radius: var(--radius-sm);
  font-size: 12px;
  font-family: inherit;
  color: var(--color-text-primary);
  background: var(--color-surface-subtle);
  outline: none;
}

.notes-sidebar__input::placeholder { color: var(--color-text-muted); }
.notes-sidebar__input:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 2px; }

.notes-sidebar__list {
  flex: 1;
  overflow-y: auto;
  padding: 0 8px;
}

.runbook-entry {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  padding: 8px;
  border-radius: var(--radius-sm);
  background: none;
  border: none;
  font-family: inherit;
  width: 100%;
  text-align: left;
  cursor: pointer;
  transition: background var(--transition-fast);
}

.runbook-entry:hover {
  background: var(--color-surface-subtle);
}

.runbook-entry--active {
  background: var(--color-accent-light);
}

.runbook-entry:focus-visible {
  outline: 2px solid var(--color-accent);
  outline-offset: -2px;
}

.runbook-entry__icon {
  font-size: 16px;
  flex-shrink: 0;
}

.runbook-entry__title {
  font-size: 12px;
  font-weight: 600;
  color: var(--color-text-primary);
}

.runbook-entry__meta {
  font-size: 10px;
  color: var(--color-text-tertiary);
  margin-top: 1px;
}

/* Viewer area */
.notes-viewer {
  flex: 1;
  overflow-y: auto;
  padding: 24px;
}

/* Skeleton */
.skeleton {
  background: var(--color-border);
  border-radius: var(--radius-sm);
  animation: pulse 1.5s ease-in-out infinite;
  height: 60px;
}

@keyframes pulse {
  0%, 100% { opacity: 0.6; }
  50% { opacity: 1; }
}
</style>
