---
description: Rule activated when reviewing any code change. Runs after implementation is complete. Checks for over-engineering, DRY violations, library misuse, CODING_STANDARDS compliance, and pattern drift. Triggers on "review this code", "check for issues", "audit", "inspect", "quality check".
---

# Code Inspection Checklist

The second set of eyes. Run every applicable check on the changed files.

## Over-Engineering Detection
- Functions >50 lines? Deep nesting >4 levels?
- Interfaces with exactly 1 implementation? If so, inline it.
- Generics where concrete types or `any` suffice?
- Plugin/visitor/strategy patterns for only 2 cases? A conditional is enough.
- Config knobs nobody asked for? Unexported optional fields with no caller.

## DRY Violations
- Same `fmt.Errorf` format string repeated?
- Same nil-check, bounds-check, field-validation in multiple places?
- Same `slog.String(...)` or `attribute.String(...)` call chains repeated?
- Same route registration pattern copy-pasted?

## Library Usage / Reinventing Wheels
- Custom retry loop with `time.Sleep`? Use `backoff` or `tenacity`.
- Custom hash/map logic? Stdlib has `maps`, `slices`, `sort`.
- Manual JSON string building? Use `encoding/json`.
- Custom date parsing? Use `time` package.
- Custom auth/validation? Use existing middleware.

## CODING_STANDARDS Compliance
Cross-reference against:
- **§1.2**: 3 import groups, alphabetized
- **§1.3**: No `interface{}`, correct naming conventions
- **§1.5**: Typed sentinel errors, not raw strings
- **§1.6**: `slog` only, no `log`/`fmt.Print` for logging
- **§1.7**: OTEL spans on significant operations
- **§1.8**: Table-driven tests, `t.Parallel()`, testify assertions
- **§1.10**: Constructor DI, no `init()` side effects, no global state
- **§1.11**: Handlers are thin, business logic in service layer
- **§1.12**: "Why" comments, not "what" comments

## Pattern Drift
Compare against similar existing code in the same package:
- Same error handling approach?
- Same logging style?
- Same DI pattern?
- Same test structure?

If existing code uses approach X and new code introduces Y for the same concern, flag as drift unless documented.

## Output
For each finding: `file:line`, `category` (over-engineering / dry / library / standards / drift), `section` (CODING_STANDARDS.md §), `evidence`, `severity` (blocking / nice-to-have).
