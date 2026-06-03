package repository

import (
	"context"
	"encoding/json"
	"time"

	"entity-management/internal/domain"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("adapters.repository.PostgresRepo")

// PostgresRepo implements ports.Repository using pgx.
type PostgresRepo struct {
	pool *pgxpool.Pool
}

// NewPostgresRepo creates a new repository backed by a pgx connection pool.
func NewPostgresRepo(pool *pgxpool.Pool) *PostgresRepo {
	return &PostgresRepo{pool: pool}
}

// GetByID loads a single entity by primary key.
func (r *PostgresRepo) GetByID(ctx context.Context, id string) (*domain.Entity, error) {
	ctx, span := tracer.Start(ctx, "adapters.repository.PostgresRepo.GetByID",
		trace.WithAttributes(attribute.String("entity.id", id)))
	defer span.End()

	const query = `
		SELECT id, name, status, deleted_at, created_at, updated_at
		FROM entities
		WHERE id = $1
	`

	var ent domain.Entity
	err := r.pool.QueryRow(ctx, query, id).Scan(
		&ent.ID, &ent.Name, &ent.Status, &ent.DeletedAt,
		&ent.CreatedAt, &ent.UpdatedAt,
	)
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	return &ent, nil
}

// HardDelete permanently removes the entity row and inserts an outbox entry
// in the same database transaction for atomicity.
func (r *PostgresRepo) HardDelete(ctx context.Context, entity *domain.Entity) error {
	ctx, span := tracer.Start(ctx, "adapters.repository.PostgresRepo.HardDelete",
		trace.WithAttributes(
			attribute.String("entity.id", entity.ID),
		))
	defer span.End()

	return pgx.BeginTxFunc(ctx, r.pool, pgx.TxOptions{
		IsoLevel: pgx.ReadCommitted,
	}, func(tx pgx.Tx) error {
		// 1. Permanently delete the entity row.
		const deleteQ = `DELETE FROM entities WHERE id = $1`
		tag, err := tx.Exec(ctx, deleteQ, entity.ID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return domain.ErrNotFound
		}

		// 2. Write to the transactional outbox.
		payload, err := json.Marshal(domain.EntityHardDeletedEvent{
			EntityID: entity.ID,
		})
		if err != nil {
			return err
		}

		const outboxQ = `
			INSERT INTO outbox (id, event_type, subject, source, payload, created_at)
			VALUES ($1, $2, $3, $4, $5, $6)
		`
		_, err = tx.Exec(ctx, outboxQ,
			uuid.New().String(),
			"entitymanagement.entity.hard_deleted",
			string(domain.SubjectEntityHardDeleted),
			"entity-management",
			payload,
			time.Now().UTC(),
		)
		return err
	})
}
