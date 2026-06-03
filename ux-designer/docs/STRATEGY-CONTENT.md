# Strategy Theme Content — Supplement to DESIGN-SPEC.md

These are specific UI elements that should appear in mock views to align the dashboard with the 4 strategic themes from STRATEGY-2026-05-31.md.

## Theme 1: GitOps-Native Remediation (PR Cards)

**Where to show:**
- **Workloads view:** After each pod/deployment row that has a problem state (CrashLoopBackOff, OOMKilled), show a small inline action: "Diagnose → Generate PR" 
- **Monitoring view:** AI diagnostics card should offer "Generate PR" as a primary action alongside "Deploy"
- **Any FinOps waste card:** "Right-size deployment-X to save $400/mo → [Generate PR]"

**Visual pattern:**
```
[action card with icon]
"Pod api-gateway-7f8b9 is CrashLoopBackOff (restart 12x in 5m)"
[Diagnose] [Generate PR →] 
```

## Theme 2: Automated FinOps ROI

**Where to show:**
- **Home/Launchpad:** Add a "Potential Savings" card in the metrics bar or as a grid card
- **Monitoring view:** Add a FinOps tab section in the sub-tabs
- **Workloads view:** Over/under-provisioned resource warnings with cost impact

**Visual pattern:**
```
┌─────────────────────────────────┐
│ 💰 Potential Savings: $1,240/mo │
│ 2 deployments over-provisioned  │
│ 1 PVC underutilized (67% free)  │
│ [View Details →]                 │
└─────────────────────────────────┘
```

## Theme 3: Autonomous Agent Sub-Agent Layer

**Where to show:**
- **Home/Launchpad:** Agent activity cards showing auto-triage actions. "Before you were paged, the SRE agent already..."
- **Agents view:** Activity feed showing autonomous actions vs user-triggered
- **Monitoring view:** AI diagnostics should mention "Background watcher agents have already gathered these logs..."

**Visual pattern:**
```
┌─────────────────────────────────────┐
│ 🤖 Agent Activity                    │
│                                       │
│ ● SRE Agent auto-triaged alert:      │
│   "Memory pressure kube-system"       │
│   → pulled logs, checked recent sync │
│   → placed root-cause summary        │
│   → generated remediation PR (#247)   │
│   2m ago                              │
└─────────────────────────────────────┘
```

## Theme 4: Local-First SRE Workspace / Executable Runbooks

**Where to show:**
- **Notes view:** A notes card with copyable/executable code blocks
- **Operations view:** Runbook viewer with step-by-step instructions
- **Knowledge view:** Markdown documents with "Run in terminal" buttons

**Visual pattern:**
```
┌────────────────────────────────────┐
│ 📖 Runbook: Incident Response       │
│                                      │
│ ## 1. Check node status              │
│ ```bash                              │
│ kubectl get nodes -o wide            │
│ ```                                  │
│ [▶ Run in Terminal] [Copy]           │
│                                      │
│ ## 2. Check pod status               │
│ ```bash                              │
│ kubectl get pods -A --field-selector │
│ ```                                  │
│ [▶ Run in Terminal] [Copy]           │
└────────────────────────────────────┘
```

## Implementation Notes

These strategic elements should be:
1. **Embedded in the HTML mocks** as static but clearly demarked placeholder sections
2. **Wrapped with comments** like `<!-- STRATEGY THEME 1: GitOps PR Card -->` so developers can find and enable them
3. **Visually inactive** elements can use `opacity: 0.5` and a small "Coming Soon" badge

For the Vue app generation, these should be:
- Behind feature flags in a `useFeatureFlags()` composable
- Disabled by default, toggleable with `data-feature="gitops-prs"` attributes
- Wired to `v-if="featureFlags.gitopsPrs"` for easy gradual rollout
