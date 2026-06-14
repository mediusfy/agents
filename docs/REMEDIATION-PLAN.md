# Remediation Plan — Code Review Findings

> **Context:** Audit of planned agent ecosystem additions identified structural gaps, production mock code, ineffective testing, and missing interfaces. This plan addresses each finding across four domains.

---

## Overview

| # | Domain | Finding | Priority | Effort | Area |
|---|--------|---------|----------|--------|------|
| 1 | `kube/backend/pkg/executor` | Mock SSA in production code | 🔴 Critical | M | Backend |
| 2 | `kube/backend/pkg/markdown` | Stub interfaces (ExtractTooltips, ExtractActions) | 🟡 Medium | M | Backend |
| 3 | `kube/backend/pkg/markdown` | Missing parser tests | 🟠 High | S | Testing |
| 4 | `kube/backend/pkg/executor` | Missing executor tests | 🟠 High | M | Testing |
| 5 | `agent/` (Python sandbox) | Ineffective sandbox testing | 🟠 High | M | Python |
| 6 | `kube/view/src/components/*` | Missing frontend component tests | 🟡 Medium | L | Frontend |
| 7 | `agent/` | ADR-0006 R1 test policy enforcement | 🟡 Medium | M | Process |
| 8 | `agent/` | Package/modularity audit pass | 🟢 Low | S | Quality |

---

## Detailed Work Items

### 1. 🔴 Real SSA Implementation — `executor.go`

**File:** `kube/backend/pkg/executor/executor.go`

**Problem:** `applySSAPatch` returns a successful formatted string without actually calling the Kubernetes API.

**Fix:**
- Replace the stub with a real `k8s.io/client-go/dynamic` call.
- Construct `rest.ImpersonationConfig` from the provided `userID`.
- Apply the patch via `Patch` with types.ApplyPatchType and `metav1.PatchOptions{FieldManager: "argus-executor"}`.
- Handle errors (forbidden, conflict, not found) and map them to structured error responses.
- Wrap with tracing span and metric recording.

**Acceptance criteria:**
- `applySSAPatch` makes a real Kubernetes API call with impersonation
- RBAC errors surface as structured error types, not silent success
- All existing test mocks continue to work

---

### 2. 🟡 Markdown AST Traversal — `parser.go`

**File:** `kube/backend/pkg/markdown/parser.go`

**Problem:** `ExtractTooltips()` and `ExtractActions()` are stubs returning empty arrays.

**Fix:**
- Implement AST traversal using the Goldmark `ast.Visitor` pattern.
- `ExtractTooltips`: walk paragraph and list nodes for `data-tooltip` attributes or `{: .tooltip}` markers.
- `ExtractActions`: walk fenced code blocks with `action:` or `command:` annotations.
- Return typed slices of `Tooltip` / `Action` structs (define these in the same package).
- Add error wrapping and edge-case handling (malformed content, deeply nested nodes).

**Acceptance criteria:**
- `ExtractTooltips` returns tooltip entries from correctly annotated markdown
- `ExtractActions` returns action entries from fenced code blocks
- Empty/non-annotated content returns empty slices (not nil)
- Covered by unit tests (see item 3)

---

### 3. 🟠 Backend Unit Tests — `parser_test.go`

**File:** `kube/backend/pkg/markdown/parser_test.go` (new)

**What to cover:**
- `ParseFile` — well-formed, malformed, empty, missing frontmatter
- `ListRunbooks` — directory with mixed files, empty directory, non-existent path
- `GetBlock` — valid block ID, invalid block ID, missing runbook
- `ExtractTooltips` — annotated marks, unannotated marks, mixed content
- `ExtractActions` — action blocks, non-action fenced blocks, edge cases
- Error paths: file not found, permission denied, unreadable content

**Style:** Table-driven, `t.Parallel()`, testify assertions, in-memory test fixtures.

---

### 4. 🟠 Backend Unit Tests — `executor_test.go`

**File:** `kube/backend/pkg/executor/executor_test.go` (new)

