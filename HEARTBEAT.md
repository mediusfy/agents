# HEARTBEAT.md

## Scheduled Tasks

The agent checks these periodically during heartbeat polls. Add or remove items as needed.

### Daily (rotate through, 2-4x per day)

- [ ] **Memory consolidation** — review recent `memory/YYYY-MM-DD.md` files, distill key learnings into MEMORY.md
- [ ] **Git status check** — review uncommitted changes, stale branches, PR status
- [ ] **Agent file sync** — verify `shared/agents/` is in sync with consumer directories (hermes, openclaw, claude, antigravity)

### Weekly

- [ ] **MEMORY.md review** — prune outdated info, update conventions
- [ ] **Dependency check** — review outdated Go modules and Python packages
- [ ] **Test coverage** — review test run results, identify gaps

### Ad-hoc (when relevant)

- [ ] **Calendar check** — upcoming events in next 24-48h
- [ ] **Email check** — urgent unread messages

## Quiet Hours

Skip non-urgent checks between 23:00-08:00 CEST.

## State Tracking

See `memory/heartbeat-state.json` for last-check timestamps.
