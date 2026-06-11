# =============================================================================
# Entity Management - Makefile
# =============================================================================
# Supports all 12 ENTITYMGMT stories:
#   - Build, test, lint, docker, db migration, observability
#   - Multi-region, idempotency, outbox, soft/hard delete, restore, pagination
# =============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

# ---------------------------------------------------------------------------
# Project metadata
# ---------------------------------------------------------------------------
SERVICE_NAME    := entity-management
GO_MODULE       := $(SERVICE_NAME)
BINARY_NAME     := $(SERVICE_NAME)
BINARY_PATH     := bin/$(BINARY_NAME)
MAIN_PACKAGE    := ./cmd/server
GO_BUILD_FLAGS  := -ldflags="-s -w -X main.Version=$(VERSION) -X main.Commit=$(GIT_COMMIT) -X main.Date=$(BUILD_DATE)"
GO_TEST_FLAGS   := -v -race -count=1 -coverprofile=coverage.out -covermode=atomic

# ---------------------------------------------------------------------------
# Versioning (ENTITYMGMT-12: Build metadata for OTel)
# ---------------------------------------------------------------------------
VERSION     ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
GIT_COMMIT  := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE  := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

# ---------------------------------------------------------------------------
# Docker images
# ---------------------------------------------------------------------------
DOCKER_REGISTRY     ?= ghcr.io
DOCKER_ORG          ?= $(shell echo "$${GITHUB_REPOSITORY_OWNER:-local}")
IMAGE_NAME           = $(DOCKER_REGISTRY)/$(DOCKER_ORG)/$(SERVICE_NAME)
IMAGE_TAG           ?= $(VERSION)
FULL_IMAGE           = $(IMAGE_NAME):$(IMAGE_TAG)

# ---------------------------------------------------------------------------
# Docker Compose profiles
# ---------------------------------------------------------------------------
COMPOSE_PROFILES := 
ifeq ($(ENABLE_OTEL), true)
    COMPOSE_PROFILES := --profile otel
endif

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
ifneq (,$(wildcard .env))
    include .env
    export
endif

# Detect OS
OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

# ===========================================================================
# Development
# ===========================================================================

.PHONY: all
all: clean deps lint test build ## Run full pipeline: clean → deps → lint → test → build

.PHONY: deps
deps: ## Download and verify Go module dependencies
	go mod tidy
	go mod verify
	go mod download

.PHONY: build
build: ## Build the service binary
	@echo ">>> Building $(BINARY_NAME) v$(VERSION) (commit: $(GIT_COMMIT))..."
	CGO_ENABLED=0 go build $(GO_BUILD_FLAGS) -o $(BINARY_PATH) $(MAIN_PACKAGE)
	@echo ">>> Built: $(BINARY_PATH)"
	@echo "    Version: $(VERSION)"
	@echo "    Commit:  $(GIT_COMMIT)"

.PHONY: build-linux
build-linux: ## Build Linux binary (for Docker)
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build $(GO_BUILD_FLAGS) -o $(BINARY_PATH)-linux $(MAIN_PACKAGE)

.PHONY: clean
clean: ## Clean all build artifacts, caches, and temp files
	@echo ">>> Cleaning..."
	rm -rf bin/ coverage.out coverage.html profile.out
	go clean -testcache -cache -modcache
	@echo ">>> Clean complete"

.PHONY: run
run: ## Run the service locally (requires postgres + nats running)
	@echo ">>> Starting $(SERVICE_NAME) locally..."
	go run $(MAIN_PACKAGE)

# ===========================================================================
# Testing (ENTITYMGMT-01 through ENTITYMGMT-12)
# ===========================================================================

.PHONY: test
test: ## Run all tests with race detection and coverage
	@echo ">>> Running all tests..."
	go test $(GO_TEST_FLAGS) ./...
	@echo ">>> All tests passed"

.PHONY: test-race
test-race: ## Run tests with extended race detection
	go test -race -count=1 -timeout 120s ./...

.PHONY: test-short
test-short: ## Run short tests only (no integration)
	go test -short -count=1 ./...