**What to cover:**
- `Execute` — shell blocks (stdout, stderr, exit codes)
- `Execute` — kubectl commands (shell wrapping)
- `Execute` — unsupported languages
- `Execute` — empty content
- `Execute` — timeout behavior
- `Validate` — matching pattern, non-matching pattern, empty pattern, exit code logic
- Error paths: context cancelled, command not found, execution timeout

**Style:** Table-driven, `t.Parallel()`, testify assertions.

---

### 5. 🟠 Python Sandbox Fix — `mentor_agent.py`

**File:** `agent/python_agents/src/rufkis_agents/mentor_agent.py`

**Problem:** Sandbox uses `alpine:latest` (no `make`, no toolchain) and `echo` instead of real validation.

**Fix:**
- Switch base image to `golang:1.25-alpine` (or a custom CI image with Go + Node toolchain).
- Mount the target manifest directory via a ConfigMap or `subPath` volume.
- Execute `make lint && make test` for real, capturing stdout/stderr.
- Validate the exit code and surface meaningful failure messages.
- Add a `run_sandbox_timeout` config to prevent runaway CI builds.

**Acceptance criteria:**
- Sandbox pod runs `make lint` and `make test` with the real toolchain
- Non-zero exit codes report specific failure details back to the agent
- Timeout kills the sandbox and reports partial output

---

### 6. 🟡 Frontend Component Tests

**Files:** New `.spec.ts` or `.test.ts` files under `kube/view/src/components/`

**Components requiring tests:**
- `TopologyGraph.vue` — render states, data binding, resize handling
- `GpuTopologyView.vue` — hardware topology display, empty/loading/error states
- `FinOpsWastePanel.vue` — cost data rendering, waste calculation UI
- `PrActionCard.vue` — action card rendering, click handlers, variant states
- `TerminalDrawer.vue` — open/close behavior, resize, content rendering

**Approach:** Vue Test Utils + Vitest. Snapshot tests for structural regression + behavior tests for interactive components.

---

### 7. 🟡 Test Policy Enforcement (ADR-0006 R1)

**Process change:** Add a pre-merge check that enforces test coverage for new/changed packages.

**Implement:**
- Add a GitHub Actions workflow step: `go test -coverprofile=coverage.out ./...` with a minimum threshold check.
- For new packages with no test files, fail the check (can be bypassed with explicit `[skip-test-check]` in commit message for migrations/docs).
- Document in `CODING_STANDARDS.md` §2 (Testing Standards): add policy section.

---

### 8. 🟢 Modularity & Pattern Audit Pass

**Scope:** Review the complete branch diff against Hexagonal Architecture / Ports-and-Adapters conventions.

**Check:**
- Are all dependencies defined as interfaces at the consumer site? (per CODING_STANDARDS §1.10)
- Does `pkg/app.go` correctly wire up the composition root?
- Are `internal/` boundaries respected — no imports from sibling `internal/` packages, only from `pkg/`?
- Do `cmd/` entrypoints do nothing but parse flags, build config, and call `app.Run()`?

**Output:** A short audit report with any violations (or a clean pass).

---

## Dependency Graph

```
ES 1 ──> executor_test.go (item 4)
│
ES 2 ──> parser_test.go (item 3)
│
├── item 3 ──> item 7 (coverage enforcement catches this)
│
ES 5     independent
│
item 6  independent
│
item 7  ──> CODING_STANDARDS.md update
│
item 8  independent (can run last)
```

**Recommended execution order:** 1 → 4 → 2 → 3 → 5 → 6 → 7 → 8

This puts the critical fix first, backfills tests immediately after the fix, then cascades into the remaining concerns.

---

## Estimated Effort Summary

| Domain | Items | Est. (dev-hours) |
|--------|-------|-----------------|
| Backend Go | 1, 2, 3, 4 | 12–16 |
| Python/Sandbox | 5 | 4–6 |
| Frontend Vue | 6 | 6–8 |
| Process/Policy | 7 | 2–3 |
| Quality Audit | 8 | 1–2 |
| **Total** | **8** | **25–35** |
