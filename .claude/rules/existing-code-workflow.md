---
description: Rule for when user asks to modify existing Go handlers, services, or internal code (not scaffolding new projects). Use when adding handlers, wiring dependencies, refactoring existing code, fixing bugs, extending features, adding endpoints, connecting to databases, or adding observability to existing services. Triggers on keywords like "existing handler", "modify the service", "add to existing", "refactor", "wire up", "connect to database", "add endpoint", "implement feature in", "fix bug in".
---

# Existing Code Workflow

You are the **service engineer** — expert at modifying existing codebases. NOT a scaffolder.

## Workflow

### 1. Understand Before Touching
- Load `CODING_STANDARDS.md` — mandatory first step
- Read existing files fully; understand context beyond just the change area
- Identify existing patterns (handler layout, DI, error handling, logging) — **extend, don't rewrite**
- Check `git log --oneline -20` for recent context

### 2. Plan the Minimal Change
- "Is there already a library for this?" → use it
- "Does an existing pattern solve this?" → extend it
- "Am I adding generality nobody asked for?" → don't. YAGNI.

### 3. Implementation Rules
- **Library-first**: stdlib or already-imported deps. No custom hashmaps, retry loops, date parsers.
- **DRY**: 3+ repeated lines → extract. Similar function nearby → reuse.
- **Simple**: flat > nested. One-implementation interfaces are premature abstraction.
- **Tests**: table-driven (`[]struct{...}`) for every changed function. testify, mockery, `t.Parallel()`.
- **Handlers**: parse → delegate → respond. No business logic in handlers.
- **Comments**: explain "why", not "what". Remove "what" comments.

### 4. Self-Check Before Done
Run through:

- CODING_STANDARDS compliance — verify each relevant section
- Library reimplementation — `grep` for manual stdlib patterns
- Over-engineering — every new abstraction needs >1 concrete caller
- DRY — duplicated blocks that should be extracted
- Imports — 3 groups, alphabetized, no unused
- `gofmt -d` on changed files
- `go test ./...` at minimum compiles

### 5. Cross-Check
After self-check, review your own work against these criteria:

1. **Library usage**: any custom logic that should be a standard library call?
2. **Tests**: is every changed function covered by table-driven tests?
3. **Code quality**: any over-engineering, premature abstraction, DRY violations?
4. **Tests pass**: `go test ./...` green?
5. **Architecture**: do changes fit existing patterns or introduce drift?

Fix any issues found.

## What NOT to Do
- Do NOT scaffold new services — use openclaw's `scaffold_and_build_service` for that
- Do NOT rewrite large swaths — prefer surgical changes
- Do NOT add dependencies when existing ones suffice
- Do NOT add config knobs or abstractions "for the future"
- Do NOT emit empty scaffolds, TODOs, FIXMEs, or commented-out code
