package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/domain"
)

const tracerName = "entity-management.postgres"

type UnitOfWork struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewUnitOfWork(pool *pgxpool.Pool, logger *slog.Logger) *UnitOfWork {
	return &UnitOfWork{
		pool:   pool,
		logger: logger.With("adapter", "postgres.UnitOfWork"),
	}
}

type txKey struct{}

func (u *UnitOfWork) Execute(ctx context.Context, fn func(uowCtx context.Context) error) error {
	tx, err := u.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}

	txCtx := context.WithValue(ctx, txKey{}, tx)
	if err := fn(txCtx); err != nil {
		if rbErr := tx.Rollback(ctx); rbErr != nil {
			u.logger.ErrorContext(ctx, "rollback failed", "error", rbErr)
		}
		return err
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit tx: %w", err)
	}
	return nil
}

var _ domain.UnitOfWork = (*UnitOfWork)(nil)

type SchemaRepository struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
	tracer trace.Tracer
}

func NewSchemaRepository(pool *pgxpool.Pool, logger *slog.Logger) *SchemaRepository {
	return &SchemaRepository{
		pool:   pool,
		logger: logger.With("adapter", "postgres.SchemaRepository"),
		tracer: otel.Tracer(tracerName),
	}
}



func (r *SchemaRepository) Save(ctx context.Context, schema *domain.EntitySchema) error {
	ctx, span := r.tracer.Start(ctx, "postgres.SchemaRepository.Save",
		trace.WithAttributes(
			attribute.String("schema_id", schema.ID),
			attribute.String("schema_name", schema.Name),
			attribute.Int("version", schema.Version),
		))
	defer span.End()

	attrsJSON, err := json.Marshal(schema.Attributes)
	if err != nil {
		return fmt.Errorf("marshal attributes: %w", err)
	}

	query := `
		INSERT INTO entity_schemas (id, name, version, attributes, created_at, updated_at)
		VALUES ($1, $2, $3, $4::jsonb, $5, $6)
		ON CONFLICT (id) DO UPDATE SET
			version = EXCLUDED.version,
			attributes = EXCLUDED.attributes,
			updated_at = EXCLUDED.updated_at
	`

	_, err = r.pool.Exec(ctx, query,
		schema.ID, schema.Name, schema.Version, string(attrsJSON),
		schema.CreatedAt, schema.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("save schema: %w", err)
	}
	return nil
}

func (r *SchemaRepository) FindByID(ctx context.Context, id string) (*domain.EntitySchema, error) {
	ctx, span := r.tracer.Start(ctx, "postgres.SchemaRepository.FindByID",
		trace.WithAttributes(attribute.String("schema_id", id)))
	defer span.End()

	query := `SELECT id, name, version, attributes, created_at, updated_at
		FROM entity_schemas WHERE id = $1`

	schema, err := r.scanSchema(ctx, r.pool.QueryRow(ctx, query, id))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("find schema by id: %w", domain.ErrSchemaNotFound)
		}
		return nil, fmt.Errorf("find schema by id: %w", err)
	}
	return schema, nil
}

func (r *SchemaRepository) FindByName(ctx context.Context, name string) (*domain.EntitySchema, error) {
	ctx, span := r.tracer.Start(ctx, "postgres.SchemaRepository.FindByName",
		trace.WithAttributes(attribute.String("schema_name", name)))
	defer span.End()

	query := `SELECT id, name, version, attributes, created_at, updated_at
		FROM entity_schemas WHERE name = $1 ORDER BY version DESC LIMIT 1`

	schema, err := r.scanSchema(ctx, r.pool.QueryRow(ctx, query, name))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("find schema by name: %w", domain.ErrSchemaNotFound)
		}
		return nil, fmt.Errorf("find schema by name: %w", err)
	}
	return schema, nil
}

func (r *SchemaRepository) FindAll(ctx context.Context) ([]*domain.EntitySchema, error) {
	ctx, span := r.tracer.Start(ctx, "postgres.SchemaRepository.FindAll")
	defer span.End()

	query := `SELECT DISTINCT ON (name) id, name, version, attributes, created_at, updated_at
		FROM entity_schemas ORDER BY name, version DESC`

	rows, err := r.pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("find all schemas: %w", err)
	}
	defer rows.Close()

	var schemas []*domain.EntitySchema
	for rows.Next() {
		schema, err := r.scanSchema(ctx, rows)
		if err != nil {
			return nil, fmt.Errorf("find all schemas: scan: %w", err)
		}
		schemas = append(schemas, schema)
	}
	if schemas == nil {
		schemas = []*domain.EntitySchema{}
	}
	return schemas, rows.Err()
}

