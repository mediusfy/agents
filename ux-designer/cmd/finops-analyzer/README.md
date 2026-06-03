# FinOps Analyzer

The FinOps analyzer implements Strategy Theme 2: **Automated FinOps ROI**. It periodically scans Prometheus metrics, detects resource waste, computes monthly savings, and generates PRs for remediation.

## Architecture

```
┌──────────────┐  PromQL query    ┌──────────────┐  PR request     ┌──────────────┐
│  Prometheus  │ ◄──────────────  │  FinOps       │ ──────────────►  │  PR Bridge    │
│              │                  │  Analyzer     │                  │              │
└──────────────┘                  └──────┬───────┘                  └──────────────┘
                                         │
                                         ▼
                                  ┌──────────────┐
                                  │  PostgreSQL   │
                                  │  (waste_obs)  │
                                  └──────────────┘
```

## Quick Start

```bash
# Build
go build -o bin/finops-analyzer ./cmd/finops-analyzer/

# Run
DATABASE_URL="postgres://..." \
  PROMETHEUS_URL="http://prometheus:9090" \
  PR_BRIDGE_URL="http://pr-bridge:8082" \
  go run ./cmd/finops-analyzer/
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | — | PostgreSQL connection string |
| `PROMETHEUS_URL` | — | Prometheus server URL |
| `PR_BRIDGE_URL` | — | PR bridge service URL |
| `SCAN_INTERVAL` | `30m` | Periodic scan interval |
| `PORT` | `8085` | HTTP server port |
| `LOG_LEVEL` | `info` | Log level |
| `COST_PER_CPU_HOUR` | `0.10` | $/hour per CPU core |
| `COST_PER_GB_MEM` | `0.05` | $/hour per GB memory |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/v1/waste` | List waste observations (filterable) |
| GET | `/api/v1/waste/top` | Top-N by monthly waste |
| POST | `/api/v1/waste/:id/recommend` | Generate remediation PR |
| PATCH | `/api/v1/waste/:id/dismiss` | Dismiss observation |
| GET | `/healthz` | Health check |
| GET | `/readyz` | Readiness check |

## Database Schema

See `migrations/001_waste_observations.sql` and `migrations/002_cost_saving_actions.sql`.

## Error Handling

- `ErrNoMetricsAvailable` — Prometheus returned no data for workload
- `ErrAlreadyActioned` — observation already has a PR
- `ErrRecommendationFailed` — PR generation failed

## Build & Test

```bash
go build ./cmd/finops-analyzer/
go test -v -race -count=1 ./cmd/finops-analyzer/...
```