.PHONY: test-integration
test-integration: ## Run integration tests (requires postgres + nats)
	go test -tags=integration -count=1 -timeout 180s ./internal/adapters/...

.PHONY: test-coverage
test-coverage: test ## Run tests and generate coverage reports
	go tool cover -html=coverage.out -o coverage.html
	go tool cover -func=coverage.out | grep total
	@echo ">>> Coverage report: coverage.html"

.PHONY: test-watch
test-watch: ## Run tests in watch mode (requires gow)
	@command -v gow >/dev/null 2>&1 || { echo "Install gow: go install github.com/mitranim/gow@latest"; exit 1; }
	gow test -v -race ./...

# ===========================================================================
# Linting & Quality (ENTITYMGHT-12: Code quality gates)
# ===========================================================================

.PHONY: lint
lint: lint-go lint-vuln ## Run all linters

.PHONY: lint-go
lint-go: ## Run golangci-lint
	@echo ">>> Running golangci-lint..."
	golangci-lint run --timeout=5m --out-format=colored-line-number
	@echo ">>> Lint passed"

.PHONY: lint-vuln
lint-vuln: ## Run govulncheck for vulnerability scanning
	@echo ">>> Running govulncheck..."
	@command -v govulncheck >/dev/null 2>&1 || go install golang.org/x/vuln/cmd/govulncheck@latest
	govulncheck ./...
	@echo ">>> Vulnerability check passed"

.PHONY: fmt
fmt: ## Format Go code
	go fmt ./...

.PHONY: vet
vet: ## Run go vet
	go vet ./...

# ===========================================================================
# Docker (ENTITYMGMT-11: Multi-region container builds)
# ===========================================================================

.PHONY: docker-build
docker-build: ## Build the Docker image
	@echo ">>> Building Docker image: $(FULL_IMAGE)"
	DOCKER_BUILDKIT=1 docker build \
		--cache-from $(IMAGE_NAME):cache \
		--tag $(FULL_IMAGE) \
		--tag $(IMAGE_NAME):latest \
		--build-arg BUILDKIT_INLINE_CACHE=1 \
		--build-arg VERSION=$(VERSION) \
		--build-arg GIT_COMMIT=$(GIT_COMMIT) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		-f Dockerfile .
	@echo ">>> Built: $(FULL_IMAGE)"

.PHONY: docker-push
docker-push: docker-build ## Build and push Docker image to registry
	docker push $(FULL_IMAGE)
	docker push $(IMAGE_NAME):latest

.PHONY: docker-scan
docker-scan: ## Scan the Docker image for vulnerabilities (requires trivy)
	@command -v trivy >/dev/null 2>&1 || { echo "Install trivy: https://trivy.dev"; exit 1; }
	trivy image --severity HIGH,CRITICAL $(FULL_IMAGE)

# ===========================================================================
# Docker Compose Orchestration (ENTITYMGMT-12: Local dev environment)
# ===========================================================================

.PHONY: up
up: ## Start all services (postgres + nats + redis + app)
	@echo ">>> Starting all services..."
	docker compose $(COMPOSE_PROFILES) up -d --build
	@echo ">>> Services started"
	@echo "    API:       http://localhost:$(HTTP_PORT:8080)"
	@echo "    Postgres:  localhost:$(DB_PORT:5432)"
	@echo "    NATS:      localhost:$(NATS_PORT:4222)"
	@echo "    NATS Mon:  http://localhost:$(NATS_HTTP_PORT:8222)"
	@echo "    Redis:     localhost:$(REDIS_PORT:6379)"

.PHONY: down
down: ## Stop all services
	docker compose $(COMPOSE_PROFILES) down -v
	@echo ">>> Services stopped"

.PHONY: up-deps
up-deps: ## Start only dependencies (postgres + nats + redis), no app
	docker compose up -d postgres nats redis
	@echo ">>> Dependencies started"

.PHONY: logs
logs: ## Tail logs from all services
	docker compose logs -f

.PHONY: ps
ps: ## Show running services
	docker compose ps

.PHONY: restart
restart: ## Restart the app service
	docker compose restart entity-management

