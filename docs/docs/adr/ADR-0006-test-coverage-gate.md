# ADR-0006: Minimum Test Coverage Gate & Pre-Merge Quality Policy (R1)

**Status:** Accepted  
**Date:** 2026-06-03  
**Author:** Buddy (Backend Engineer)  
**PR:** TBD  

## Context

The code review audit (2026-06-03) identified that the agent ecosystem lacks a standardized test coverage policy. Individual services have varying levels of test coverage:

| Service | Unit tests | Integration tests | Coverage enforced |
|---------|-----------|------------------|-------------------|
| entity-management | 24 test files | Yes (Postgres+NATS) | No minimum |
| ux-designer | 2 test files (backfill) | None | No minimum |
| region-resolver | 0 test files | None | No minimum |

Without a policy, new packages can be added without tests, and existing coverage can regress. The ADR-0006 R1 introduces a lightweight coverage gate that grows stricter over time.

**Key trade-offs considered:**
- Too strict → blocks legitimate changes / encourages coverage gaming
- Too loose → meaningless check
- Package-level vs aggregate → package-level better for pinpointing gaps

## Decision

### 1. Coverage Gate (GitHub Actions)

Each Go service's CI workflow **SHOULD** include a coverage check step after unit tests:

```yaml
- name: Check minimum package coverage
  run: |
    go tool cover -func=coverage.out | grep -v "^total:" | while IFS= read -r line; do
      pkg=$(echo "$line" | awk '{print $1}')
      cov=$(echo "$line" | awk '{print $NF}' | tr -d '%')
      if [ "${cov%.*}" -lt 30 ] 2>/dev/null; then
        echo "❌ $pkg — ${cov}% coverage (min 30%)"
        exit 1
      fi
    done
    echo "✅ All packages meet minimum coverage (30%)"
  working-directory: ${{ env.SERVICE_DIR }}
```

For **new packages** (first PR), the check is informational only — it logs warnings but does not fail. This allows starting with low coverage and ramping up.

### 2. Coverage Thresholds

| Phase | Effective | Threshold | Scope |
|-------|-----------|-----------|-------|
| R1 | Immediate | 30% per package | Advisory for new packages, blocking for existing |
| R2 | Q3 2026 | 50% per package | Blocking for all packages |
| R3 | Q1 2027 | 60% per package | Blocking for all packages, excludes tests/ and mocks/ |

Packages at 0% coverage (no test file at all) trigger a warning regardless of phase.

Bypass mechanism: commit message `[skip-test-check]` allows temporary bypass for emergency fixes or refactoring churn.

### 3. New Services / New Packages

When a new Go service or significant new package is introduced:

1. At least one test file must exist in the first PR (even if only a stub `package_test.go`)
2. The PR description must call out the coverage plan for the new package
3. A follow-up issue must exist to reach 30% coverage within 2 weeks

### 4. Policy Exceptions

Explicitly excluded from coverage requirements:
- `cmd/` — entrypoints only (flag parsing, config loading, app.Run)
- `mocks/` — generated mock code
- `internal/adapters/handlers/` — thin handlers only if delegating entirely to service layer (requires annotation in handler file)

### 5. CODING_STANDARDS.md Update

Add §2.4 to the Testing Standards section:

```markdown
### 2.4 Coverage Gate

**Minimum coverage: 30% per package (R1), rising to 60% (R3).**

- Enforced in CI via `go tool cover -func=coverage.out` check.
- Skippable with `[skip-test-check]` in commit message.
- New packages must include at least one test file in the introducing PR.
- See ADR-0006 for full policy and phase roadmap.
```

### 6. Implementation Plan (R1)

| Step | Owner | Done |
|------|-------|------|
| Add coverage step to `entity-management-ci.yml` | Backend Engineer | |
| Add coverage step to `ux-designer-ci.yml` (once created) | Backend Engineer | |
| Add coverage step to any future service CI | Per-service PR | |
| Update `CODING_STANDARDS.md` §2 with coverage gate | Backend Engineer | |
| Add first test file to `region-resolver/` | Backend Engineer | |
| Close associated issue | Backend Engineer | |

## Consequences

**Positive:**
- Prevents new packages entering the repo without any test coverage
- Creates a clear, ratcheting target across services
- Lightweight enough to not block development velocity
- CI step is ~5 seconds per run (negligible cost)

**Negative:**
- 30% is a low bar — a single happy-path test can satisfy it
- Package-level checking is vulnerable to tiny packages (~50 lines) where 30% is meaningless
- May incentivize trivial test additions (coverage gaming)

**Mitigations:**
- R2/R3 thresholds raise the bar over time
- Code review should catch trivial tests regardless
- The advisory mode for new packages reduces friction early

## Rationale

30% was chosen as the R1 threshold because:
- It catches the worst offenders (0% coverage packages)
- It's achievable for any non-trivial package with a single file of tests
- It doesn't block legitimate small changes

The phased approach mirrors industry best practices (Google's Testing on the Toilet, ThoughtWorks' coverage recommendations) without imposing a one-size-fits-all threshold.
