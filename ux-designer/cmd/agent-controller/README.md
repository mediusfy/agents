# Agent Controller

The agent controller is the foundational runtime for Strategy Theme 3: **Autonomous Agent Sub-Agent Layer**. It manages the lifecycle of Kubernetes Agent CRDs, dispatching triggers to the MCP agent runtime.

## Architecture

```
┌──────────────┐     triggers     ┌─────────────────┐
│  Anomstack   │ ──────────────►  │  Agent          │
│  Consumer    │                  │  Controller      │
└──────────────┘                  └────────┬────────┘
       ▲                                   │
       │                                   ▼
       │                           ┌─────────────────┐
       │                           │  MCP Agent       │
       │                           │  Runtime          │
       │                           └─────────────────┘
       │
┌──────┴──────┐
│  Prometheus  │
│  Alertmanager│
└─────────────┘
```

## Quick Start

```bash
# Build
go build -o bin/agent-controller ./cmd/agent-controller/

# Run (dev)
DATABASE_URL="postgres://..." go run ./cmd/agent-controller/
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | — | PostgreSQL connection string |
| `NATS_URL` | `nats://localhost:4222` | NATS connection for event bus |
| `LOG_LEVEL` | `info` | Log level (debug/info/warn/error) |

## Error Handling

All errors are typed sentinels:
- `ErrAgentNotFound`
- `ErrAgentAlreadyRunning`
- `ErrAgentLifecycle`
- `ErrMCPServerUnreachable`

Errors are wrapped with operation context via `AgentError{Op, Name, Err}`.

## Build & Test

```bash
go build ./cmd/agent-controller/
go test -v -race -count=1 ./cmd/agent-controller/... ./internal/agents/...
go vet ./cmd/agent-controller/... ./internal/agents/...
```

## Imports std order

```go
import (
    "context"
    "fmt"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/trace"

    "github.com/drewjocham/agents/ux-designer/internal/agents/ports"
)
```

## Logging

Structured `slog` only — no `log.Print`. Always pass `ctx context.Context` to `slog.InfoContext`.

## Concurrency

Use `errgroup.WithContext` for parallel agent dispatch. All state mutations under `sync.Mutex`.

## Testing

Table-driven tests with `github.com/stretchr/testify/assert`. Use `slog.DiscardHandler` in test logger.
