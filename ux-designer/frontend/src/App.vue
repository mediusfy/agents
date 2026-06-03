<template>
  <div class="app" data-testid="app-shell">
    <LeftNav />
    <div class="main">
      <router-view v-slot="{ Component, route }">
        <keep-alive>
          <component :is="Component" :key="route.path" />
        </keep-alive>
      </router-view>
    </div>
  </div>
</template>

<script setup lang="ts">
import { watch } from 'vue';
import { useRouter } from 'vue-router';
import LeftNav from './components/atoms/LeftNav.vue';

const router = useRouter();

// Auto-redirect to home on bare load
watch(
  () => router.currentRoute.value.path,
  (path) => {
    if (path === '/') return;
  },
  { immediate: true }
);
</script>

<style>
/* Global reset and base styles */
*,
*::before,
*::after {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: var(--font-family);
  background: var(--color-surface-subtle);
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
  padding: 20px;
  color: var(--color-text-primary);
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

.app {
  width: 1440px;
  height: 900px;
  display: flex;
  background: var(--color-surface);
  overflow: hidden;
  border-radius: var(--radius-xl);
  box-shadow: 0 4px 40px rgba(0, 0, 0, 0.06);
}

.main {
  flex: 1;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  min-width: 0;
}

/* Scrollbar styling */
::-webkit-scrollbar {
  width: 6px;
}

::-webkit-scrollbar-track {
  background: transparent;
}

::-webkit-scrollbar-thumb {
  background: #D0D0D4;
  border-radius: 3px;
}

::-webkit-scrollbar-thumb:hover {
  background: #B0B0B6;
}

/* Shared button styles */
.btn {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 7px 14px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--color-border-input);
  background: var(--color-surface);
  color: var(--color-text-secondary);
  font-size: var(--font-size-base);
  font-family: inherit;
  cursor: pointer;
  font-weight: 500;
  transition: background var(--transition-fast), color var(--transition-fast), border-color var(--transition-fast);
}

.btn:hover {
  background: var(--color-surface-subtle);
  color: #333;
  border-color: #C0C0C6;
}

.btn:focus-visible {
  outline: 2px solid var(--color-accent);
  outline-offset: 2px;
}

.btn--primary {
  background: var(--color-accent);
  color: #fff;
  border-color: var(--color-accent);
}

.btn--primary:hover {
  background: var(--color-accent-hover);
}

.btn--small {
  padding: 5px 10px;
  font-size: 11px;
}

/* Status dot */
.sdot {
  width: 6px;
  height: 6px;
  border-radius: var(--radius-full);
  flex-shrink: 0;
}

.sdot.green { background: var(--color-success); }
.sdot.orange { background: var(--color-warning); }
.sdot.red { background: var(--color-danger); }
.sdot.purple { background: var(--color-accent); }

/* Card */
.card {
  background: var(--color-surface);
  border-radius: var(--radius-lg);
  border: 1px solid var(--color-border);
  padding: 20px;
}

.card__title {
  font-size: 13px;
  font-weight: 600;
  color: var(--color-text-primary);
  margin-bottom: 12px;
  display: flex;
  align-items: center;
  gap: 6px;
}

.card__title :deep(svg) {
  width: 14px;
  height: 14px;
  stroke: var(--color-accent);
}

.card__title .badge-count {
  font-size: 10px;
  padding: 2px 7px;
  border-radius: var(--radius-full);
  background: var(--color-accent-light);
  color: var(--color-accent);
  font-weight: 500;
  margin-left: auto;
}

/* Loading skeleton */
.skeleton {
  background: var(--color-border);
  border-radius: var(--radius-sm);
  animation: pulse 1.5s ease-in-out infinite;
}

@keyframes pulse {
  0%, 100% { opacity: 0.6; }
  50% { opacity: 1; }
}

.skeleton--text {
  height: 12px;
  margin-bottom: 8px;
  width: 80%;
}

.skeleton--card {
  height: 60px;
  border-radius: var(--radius-md);
}

/* Empty state */
.empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  padding: 32px 16px;
  text-align: center;
}

.empty-state__heading {
  font-size: 14px;
  font-weight: 600;
  color: var(--color-text-primary);
}

.empty-state__body {
  font-size: 12px;
  color: var(--color-text-tertiary);
}

/* Error state */
.error-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  padding: 24px;
  background: var(--color-danger-bg);
  border: 1px solid var(--color-danger);
  border-radius: var(--radius-lg);
}

.error-state__message {
  font-size: 13px;
  color: var(--color-danger-text);
  font-weight: 500;
}

/* Pill badge */
.pill-small {
  font-size: 9px;
  padding: 1px 5px;
  border-radius: 3px;
  font-weight: 500;
}

.pill-small--finops {
  background: var(--color-accent-light);
  color: var(--color-accent);
}

.pill-small--coming-soon {
  background: var(--color-warning-bg);
  color: var(--color-warning-text);
}
</style>
