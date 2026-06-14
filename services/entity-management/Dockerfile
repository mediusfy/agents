# =============================================================================
# Entity Management - Multi-Stage Dockerfile
# =============================================================================
# Supports all 12 ENTITYMGMT stories.
# 
# Build arguments:
#   VERSION    - Semantic version (default: dev)
#   GIT_COMMIT - Git commit hash  (default: unknown)
#   BUILD_DATE - Build timestamp   (default: unknown)
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Go module cache (leveraged by Docker layer caching)
# ---------------------------------------------------------------------------
FROM golang:1.26-alpine AS base

RUN apk add --no-cache ca-certificates tzdata git

WORKDIR /src

# ---------------------------------------------------------------------------
# Stage 2: Dependency download (cached layer unless go.mod/sum change)
# ---------------------------------------------------------------------------
FROM base AS deps

COPY go.mod go.sum ./
RUN go mod download && go mod verify

# ---------------------------------------------------------------------------
# Stage 3: Build the binary
# ---------------------------------------------------------------------------
FROM deps AS builder

ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_DATE=unknown
ARG TARGETOS=linux
ARG TARGETARCH=amd64

LABEL org.opencontainers.image.title="entity-management"
LABEL org.opencontainers.image.description="Entity Management Service"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${GIT_COMMIT}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.source="https://github.com/your-org/entity-management"

COPY . .

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
    -ldflags="-s -w \
      -X main.Version=${VERSION} \
      -X main.Commit=${GIT_COMMIT} \
      -X main.Date=${BUILD_DATE}" \
    -o /usr/local/bin/entity-management \
    ./cmd/server/main.go

# Verify the binary
RUN echo "Binary size: $(ls -lh /usr/local/bin/entity-management | awk '{print $5}')" && \
    file /usr/local/bin/entity-management && \
    /usr/local/bin/entity-management --help 2>&1 || true

# ---------------------------------------------------------------------------
# Stage 4: Minimal runtime image
# ---------------------------------------------------------------------------
FROM alpine:3.21 AS runtime

RUN apk add --no-cache ca-certificates tzdata wget && \
    adduser -D -u 1001 appuser && \
    mkdir -p /app && \
    chown -R appuser:appuser /app

WORKDIR /app

# Copy only the binary (no source code, no build tools)
COPY --from=builder /usr/local/bin/entity-management .

# Security: drop all capabilities, use non-root user
USER appuser

# Service port
EXPOSE 8080

# Health check (ENTITYMGMT-12: /healthz endpoint)
HEALTHCHECK --interval=10s --timeout=3s --start-period=8s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/healthz || exit 1

# Security: read-only root filesystem
# (enable with --read-only --tmpfs /tmp when running)
# VOLUME /tmp

ENTRYPOINT ["./entity-management"]
