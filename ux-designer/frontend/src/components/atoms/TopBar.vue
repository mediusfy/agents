<template>
  <header class="topbar" data-testid="topbar">
    <h1 class="topbar__title">{{ title }}</h1>
    <div class="topbar__actions">
      <slot name="actions" />
      <div
        class="topbar__avatar"
        aria-label="Drew Jocham avatar"
        role="img"
        data-testid="user-avatar"
      >
        D
      </div>
    </div>
  </header>
</template>

<script setup lang="ts">
defineProps<{
  title: string;
}>();
</script>

<style scoped>
.topbar {
  height: var(--topbar-height);
  border-bottom: 1px solid var(--color-border-light);
  display: flex;
  align-items: center;
  padding: 0 24px;
  gap: 16px;
  flex-shrink: 0;
  background: var(--color-surface);
}

.topbar__title {
  font-size: var(--font-size-2xl);
  font-weight: 600;
  color: var(--color-text-primary);
  letter-spacing: -0.01em;
}

.topbar__actions {
  margin-left: auto;
  display: flex;
  gap: 6px;
  align-items: center;
}

.topbar__avatar {
  width: 30px;
  height: 30px;
  border-radius: var(--radius-full);
  background: linear-gradient(135deg, var(--color-accent), #8A5CFF);
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  transition: opacity var(--transition-fast);
}

.topbar__avatar:hover {
  opacity: 0.85;
}

.topbar__avatar:focus-visible {
  outline: 2px solid var(--color-accent);
  outline-offset: 2px;
}
</style>
