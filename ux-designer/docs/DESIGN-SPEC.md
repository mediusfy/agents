# Canonical Design Specification

## Decision: Monday Design System

All pages must use the **monday-* design language**:
- **Font:** Inter (Google Fonts) — no system font stack
- **Base width:** 1440px viewport
- **Accent color:** #6C31FF (purple)
- **Background:** #F5F5F7 (content area)
- **Surfaces:** #FFFFFF with border #E8E8EC
- **Nav:** Left sidebar 240px, background #F9F9FB, border-right #EBEBED
- **Topbar:** 52px, border-bottom #EBEBED
- **Border radius:** 10px cards, 6px buttons, 999px pills
- **Body text:** 14px / #1A1A1A
- **Secondary text:** #555 / #7A7A80 / #999
- **Tabs:** 12px font, 500 weight, active underline with #6C31FF
- **Shadow:** None on surfaces. Only `box-shadow: 0 2px 12px rgba(0,0,0,0.04)` on hover

## Navigation Structure

```
Left Nav (240px):
  Logo: "R" icon in #6C31FF square
  "Workspace" section:
    Home          (house icon)
    Agents        (grid icon) — badge count
    Workloads     (monitor icon) — badge count
    Automations   (briefcase icon)
  "Configure" section:
    Logs          (clock icon)
    Notes         (edit icon)
  Footer:
    Agent Health (pills)
    User avatar + name
```

## Page Layout

Each page follows this shell:
```
.app (1440x900, flex, white background, border-radius 12px)
  .leftnav (240px, fixed)
  .main (flex:1, flex column)
    .topbar (52px, h1 title, actions right-aligned)
    .content (flex:1, overflow-y:auto, padding 24px, bg #F5F5F7)
```

## Template Sections Per Page

Every content page should contain, at minimum:
1. Welcome/header section with cluster status
2. Content-specific widgets (tables, cards, metrics bars)
3. Recent activity feed
4. AI/agent action prompts where appropriate

## Empty, Loading, and Error States

Every list/table must handle:
- **Loading:** Skeleton lines with pulse animation (bg #E8E8EC rounded rectangles)
- **Empty:** Illustration-free empty state: heading "No items yet" / body text / optional action button
- **Error:** Red-tinted card "Failed to load" / retry button

## Accessibility Baseline

- All interactive elements: `tabindex="0"` or native `<button>`/`<a>`
- `role="tablist"` on tab bars, `role="tab"` and `aria-selected` on tabs
- `aria-label` on icon-only buttons
- `focus-visible` outline: 2px solid #6C31FF, offset 2px
- Color is never the only status indicator — always add text labels
- Status dot + label pattern for severities / health

## Strategy Theme Integration

Place these as upcoming sections (commented where not yet interactive):

### Theme 1 — GitOps PR Cards
In workloads and monitoring views: "Right-size Deployment-X to save $400/mo → [Generate PR]"

### Theme 2 — FinOps Waste Heatmap
In home and monitoring: waste observation cards with "Generate PR" action

### Theme 3 — Autonomous Agent Activity
Agent activity feed showing auto-triage summaries. "before the SRE is paged" pattern.

### Theme 4 — Executable Runbooks
In Notes view: markdown viewer with executable code blocks

## Color System

| Token | Hex | Usage |
|-------|-----|-------|
| accent | #6C31FF | Primary buttons, active nav, badges |
| accent-hover | #5B28E0 | Button hover |
| success | #00C875 | Healthy, active, resolved |
| warning | #FFAD42 | Warning, progressing |
| danger | #D93025 | Critical, error, degraded |
| text-primary | #1A1A1A | Headings |
| text-secondary | #555 | Body |
| text-tertiary | #7A7A80 | Metadata |
| text-muted | #999 | Labels |
| surface | #FFFFFF | Cards |
| surface-subtle | #F5F5F7 | Page bg |
| surface-nav | #F9F9FB | Sidebar bg |
| border | #E8E8EC | Card borders |
| border-light | #EBEBED | Layout borders |
## Page-Specific Requirements

### Home (launchpad)
- Welcome card with OpenClaw shield icon
- Metrics bar: Active Agents, Avg CPU, Avg Memory, Artifacts Today
- Two-column grid: Recent Activity (left) / Quick Actions (right)
- Two-column grid: Active Agents (agent name, status dot, capabilities) / Today's Artifacts

### Workloads
- Tab bar: Pods, Deployments, StatefulSets, DaemonSets, Jobs, Cron Jobs
- Filter bar with search input + namespace/status dropdowns
- Sortable table with status badges
- Debug Pod primary action button

### Monitoring
- Alert severity summary cards (Critical / Warnings / Resolved / Avg Response)
- Filtered alert table with severity, name, status, source, value, time
- AI Diagnostics footer card

### Agents
- Welcome banner with agent count + health pills
- Metrics bar: Agents, Total CPU, Total Memory, Savings/month
- Tab filter: All Agents, Watchers, Schedulers, Analyzers, Integrations
- Agent cards grid (3 columns): icon, name, status badge, description, CPU/Memory/Scope metrics, action buttons (pause/restart/logs/configure)
- Recent Agent Activity feed
- Data & Privacy footer bar

### Cluster
- Node summary cards (status, CPU, memory, pods)
- Node table with health indicators

### All Other Pages
- At minimum: proper sidebar, topbar, content area with relevant placeholder content
- No copy-pasted "Workloads" body with wrong title

## Component Library (to be extracted)

### Atoms
- Button: default variant (.tb-btn), purple variant (.tb-btn.purple), icon-only (.aqb)
- StatusDot: .sdot with .green/.orange/.purple/.red classes
- Badge: pill pattern with .as-green/.as-orange/.as-purple
- Input: search input with icon
- Tab: .tab with .tab.active

### Molecules
- LeftNavItem: icon + label + optional badge + optional active bar
- StatusCard: severity label, metric value, change indicator
- AgentCard: avatar circle, name, status, description, metrics grid, action buttons
- TableRow: cells with status indicator, monospace name, badges

### Organisms
- Sidebar (leftnav): nav items + health footer + user footer
- TopBar: title + actions
- ContentArea: scrollable container
- MetricsBar: horizontal metric pills
