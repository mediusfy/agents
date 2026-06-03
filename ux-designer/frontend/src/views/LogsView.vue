<template>
  <div class="page">
    <TopBar title="Logs" />
    <div class="content">
      <div class="logs-placeholder" data-testid="logs-placeholder">
        <div class="filter-bar">
          <div class="filter-bar__search">
            <svg viewBox="0 0 24 24" class="filter-bar__search-icon" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>
            </svg>
            <input type="text" class="filter-bar__input" placeholder="Search logs..." data-testid="log-search" />
          </div>
          <select class="filter-bar__select" data-testid="log-service-filter">
            <option>All Services</option>
            <option>api-gateway</option>
            <option>agent-controller</option>
            <option>pr-bridge</option>
            <option>finops-analyzer</option>
            <option>runbook-mcp</option>
          </select>
          <select class="filter-bar__select" data-testid="log-level-filter">
            <option>All Levels</option>
            <option>ERROR</option>
            <option>WARN</option>
            <option>INFO</option>
            <option>DEBUG</option>
          </select>
        </div>
        <div class="log-list" data-testid="log-list">
          <div v-for="log in logs" :key="log.id" class="log-entry" :data-testid="`log-${log.id}`">
            <span class="log-entry__time">{{ log.time }}</span>
            <span class="log-entry__level" :class="`log-entry__level--${log.level.toLowerCase()}`">{{ log.level }}</span>
            <span class="log-entry__service">{{ log.service }}</span>
            <span class="log-entry__message">{{ log.message }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import TopBar from '../components/atoms/TopBar.vue';

const logs = [
  { id: 'l1', time: '14:32:01', level: 'ERROR', service: 'pr-bridge', message: 'POST /api/v1/prs failed: ErrGitHubAuth (token expired)' },
  { id: 'l2', time: '14:31:45', level: 'WARN', service: 'agent-controller', message: 'Agent finops-analyzer execution took 47.2s (threshold: 30s)' },
  { id: 'l3', time: '14:31:12', level: 'INFO', service: 'finops-analyzer', message: 'Scanned 14 workloads, detected 3 over-provisioned' },
  { id: 'l4', time: '14:30:00', level: 'INFO', service: 'runbook-mcp', message: 'Executed block step-1 from runbooks/redis-failover.md (exit: 0)' },
  { id: 'l5', time: '14:29:33', level: 'WARN', service: 'anomstack-consumer', message: 'Deduplicated alert alert-9821 (last seen 3m ago)' },
  { id: 'l6', time: '14:28:00', level: 'INFO', service: 'pr-bridge', message: 'Created PR #249 for drewjocham/agents (fix/rightsize-api)' },
];
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
  overflow-y: auto;
  padding: 24px;
  background: var(--color-surface-subtle);
}

.logs-placeholder {
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-lg);
  overflow: hidden;
}

.filter-bar {
  display: flex;
  gap: 8px;
  padding: 12px 16px;
  border-bottom: 1px solid var(--color-border);
  background: var(--color-surface);
}

.filter-bar__search {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 12px;
  border: 1px solid var(--color-border-input);
  border-radius: var(--radius-sm);
  flex: 1;
  max-width: 260px;
}

.filter-bar__search-icon { color: var(--color-text-muted); }

.filter-bar__input {
  border: none;
  background: none;
  font-size: 12px;
  font-family: inherit;
  color: var(--color-text-primary);
  outline: none;
  width: 100%;
}

.filter-bar__select {
  padding: 6px 10px;
  border: 1px solid var(--color-border-input);
  border-radius: var(--radius-sm);
  font-size: 12px;
  font-family: inherit;
  color: var(--color-text-secondary);
  background: var(--color-surface);
}

.log-list {
  padding: 8px 0;
  font-family: 'SF Mono', 'Fira Code', 'Consolas', monospace;
  font-size: 12px;
}

.log-entry {
  display: flex;
  gap: 12px;
  padding: 4px 16px;
  color: var(--color-text-secondary);
}

.log-entry:hover {
  background: var(--color-surface-subtle);
}

.log-entry__time { color: var(--color-text-muted); flex-shrink: 0; }
.log-entry__level { width: 50px; flex-shrink: 0; font-weight: 600; }
.log-entry__level--error { color: var(--color-danger); }
.log-entry__level--warn { color: var(--color-warning-text); }
.log-entry__level--info { color: var(--color-success-text); }
.log-entry__service { width: 130px; flex-shrink: 0; color: var(--color-accent); }
.log-entry__message { flex: 1; }
</style>
