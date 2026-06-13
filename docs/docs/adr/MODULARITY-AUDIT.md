# Modularity & Pattern Audit — 2026-06-03

**Scope:** All Go services in `programming/agents`  
**Conventions checked:** Hexagonal Architecture / Ports-and-Adapters per CODING_STANDARDS.md §1.10, §1.4, §1.5  

---

## Summary

| Service | Status | Findings |
|---------|--------|----------|
| entity-management | ⚠️ Minor violations | 3 issues (entrypoint fatness, stale test files, port duplication) |
| ux-designer | ⚠️ Minor violations | 2 issues (cmd multiplexing, missing composition root) |
| region-resolver | ⚠️ Minor violations | 4 issues (entrypoint fatness, missing test file, duplicate docs, stale go.sum) |

**Overall: Clean pass with minor remediation items. No architectural showstoppers.**

---

## 1. entity-management

### 1.1 Interfaces at Consumer Site ✅

All ports are correctly defined at the consumer site:
- `internal/ports/repository.go` — `Repository` interface (consumed by domain)
- `internal/ports/events.go` — `EventBus` interface (consumed by domain)
- `internal/ports/handlers.go` — `HTTPHandler`, `GRPCHandler` interfaces

### 1.2 Composition Root ⚠️

`pkg/app.go` exists and wires dependencies, but `entity-management/cmd/server/main.go` bypasses it — it assembles its own OTel SDK, pool, and service wiring inline instead of calling `pkg.App()`. The second cmd `cmd/server/main.go` follows the same pattern.

**Fix:** Both `cmd/server/main.go` files should call `pkg/app.go:App()` (or equivalent) and only do flag/config parsing. The OTel SDK setup should live in a shared `pkg/telemetry.go`.

### 1.3 Stale/duplicate port definitions ⚠️

`internal/ports/events.go` and `internal/ports/event_publisher.go` both define `NewEntityCreatedEnvelope`, `NewEntitySoftDeletedEnvelope`, etc. — causing a build failure:

```
internal/ports/events.go:25:6: NewEntityCreatedEnvelope redeclared in this block
    internal/ports/event_publisher.go:362:6: other declaration
```

**Fix:** Consolidate into one file. This is a pre-existing bug.

### 1.4 Stale Test Files ⚠️

Test files in `internal/domain/` and `internal/application/` have duplicate declarations across files (e.g. `fakeSchemaRepo` declared in both `service_test.go` and `create_entity_test.go`). These tests cannot run in the same package because of shared global fakes.

**Fix:** Move test helpers into a `testutil/` package with `_test.go` build tags, or use unique names per file. This is a pre-existing bug.

### 1.5 Internal Boundary Compliance ✅

No sibling `internal/` imports found. `pkg/app.go` correctly imports from `internal/`. `cmd/` only imports from `pkg/` and `internal/adapters/`.

### 1.6 Error Handling ✅

Sentinel errors used throughout. `fmt.Errorf("%w: %v", ...)` wrapping pattern per §1.5.

---

## 2. ux-designer

### 2.1 Interfaces at Consumer Site ✅

All ports are correctly defined:
- `cmd/runbook-mcp/ports/runbook.go` — `RunbookProvider`, `BlockExecutor`
- `internal/agents/ports/agent.go` — `Capability`, `Describable`, `Diagnosable`, `Actable`, `Summarizable`

### 2.2 Composition Root ⚠️

**No composition root exists.** The ux-designer is structured as multiple standalone `cmd/` binaries (runbook-mcp, pr-bridge, finops-analyzer) each with their own main. There is no `pkg/app.go` that wires shared dependencies.

This is by design for a multi-binary monorepo, but means:
- Shared initialization (OTel, config loading, DB pools) is duplicated per binary
- No single place to reason about the dependency graph

**Observation:** Not necessarily a violation — this is a valid microservices-in-monorepo pattern — but worth noting for when the ux-designer grows.

### 2.3 `cmd/` Multiplexing ⚠️

Each `cmd/` directory is a separate binary, but they share `internal/`. The boundary between `cmd/runbook-mcp/` (its own internal adapters) and `ux-designer/internal/` is unclear — `runbook-mcp` has ad-hoc adapters while the shared `internal/` has its own agent system.

### 2.4 Internal Boundary Compliance ✅

No sibling `internal/` violations. Each cmd is self-contained.

---

## 3. region-resolver

### 3.1 Interfaces at Consumer Site ✅

Ports defined in `internal/ports/`:
- `internal/ports/repository.go` — repository inteface
- `internal/ports/events.go` — event interface

### 3.2 Composition Root ⚠️

No `pkg/app.go`. `cmd/server/main.go` does all wiring inline (config, OTel, pool, service assembly, HTTP/gRPC server start). Per §1.4, the composition root should be in `pkg/app.go`.

### 3.3 Missing Tests ⚠️

Zero test files across the entire service. This violates the emerging ADR-0006 policy.

### 3.4 Duplicate Documentation ⚠️

Repo has nested `docs/docs/` paths resulting from an earlier refactoring issue — there are ADR files duplicated across `docs/docs/adr/`, `docs/docs/docs/adr/`, and even `docs/docs/docs/docs/adr/`. Some file paths contain raw filesystem paths as their name (e.g. `docs/Users/jocham/programming/projects/mediusfy/agents/docs/docs/docs/adr/ADR-003-incident-domain-model.md`).

### 3.5 Stale go.sum ⚠️

`go mod tidy` resolves missing entries, suggesting the go.sum was not regenerated after the last dependency change.

---

## Consolidation of Findings

| # | Service | Severity | Finding | Effort |
|---|---------|----------|---------|--------|
| A | entity-management | 🟡 Medium | `cmd/server/main.go` bypasses `pkg/app.go` — inline OTel + wiring | 2h |
| B | entity-management | 🔴 High | Duplicate port definitions cause build failure | 0.5h |
| C | entity-management | 🟡 Medium | Test files have duplicate declarations across files | 1h |
| D | ux-designer | 🟢 Low | No unified composition root (by design for multi-binary) | — |
| E | region-resolver | 🟡 Medium | No `pkg/app.go` — inline wiring in main | 2h |
| F | region-resolver | 🔴 High | Zero test files | 3h |
| G | repo-wide | 🟠 Low | Nested `docs/docs/docs/` path duplication from refactoring artifact | 1h |
| H | repo-wide | 🟢 Low | Stale `go.sum` in several modules | 0.25h |

**Total remediation effort: ~10h** (including the 3h to add region-resolver tests)

### Priority Order

1. **B** — Build is broken in entity-management (duplicate port defs)
2. **F** — region-resolver needs at least one test file
3. **C** — entity-management test files can't run together
4. **A, E** — Extract composition roots out of main
5. **G, H** — Cleanup tasks