.PHONY: reset
reset: down ## Full reset: stop all services, remove volumes, rebuild
	docker compose $(COMPOSE_PROFILES) down -v --rmi local
	@echo ">>> Full reset complete. Run 'make up' to rebuild."

# ===========================================================================
# Database (ENTITYMGMT-01: Schema migrations, ENTITYMGMT-02: Idempotency)
# ===========================================================================

.PHONY: db-migrate
db-migrate: ## Run database migrations
	@echo ">>> Running migrations..."
	@for f in database/migrations/*.up.sql; do \
		echo "    Applying: $$(basename $$f)"; \
		psql "$${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/entity_management?sslmode=disable}" -f "$$f" > /dev/null 2>&1; \
	done
	@echo ">>> Migrations complete"

.PHONY: db-rollback
db-rollback: ## Run database rollbacks (all down migrations)
	@echo ">>> Rolling back migrations..."
	@for f in $$(ls database/migrations/*.down.sql | sort -r); do \
		echo "    Rolling back: $$(basename $$f)"; \
		psql "$${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/entity_management?sslmode=disable}" -f "$$f" > /dev/null 2>&1; \
	done
	@echo ">>> Rollback complete"

.PHONY: db-reset
db-reset: db-rollback db-migrate ## Reset and re-run all migrations

.PHONY: db-shell
db-shell: ## Open an interactive psql shell
	psql "$${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/entity_management?sslmode=disable}"

.PHONY: db-create
db-create: ## Create the database
	createdb -U postgres entity_management 2>/dev/null || true

# ===========================================================================
# Code Generation
# ===========================================================================

.PHONY: generate
generate: ## Run all code generators (protobuf, mocks, etc.)
	go generate ./...
	@echo ">>> Code generation complete"

# ===========================================================================
# Observability (ENTITYMGMT-12: OTel, tracing, metrics)
# ===========================================================================

.PHONY: otel-up
otel-up: ## Start OTel collector alongside services
	ENABLE_OTEL=true docker compose --profile otel up -d

.PHONY: otel-down
otel-down: ## Stop OTel collector
	ENABLE_OTEL=true docker compose --profile otel down

.PHONY: trace
trace: ## Export a trace to view traces (requires otel-collector running)
	@echo ">>> Sending test trace..."
	curl -X POST http://localhost:4318/v1/traces \
		-H "Content-Type: application/json" \
		-d '{"resourceSpans":[{"resource":{"attributes":[]},"scopeSpans":[{"scope":{"name":"test"},"spans":[{"traceId":"00000000000000000000000000000001","spanId":"0000000000000001","parentSpanId":"","name":"test-span","kind":1,"startTimeUnixNano":'"$$(date +%s%N)"',"endTimeUnixNano":'"$$(date +%s%N)"',"attributes":[]}]}]}]}'
	@echo ">>> Trace sent"

# ===========================================================================
# Security (ENTITYMGMT-04: Optimistic concurrency, input validation)
# ===========================================================================

.PHONY: security-audit
security-audit: lint-vuln ## Run security audit
	@echo ">>> Running gosec..."
	@command -v gosec >/dev/null 2>&1 || go install github.com/securego/gosec/v2/cmd/gosec@latest
	gosec -quiet -confidence=high -severity=medium ./...
	@echo ">>> Security audit complete"

# ===========================================================================
# CI Simulation
# ===========================================================================

.PHONY: ci-simulate
ci-simulate: clean deps lint-go lint-vuln test build docker-build ## Simulate the full CI pipeline locally
	@echo ">>> CI simulation complete"

# ===========================================================================
# Utilities
# ===========================================================================

.PHONY: todo
todo: ## Show all TODO/FIXME/HACK comments in the codebase
	@grep -rn "TODO\|FIXME\|HACK\|XXX" --include="*.go" . || echo "No TODOs found"

.PHONY: version
version: ## Print version information
	@echo "Service:    $(SERVICE_NAME)"
	@echo "Version:    $(VERSION)"
	@echo "Commit:     $(GIT_COMMIT)"
	@echo "Built:      $(BUILD_DATE)"
	@echo "Go:         $(shell go version)"
	@echo "Binary:     $(BINARY_PATH)"
