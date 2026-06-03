import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import TerminalDrawer from '../atoms/TerminalDrawer.vue'
import PrActionCard from '../atoms/PrActionCard.vue'
import type { ExecutionResult } from '../../types/api'

// ── TerminalDrawer ──────────────────────────────────────────────

// TerminalDrawer uses <Teleport to="body">. Stub Teleport so content
// renders inline for testing, avoiding happy-dom Teleport issues.

describe('TerminalDrawer', () => {
  function mountDrawer(props: Record<string, unknown> = {}) {
    return mount(TerminalDrawer, {
      props,
      global: {
        stubs: {
          Teleport: {
            template: '<div><slot /></div>',
          },
        },
      },
    })
  }

  it('renders closed state (hidden)', () => {
    const wrapper = mountDrawer({ open: false })
    expect(wrapper.find('[role="region"]').exists()).toBe(false)
  })

  it('renders open state with default title', () => {
    const wrapper = mountDrawer({ open: true })
    expect(wrapper.text()).toContain('Terminal')
  })

  it('shows executing state', () => {
    const wrapper = mountDrawer({ open: true, executing: true })
    expect(wrapper.text()).toContain('Executing...')
  })

  it('shows error state', () => {
    const wrapper = mountDrawer({ open: true, error: 'Error: something went wrong' })
    expect(wrapper.text()).toContain('Error: something went wrong')
  })

  it('shows result stdout', () => {
    const result: ExecutionResult = {
      stdout: 'hello world\n',
      stderr: '',
      exit_code: 0,
      validated: true,
    }
    const wrapper = mountDrawer({ open: true, result })
    expect(wrapper.text()).toContain('hello world')
  })

  it('shows exit code and validation', () => {
    const result: ExecutionResult = {
      stdout: 'done',
      stderr: '',
      exit_code: 0,
      validated: true,
      explanation: 'output matches expected pattern',
    }
    const wrapper = mountDrawer({ open: true, result })
    expect(wrapper.text()).toContain('Exit code:')
    expect(wrapper.text()).toContain('Validated')
  })

  it('emits close on overlay click', async () => {
    const wrapper = mountDrawer({ open: true })
    await wrapper.find('.terminal-drawer__overlay').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('emits rerun on rerun button click', async () => {
    const wrapper = mountDrawer({ open: true })
    await wrapper.find('[data-testid="terminal-rerun-btn"]').trigger('click')
    expect(wrapper.emitted('rerun')).toBeTruthy()
  })

  it('emits close on minimize button click', async () => {
    const wrapper = mountDrawer({ open: true })
    await wrapper.find('[data-testid="terminal-minimize-btn"]').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('emits toggle on Ctrl+Backtick', async () => {
    const wrapper = mountDrawer({ open: true })
    window.dispatchEvent(new KeyboardEvent('keydown', { ctrlKey: true, code: 'Backquote' }))
    expect(wrapper.emitted('toggle')).toBeTruthy()
  })
})

// ── PrActionCard ────────────────────────────────────────────────

describe('PrActionCard', () => {
  it('renders title and description', () => {
    const wrapper = mount(PrActionCard, {
      props: {
        title: 'nginx-default/nginx',
        savingsCents: 4520,
        status: 'open',
        description: 'cluster-1 · 500m CPU → 250m CPU',
      },
    })
    expect(wrapper.text()).toContain('nginx-default/nginx')
    expect(wrapper.text()).toContain('cluster-1')
    expect(wrapper.text()).toContain('$45')
  })

  it('formats savings in thousands', () => {
    const wrapper = mount(PrActionCard, {
      props: {
        title: 'large-workload',
        savingsCents: 120000,
        status: 'open',
        description: 'large cost saving opportunity',
      },
    })
    expect(wrapper.text()).toContain('$1.2K')
  })

  it('shows status label for open', () => {
    const wrapper = mount(PrActionCard, {
      props: {
        title: 'test',
        savingsCents: 100,
        status: 'open',
        description: 'test',
      },
    })
    expect(wrapper.text()).toContain('Savings Opportunity')
  })

  it('shows create PR button when status is open', () => {
    const wrapper = mount(PrActionCard, {
      props: {
        title: 'test',
        savingsCents: 100,
        status: 'open',
        description: 'test',
      },
    })
    expect(wrapper.find('[data-testid="generate-pr-btn"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="dismiss-btn"]').exists()).toBe(true)
  })

  it('shows view PR button when status is actioned', () => {
    const wrapper = mount(PrActionCard, {
      props: {
        title: 'test',
        savingsCents: 100,
        status: 'actioned',
        description: 'test',
      },
    })
    expect(wrapper.find('[data-testid="view-pr-btn"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="generate-pr-btn"]').exists()).toBe(false)
  })

  it('shows loading skeleton', () => {
    const wrapper = mount(PrActionCard, {
      props: {
        title: 'test',
        savingsCents: 100,
        status: 'open',
        description: 'test',
        loading: true,
      },
    })
    expect(wrapper.find('.pr-card__skeleton').exists()).toBe(true)
  })

  it('shows error state', () => {
    const wrapper = mount(PrActionCard, {
      props: {
        title: 'test',
        savingsCents: 100,
        status: 'open',
        description: 'test',
        error: 'Failed to load',
      },
    })
    expect(wrapper.text()).toContain('Failed to load')
  })

  it('emits generate-pr event', async () => {
    const wrapper = mount(PrActionCard, {
      props: {
        title: 'test',
        savingsCents: 100,
        status: 'open',
        description: 'test',
      },
    })
    await wrapper.find('[data-testid="generate-pr-btn"]').trigger('click')
    expect(wrapper.emitted('generate-pr')).toBeTruthy()
  })

  it('emits dismiss event', async () => {
    const wrapper = mount(PrActionCard, {
      props: {
        title: 'test',
        savingsCents: 100,
        status: 'open',
        description: 'test',
      },
    })
    await wrapper.find('[data-testid="dismiss-btn"]').trigger('click')
    expect(wrapper.emitted('dismiss')).toBeTruthy()
  })
})

// ── FinOpsWastePanel ────────────────────────────────────────────

describe('FinOpsWastePanel', () => {
  it('renders title when mounted with Pinia', async () => {
    setActivePinia(createPinia())

    const FinOpsWastePanel = (await import('../organisms/FinOpsWastePanel.vue')).default
    const wrapper = mount(FinOpsWastePanel, {
      props: { autoPoll: false, title: 'My Waste Panel' },
    })
    expect(wrapper.text()).toContain('My Waste Panel')
  })
})
