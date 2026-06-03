# Runbook MCP

Runbook MCP implements Strategy Theme 4: **Executable Runbooks**. It parses Markdown runbooks, identifies executable code blocks, and executes them in a sandboxed environment.

## Architecture

```
┌──────────────┐   list, get, exec  ┌──────────────┐    shell cmd    ┌─────────┐
│  Frontend    │ ───────────────►  │  Runbook MCP  │ ──────────────►  │  Shell   │
│  (Vue)       │                   │  (Go server)  │                  │  (pty)   │
└──────────────┘                   └──────┬───────┘                  └─────────┘
                                          │
                                    ┌─────▼──────┐
                                    │  OTEL spans │
                                    └────────────┘
```

## Quick Start

```bash
# Build
go build -o bin/runbook-mcp ./cmd/runbook-mcp/

# Run
RUNBOOK_DIR="./runbooks" go run ./cmd/runbook-mcp/
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `RUNBOOK_DIR` | `./runbooks` | Directory containing .md runbooks |
| `PORT` | `8080` | HTTP server port |
| `LOG_LEVEL` | `info` | Log level |
| `SAFE_MODE` | `true` | Enable command allowlist |

## MCP Tools

| Tool | Description |
|------|-------------|
| `runbook.list` | List available runbooks |
| `runbook.get_block` | Get block content with metadata |
| `runbook.execute` | Execute a code block, return output |

## Runbook Format

```markdown
# Title

Some description text.

```sh
kubectl get pods -n my-namespace
```

```sh {"description":"Check pod status","expected_output_pattern":"Running"}
kubectl get pods -n my-namespace -o wide
```

## Note

The executor uses a **command allowlist** for safety (kubectl, helm, curl, etc.).
Only explicitly allowed commands can be executed. This is controlled by `SAFE_MODE`.

## Error Handling

- `ErrRunbookNotFound` — runbook path doesn't exist
- `ErrBlockNotFound` — block ID not in runbook
- `ErrExecutionFailed` — shell command returned non-zero
- `ErrValidationFailed` — output didn't match expected pattern

## Build & Test

```bash
go build ./cmd/runbook-mcp/
go test -v -race -count=1 ./cmd/runbook-mcp/...
```