func (r *SchemaRepository) Delete(ctx context.Context, id string) error {
	ctx, span := r.tracer.Start(ctx, "postgres.SchemaRepository.Delete",
		trace.WithAttributes(attribute.String("schema_id", id)))
	defer span.End()

	tag, err := r.pool.Exec(ctx, `DELETE FROM entity_schemas WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("delete schema: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("delete schema: %w", domain.ErrSchemaNotFound)
	}
	return nil
}

func (r *SchemaRepository) scanSchema(_ context.Context, row pgx.Row) (*domain.EntitySchema, error) {
	var (
		id, name             string
		version              int
		attrsJSON            []byte
		createdAt, updatedAt time.Time
	)
	if err := row.Scan(&id, &name, &version, &attrsJSON, &createdAt, &updatedAt); err != nil {
		return nil, err
	}

	var attrs []domain.AttributeDefinition
	if err := json.Unmarshal(attrsJSON, &attrs); err != nil {
		return nil, fmt.Errorf("unmarshal attributes: %w", err)
	}

	return &domain.EntitySchema{
		ID: id, Name: name, Version: version,
		Attributes: attrs, CreatedAt: createdAt, UpdatedAt: updatedAt,
	}, nil
}

type OutboxRepository struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
	tracer trace.Tracer
}

func NewOutboxRepository(pool *pgxpool.Pool, logger *slog.Logger) *OutboxRepository {
	return &OutboxRepository{
		pool:   pool,
		logger: logger.With("adapter", "postgres.OutboxRepository"),
		tracer: otel.Tracer(tracerName),
	}
}

func (r *OutboxRepository) Save(ctx context.Context, event *domain.OutboxEvent) error {
	query := `INSERT INTO outbox_events (id, aggregate_id, aggregate_type, event_type, payload, status, retry_count, created_at)
		VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7, $8)`
	_, err := r.pool.Exec(ctx, query,
		event.ID, event.AggregateID, event.AggregateType, event.EventType,
		event.Payload, event.Status, event.RetryCount, event.CreatedAt)
	if err != nil {
		return fmt.Errorf("outbox save: %w", err)
	}
	return nil
}

func (r *OutboxRepository) MarkPublished(ctx context.Context, id string) error {
	_, err := r.pool.Exec(ctx, `UPDATE outbox_events SET status = 'published' WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("outbox mark published: %w", err)
	}
	return nil
}

func (r *OutboxRepository) MarkFailed(ctx context.Context, id string, _ error) error {
	_, err := r.pool.Exec(ctx,
		`UPDATE outbox_events SET status = 'failed', retry_count = retry_count + 1 WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("outbox mark failed: %w", err)
	}
	return nil
}

func (r *OutboxRepository) FetchPending(ctx context.Context, limit int) ([]*domain.OutboxEvent, error) {
	query := `SELECT id, aggregate_id, aggregate_type, event_type, payload, status, retry_count, created_at
		FROM outbox_events WHERE status = 'pending' ORDER BY created_at LIMIT $1`
	rows, err := r.pool.Query(ctx, query, limit)
	if err != nil {
		return nil, fmt.Errorf("outbox fetch pending: %w", err)
	}
	defer rows.Close()

	var events []*domain.OutboxEvent
	for rows.Next() {
		var e domain.OutboxEvent
		if err := rows.Scan(&e.ID, &e.AggregateID, &e.AggregateType, &e.EventType,
			&e.Payload, &e.Status, &e.RetryCount, &e.CreatedAt); err != nil {
			return nil, fmt.Errorf("outbox scan: %w", err)
		}
		events = append(events, &e)
	}
	return events, rows.Err()
}

type IdempotencyStore struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
	tracer trace.Tracer
}

func NewIdempotencyStore(pool *pgxpool.Pool, logger *slog.Logger) *IdempotencyStore {
	return &IdempotencyStore{
		pool:   pool,
		logger: logger.With("adapter", "postgres.IdempotencyStore"),
		tracer: otel.Tracer(tracerName),
	}
}

func (s *IdempotencyStore) IsDuplicate(ctx context.Context, key domain.IdempotencyKey) (bool, error) {
	query := `SELECT EXISTS(SELECT 1 FROM idempotency_keys WHERE event_id = $1 AND entity_id = $2 AND expires_at > NOW())`
	var exists bool
	err := s.pool.QueryRow(ctx, query, key.EventID, key.EntityID).Scan(&exists)
	if err != nil {
		return false, fmt.Errorf("idempotency check: %w", err)
	}
	return exists, nil
}

func (s *IdempotencyStore) MarkProcessed(ctx context.Context, key domain.IdempotencyKey) error {
	query := `INSERT INTO idempotency_keys (event_id, entity_id, expires_at)
		VALUES ($1, $2, NOW() + INTERVAL '7 days') ON CONFLICT DO NOTHING`
	_, err := s.pool.Exec(ctx, query, key.EventID, key.EntityID)
	if err != nil {
		return fmt.Errorf("idempotency mark processed: %w", err)
	}
	return nil
}

func (s *IdempotencyStore) CleanExpired(ctx context.Context) (int, error) {
	tag, err := s.pool.Exec(ctx, `DELETE FROM idempotency_keys WHERE expires_at <= NOW()`)
	if err != nil {
		return 0, fmt.Errorf("idempotency clean: %w", err)
	}
	return int(tag.RowsAffected()), nil
}

var (
	_ domain.SchemaRepository = (*SchemaRepository)(nil)
	_ domain.OutboxRepository = (*OutboxRepository)(nil)
	_ domain.IdempotencyStore = (*IdempotencyStore)(nil)
)
