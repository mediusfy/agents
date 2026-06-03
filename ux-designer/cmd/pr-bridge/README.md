# PR Bridge

The PR bridge implements Strategy Theme 1: **GitOps-Native Remediation**. It converts AI-generated YAML patches into GitHub PRs.

## Architecture

```
┌──────────────┐    PR Request     ┌──────────────┐    API calls     ┌─────────┐
│  FinOps      │ ───────────────►  │  PR Bridge    │ ──────────────►  │  GitHub  │
│  Analyzer    │                   │  (Go server)  │                  │  API     │
└──────────────┘                   └──────┬───────┘                  └─────────┘
                                          │
                                    ┌─────▼──────┐
                                    │  OTEL spans │
                                    └────────────┘
```

## Quick Start

```bash
# Build
go build -o bin/pr-bridge ./cmd/pr-bridge/

# Run
GITHUB_TOKEN="ghp_..." go run ./cmd/pr-bridge/
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GITHUB_TOKEN` | — | GitHub personal access token (with repo scope) |
| `GITHUB_BASE_URL` | `https://api.github.com` | GitHub API base URL |
| `PORT` | `8080` | HTTP server port |
| `LOG_LEVEL` | `info` | Log level

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v1/prs` | Create a PR (idempotent) |
| GET | `/api/v1/prs/:repo/:number` | Get PR status |
| GET | `/healthz` | Health check |
| GET | `/readyz` | Readiness check |

## Error Handling

Typed sentinels:
- `ErrPRCreationFailed`
- `ErrBranchExists`
- `ErrNoChanges`
- `ErrGitHubAuth`

## Security

- Token via `GITHUB_TOKEN` env var — no hardcoded secrets
- Base URL pinned to `api.github.com`
- Rate limited via token bucket (10 req/s)
- Non-root container (UID 10001)

## Build & Test

```bash
go build ./cmd/pr-bridge/
go test -v -race -count=1 ./cmd/pr-bridge/...
```
