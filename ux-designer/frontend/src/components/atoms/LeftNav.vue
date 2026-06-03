<template>
  <nav class="leftnav" data-testid="left-nav" aria-label="Workspace navigation">
    <div class="leftnav__header">
      <div class="leftnav__logo" aria-label="Rufkis logo">R</div>
      <span class="leftnav__name">Rufkis</span>
    </div>

    <div class="leftnav__section-label">Workspace</div>

    <router-link
      v-for="item in navItems.workspace"
      :key="item.path"
      :to="item.path"
      class="leftnav__item"
      :class="{ 'leftnav__item--active': isActive(item.path) }"
      :data-testid="`nav-${item.id}`"
      :aria-current="isActive(item.path) ? 'page' : undefined"
    >
      <span class="leftnav__item-icon" v-html="item.icon"></span>
      <span class="leftnav__item-label">{{ item.label }}</span>
      <span v-if="item.badge" class="leftnav__badge">{{ item.badge }}</span>
    </router-link>

    <div class="leftnav__section-label">Configure</div>

    <router-link
      v-for="item in navItems.configure"
      :key="item.path"
      :to="item.path"
      class="leftnav__item"
      :class="{ 'leftnav__item--active': isActive(item.path) }"
      :data-testid="`nav-${item.id}`"
      :aria-current="isActive(item.path) ? 'page' : undefined"
    >
      <span class="leftnav__item-icon" v-html="item.icon"></span>
      <span class="leftnav__item-label">{{ item.label }}</span>
    </router-link>

    <div class="leftnav__footer">
      <div class="leftnav__health">
        <div class="leftnav__health-label">Agent Health</div>
        <div class="leftnav__health-pills">
          <span class="pill pill--green">SRE</span>
          <span class="pill pill--green">Backend</span>
          <span class="pill pill--orange">Frontend</span>
          <span class="pill pill--green">DevOps</span>
          <span class="pill pill--purple">Security</span>
        </div>
      </div>
      <div class="leftnav__user" data-testid="nav-user">
        <div class="leftnav__user-avatar">D</div>
        <span class="leftnav__user-name">Drew Jocham</span>
      </div>
    </div>
  </nav>
</template>

<script setup lang="ts">
import { useRoute } from 'vue-router';

const route = useRoute();

interface NavItem {
  id: string;
  path: string;
  label: string;
  icon: string;
  badge?: number;
}

const navItems = {
  workspace: [
    {
      id: 'home',
      path: '/',
      label: 'Home',
      icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
    },
    {
      id: 'agents',
      path: '/agents',
      label: 'Agents',
      badge: 5,
      icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2"/><line x1="3" y1="9" x2="21" y2="9"/><circle cx="12" cy="13" r="1"/><circle cx="8" cy="13" r="1"/><circle cx="16" cy="13" r="1"/></svg>',
    },
    {
      id: 'workloads',
      path: '/workloads',
      label: 'Workloads',
      badge: 48,
      icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>',
    },
    {
      id: 'automations',
      path: '/automations',
      label: 'Automations',
      icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2a2 2 0 012 2v2h3a3 3 0 013 3v9a3 3 0 01-3 3H7a3 3 0 01-3-3V9a3 3 0 013-3h3V4a2 2 0 012-2z"/></svg>',
    },
  ] as NavItem[],
  configure: [
    {
      id: 'logs',
      path: '/logs',
      label: 'Logs',
      icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>',
    },
    {
      id: 'notes',
      path: '/notes',
      label: 'Notes',
      icon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 20h9M16.5 3.5a2.121 2.121 0 013 3L7 19l-4 1 1-4L16.5 3.5z"/></svg>',
    },
  ] as NavItem[],
};

function isActive(path: string): boolean {
  if (path === '/') return route.path === '/';
  return route.path.startsWith(path);
}
</script>

<style scoped>
.leftnav {
  width: 240px;
  background: var(--color-surface-nav);
  border-right: 1px solid var(--color-border-light);
  display: flex;
  flex-direction: column;
  flex-shrink: 0;
  min-height: 0;
}

.leftnav__header {
  padding: 16px 16px 8px;
  display: flex;
  align-items: center;
  gap: 8px;
}

.leftnav__logo {
  width: 28px;
  height: 28px;
  border-radius: 8px;
  background: var(--color-accent);
  display: flex;
  align-items: center;
  justify-content: center;
  color: #fff;
  font-weight: 700;
  font-size: 14px;
}

.leftnav__name {
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary);
}

.leftnav__section-label {
  padding: 12px 12px 4px;
  font-size: 10px;
  font-weight: 600;
  color: var(--color-text-muted);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.leftnav__item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 7px 12px;
  margin: 0 6px;
  border-radius: 6px;
  font-size: 13px;
  font-weight: 500;
  color: var(--color-text-secondary);
  cursor: pointer;
  text-decoration: none;
  position: relative;
  transition: background var(--transition-fast), color var(--transition-fast);
}

.leftnav__item:hover {
  background: rgba(108, 49, 255, 0.04);
  color: #333;
}

.leftnav__item--active {
  background: rgba(108, 49, 255, 0.08);
  color: var(--color-accent);
  font-weight: 600;
}

.leftnav__item--active::before {
  content: '';
  position: absolute;
  left: -6px;
  width: 3px;
  height: 16px;
  border-radius: 0 3px 3px 0;
  background: var(--color-accent);
}

.leftnav__item:focus-visible {
  outline: 2px solid var(--color-accent);
  outline-offset: -2px;
}

.leftnav__item-icon {
  width: 16px;
  height: 16px;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.leftnav__item-icon :deep(svg) {
  width: 14px;
  height: 14px;
}

.leftnav__badge {
  margin-left: auto;
  font-size: 10px;
  padding: 1px 6px;
  border-radius: var(--radius-full);
  background: rgba(108, 49, 255, 0.1);
  color: var(--color-accent);
  font-weight: 600;
}

.leftnav__footer {
  margin-top: auto;
  padding: 12px;
  border-top: 1px solid var(--color-border-light);
}

.leftnav__health {
  padding: 8px;
  border-radius: 8px;
  background: #FAFAFC;
  border: 1px solid #F0F0F2;
  margin-bottom: 8px;
}

.leftnav__health-label {
  font-size: 10px;
  font-weight: 600;
  color: var(--color-text-muted);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin-bottom: 6px;
}

.leftnav__health-pills {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}

.pill {
  display: flex;
  align-items: center;
  font-size: 10px;
  padding: 2px 8px;
  border-radius: var(--radius-full);
  font-weight: 500;
}

.pill--green {
  background: var(--color-success-bg);
  color: var(--color-success-text);
}

.pill--orange {
  background: var(--color-warning-bg);
  color: var(--color-warning-text);
}

.pill--purple {
  background: var(--color-accent-light);
  color: var(--color-accent);
}

.leftnav__user {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 7px 8px;
  border-radius: 6px;
  font-size: 12px;
  color: #777;
  cursor: pointer;
}

.leftnav__user:hover {
  background: rgba(108, 49, 255, 0.03);
  color: #333;
}

.leftnav__user-avatar {
  width: 20px;
  height: 20px;
  border-radius: 6px;
  background: linear-gradient(135deg, var(--color-accent), #8A5CFF);
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 10px;
  font-weight: 600;
}

.leftnav__user-name {
  font-size: 12px;
}
</style>
