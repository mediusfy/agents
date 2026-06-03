package postgres

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/cto-ai/entity-management/internal/domain"
)

// EntityRepository is a PostgreSQL-backed implementation of domain.EntityRepository.
type EntityRepository struct {
	pool *pgxpool.Pool
}

// NewEntityRepository creates a new Postgres repository.
func NewEntityRepository(pool *pgxpool.Pool) *EntityRepository {
	return &EntityRepository{pool: pool}
}

// GetByID retrieves an entity by its primary key.
func (r *EntityRepository) GetByID(ctx context.Context, id string) (*domain.Entity, error) {
	const query = `
		SELECT id, name, labels, version, created_at, updated_at
		FROM entities
		WHERE id = $1
	`

	row := r.pool.QueryRow(ctx, query, id)
	var (
		entity    domain.Entity
		labelsRaw []byte
	)
	if err := row.Scan(&entity.ID, &entity.Name, &labelsRaw, &entity.Version, &entity.CreatedAt, &entity.UpdatedAt); err != nil {
		if err == pgx.ErrNoRows {
			return nil, fmt.Errorf("%w: %s", domain.ErrEntityNotFound, id)
		}
		return nil, fmt.Errorf("scan entity: %w", err)
	}
	if labelsRaw != nil {
		if err := json.Unmarshal(labelsRaw, &entity.Labels); err != nil {
			return nil, fmt.Errorf("unmarshal labels: %w", err)
		}
	}
	if entity.Labels == nil {
		entity.Labels = make(map[string]string)
	}
	return &entity, nil
}

// Update persists the entity using optimistic concurrency.
// It returns domain.ErrStaleVersion if the version column doesn't match.
func (r *EntityRepository) Update(ctx context.Context, entity *domain.Entity) error {
	const query = `
		UPDATE entities
		SET name = $1, labels = $2, version = $3, updated_at = $4
		WHERE id = $5 AND version = $6
	`

	labelsRaw, err := json.Marshal(entity.Labels)
	if err != nil {
		return fmt.Errorf("marshal labels: %w", err)
	}

	prevVersion := entity.Version - 1
	tag, err := r.pool.Exec(ctx, query,
		entity.Name,
		labelsRaw,
		entity.Version,
		entity.UpdatedAt,
		entity.ID,
		prevVersion,
	)
	if err != nil {
		return fmt.Errorf("exec update: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("%w: entity %s at version %d", domain.ErrStaleVersion, entity.ID, prevVersion)
	}
	return nil
}

func (r *EntityRepository) Close(ctx context.Context) error {
	r.pool.Close()
	return nil
}

// ---- OutboxRepository ----

// OutboxRepository stores pending domain events for reliable publication.
type OutboxRepository struct {
	pool *pgxpool.Pool
}

// NewOutboxRepository creates a new outbox repository.
func NewOutboxRepository(pool *pgxpool.Pool) *OutboxRepository {
	return &OutboxRepository{pool: pool}
}

func (o *OutboxRepository) Insert(ctx context.Context, msg *domain.OutboxMessage) error {
	const query = `
		INSERT INTO outbox (id, subject, event_type, payload, created_at)
		VALUES ($1, $2, $3, $4, $5)
	`
	_, err := o.pool.Exec(ctx, query,
		msg.ID, msg.Subject, msg.EventType, msg.Payload, msg.CreatedAt,
	)
	if err != nil {
		return fmt.Errorf("insert outbox: %w", err)
	}
	return nil
}

func (o *OutboxRepository) FetchPending(ctx context.Context, batchSize int) ([]domain.OutboxMessage, error) {
	const query = `
		SELECT id, subject, event_type, payload, created_at
		FROM outbox
		WHERE published_at IS NULL
		ORDER BY created_at ASC
		LIMIT $1
		FOR UPDATE SKIP LOCKED
	`
	rows, err := o.pool.Query(ctx, query, batchSize)
	if err != nil {
		return nil, fmt.Errorf("fetch pending outbox: %w", err)
	}
	defer rows.Close()

	var msgs []domain.OutboxMessage
	for rows.Next() {
		var m domain.OutboxMessage
		if err := rows.Scan(&m.ID, &m.Subject, &m.EventType, &m.Payload, &m.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan outbox row: %w", err)
		}
		msgs = append(msgs, m)
	}
	return msgs, rows.Err()
}

func (o *OutboxRepository) MarkPublished(ctx context.Context, ids []string) error {
	const query = `
		UPDATE outbox
		SET published_at = NOW()
		WHERE id = ANY($1)
	`
	_, err := o.pool.Exec(ctx, query, ids)
	if err != nil {
		return fmt.Errorf("mark outbox published: %w", err)
	}
	return nil
}

func (o *OutboxRepository) DeletePublished(ctx context.Context, olderThan time.Duration) error {
	const query = `
		DELETE FROM outbox
		WHERE published_at IS NOT NULL
		AND published_at < NOW() - $1::interval
	`
	_, err := o.pool.Exec(ctx, query, fmt.Sprintf("%f seconds", olderThan.Seconds()))
	if err != nil {
		return fmt.Errorf("delete old outbox messages: %w", err)
	}
	return nil
}
