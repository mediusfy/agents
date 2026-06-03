# Anomstack Consumer

The Anomstack consumer implements event-driven autonomous agent triage (Strategy Theme 3). It receives anomaly alerts, deduplicates them, and dispatches commands to the agent controller.

## Architecture

```
┌──────────────┐  webhook/NATS    ┌──────────────┐  dispatch cmd   ┌──────────────┐
│  Anomstack   │ ──────────────►  │  Consumer     │ ──────────────►  │  Agent       │
│  (anomaly)   │                  │  (Go service) │                  │  Controller   │
└──────────────┘                  └──────┬───────┘                  └──────────────┘
                                         │
                                   ┌─────▼──────┐
                                   │  OTEL spans │
                                   └────────────┘
```

## Quick Start

```bash
# Build
go build -o bin/anomstack-consumer ./internal/adapters/anomstack/
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `WEBHOOK_PORT` | `8083` | HTTP webhook listener port |
| `NATS_URL` | `nats://localhost:4222` | NATS connection |
| `DEDUP_WINDOW` | `5m` | Alert deduplication window |
| `LOG_LEVEL` | `info` | Log level |

## Error Handling

- `ErrAlertAlreadyProcessing` — deduplicated duplicate alert
- `ErrConsumerClosed` — consumer has been shut down

## Build & Test

```bash
go build ./internal/adapters/anomstack/
go test -v -race -count=1 ./internal/adapters/anomstack/...
```
