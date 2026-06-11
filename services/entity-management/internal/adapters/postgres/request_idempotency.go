package postgres

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/domain"
)

type RequestIdempotencyStore struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
	tracer trace.Tracer
}

func NewRequestIdempotencyStore(pool *pgxpool.Pool, logger *slog.Logger) *RequestIdempotencyStore {
	return &RequestIdempotencyStore{
		pool:   pool,
		logger: logger.With("adapter", "postgres.RequestIdempotencyStore"),
		tracer: otel.Tracer(tracerName),
	}
}

func (s *RequestIdempotencyStore) GetEntityID(ctx context.Context, requestKey string) (string, error) {
	ctx, span := s.tracer.Start(ctx, "postgres.RequestIdempotencyStore.GetEntityID",
		trace.WithAttributes(attribute.String("request_key", requestKey)))
	defer span.End()

	query := `SELECT entity_id FROM request_idempotency_keys WHERE request_key = $1 AND expires_at > NOW()`
	var entityID string
	err := s.pool.QueryRow(ctx, query, requestKey).Scan(&entityID)
	if err != nil {
		return "", nil
	}
	return entityID, nil
}

func (s *RequestIdempotencyStore) Save(ctx context.Context, requestKey, entityID string, ttl time.Duration) error {
	ctx, span := s.tracer.Start(ctx, "postgres.RequestIdempotencyStore.Save",
		trace.WithAttributes(
			attribute.String("request_key", requestKey),
			attribute.String("entity_id", entityID),
		))
	defer span.End()

	query := `INSERT INTO request_idempotency_keys (request_key, entity_id, expires_at)
		VALUES ($1, $2, NOW() + $3::interval) ON CONFLICT (request_key) DO UPDATE SET
			entity_id = EXCLUDED.entity_id, expires_at = EXCLUDED.expires_at`

	_, err := s.pool.Exec(ctx, query, requestKey, entityID, fmt.Sprintf("%d seconds", int(ttl.Seconds())))
	if err != nil {
		return fmt.Errorf("save request idempotency key: %w", err)
	}
	return nil
}

func (s *RequestIdempotencyStore) CleanExpired(ctx context.Context) (int, error) {
	tag, err := s.pool.Exec(ctx, `DELETE FROM request_idempotency_keys WHERE expires_at <= NOW()`)
	if err != nil {
		return 0, fmt.Errorf("clean expired request idempotency keys: %w", err)
	}
	return int(tag.RowsAffected()), nil
}

func (s *RequestIdempotencyStore) MigrateRequestIdempotency(ctx context.Context) error {
	ddl := `
	CREATE TABLE IF NOT EXISTS request_idempotency_keys (
		request_key TEXT PRIMARY KEY,
		entity_id   TEXT NOT NULL,
		created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		expires_at  TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '7 days'
	);
	CREATE INDEX IF NOT EXISTS idx_request_idempotency_expires
		ON request_idempotency_keys(expires_at);
	`
	_, err := s.pool.Exec(ctx, ddl)
	if err != nil {
		return fmt.Errorf("migrate request idempotency keys: %w", err)
	}
	return nil
}

var _ domain.RequestIdempotencyStore = (*RequestIdempotencyStore)(nil)
