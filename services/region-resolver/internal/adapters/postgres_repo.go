// Package postgres implements the domain.EntityRepository port using
// PostgreSQL via the pgx/v5 driver.
package postgres

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"github.com/prodanlabs/region-resolver/internal/domain"
)

var tracer = otel.Tracer("postgres.entity_repo")

// Compile-time interface check.
var _ domain.EntityRepository = (*EntityRepository)(nil)

// EntityRepository implements domain.EntityRepository using PostgreSQL.
type EntityRepository struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

// NewEntityRepository creates a new Postgres-backed entity repository.
func NewEntityRepository(pool *pgxpool.Pool, logger *slog.Logger) *EntityRepository {
	return &EntityRepository{
		pool:   pool,
		logger: logger.With("component", "EntityRepository"),
	}
}

// MigrateEntities creates the entities table if it does not exist.
func (r *EntityRepository) MigrateEntities(ctx context.Context) error {
	query := `
	CREATE TABLE IF NOT EXISTS entities (
		id                TEXT PRIMARY KEY,
		name              TEXT NOT NULL,
		region            TEXT NOT NULL,
		data_residency_zone TEXT NOT NULL,
		status            TEXT NOT NULL DEFAULT 'active',
		version           INTEGER NOT NULL DEFAULT 1,
		labels            JSONB DEFAULT '{}',
		created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
	);

	CREATE INDEX IF NOT EXISTS idx_entities_region ON entities(region);
	CREATE INDEX IF NOT EXISTS idx_entities_zone ON entities(data_residency_zone);
	`
	_, err := r.pool.Exec(ctx, query)
	if err != nil {
		return fmt.Errorf("migrate entities table: %w", err)
	}
	return nil
}

// Save persists a new entity. Returns an error if the ID already exists.
func (r *EntityRepository) Save(ctx context.Context, entity *domain.Entity) error {
	ctx, span := tracer.Start(ctx, "postgres.EntityRepository.Save",
		trace.WithAttributes(
			attribute.String("entity_id", entity.ID),
			attribute.String("region", entity.Region),
			attribute.String("data_residency_zone", string(entity.DataResidencyZone)),
		),
	)
	defer span.End()

	labelsJSON, err := json.Marshal(entity.Labels)
	if err != nil {
		return fmt.Errorf("marshal labels: %w", err)
	}

	query := `
		INSERT INTO entities (id, name, region, data_residency_zone, status, version, labels, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
	`

	_, err = r.pool.Exec(ctx, query,
		entity.ID,
		entity.Name,
		entity.Region,
		string(entity.DataResidencyZone),
		string(entity.Status),
		entity.Version,
		labelsJSON,
		entity.CreatedAt,
		entity.UpdatedAt,
	)
	if err != nil {
		span.RecordError(err)
		return fmt.Errorf("insert entity: %w", err)
	}

	r.logger.DebugContext(ctx, "entity saved",
		"entity_id", entity.ID,
		"region", entity.Region,
		"zone", entity.DataResidencyZone,
	)
	return nil
}

// FindByID retrieves an entity by its primary key.
// Returns domain.ErrEntityNotFound if no row exists.
func (r *EntityRepository) FindByID(ctx context.Context, id string) (*domain.Entity, error) {
	ctx, span := tracer.Start(ctx, "postgres.EntityRepository.FindByID",
		trace.WithAttributes(attribute.String("entity_id", id)),
	)
	defer span.End()

	query := `
		SELECT id, name, region, data_residency_zone, status, version, labels, created_at, updated_at
		FROM entities
		WHERE id = $1
	`

	var entity domain.Entity
	var labelsJSON []byte
	var statusStr string
	var zoneStr string

	err := r.pool.QueryRow(ctx, query, id).Scan(
		&entity.ID,
		&entity.Name,
		&entity.Region,
		&zoneStr,
		&statusStr,
		&entity.Version,
		&labelsJSON,
		&entity.CreatedAt,
		&entity.UpdatedAt,
	)
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, fmt.Errorf("%w: %s", domain.ErrEntityNotFound, id)
		}
		span.RecordError(err)
		return nil, fmt.Errorf("query entity %s: %w", id, err)
	}

	entity.Status = domain.EntityStatus(statusStr)
	entity.DataResidencyZone = domain.DataResidencyZone(zoneStr)

	if len(labelsJSON) > 0 {
		if err := json.Unmarshal(labelsJSON, &entity.Labels); err != nil {
			return nil, fmt.Errorf("unmarshal labels: %w", err)
		}
	}

	span.SetAttributes(
		attribute.String("region", entity.Region),
		attribute.String("data_residency_zone", string(entity.DataResidencyZone)),
		attribute.Int("version", entity.Version),
	)

	return &entity, nil
}

// Update persists an entity's current state, overwriting the existing row.
// Callers MUST ensure the entity's Version has been incremented before
// calling Update to enforce optimistic concurrency.
func (r *EntityRepository) Update(ctx context.Context, entity *domain.Entity) error {
	ctx, span := tracer.Start(ctx, "postgres.EntityRepository.Update",
		trace.WithAttributes(
			attribute.String("entity_id", entity.ID),
			attribute.Int("expected_version", entity.Version-1),
			attribute.Int("new_version", entity.Version),
		),
	)
	defer span.End()

	labelsJSON, err := json.Marshal(entity.Labels)
	if err != nil {
		return fmt.Errorf("marshal labels: %w", err)
	}

	// Use the previous version (entity.Version - 1) as the optimistic lock,
	// since the version was incremented by ApplyUpdate.
	query := `
		UPDATE entities
		SET name = $1, status = $2, version = $3, labels = $4, updated_at = $5
		WHERE id = $6 AND version = $7
	`

	tag, err := r.pool.Exec(ctx, query,
		entity.Name,
		string(entity.Status),
		entity.Version,
		labelsJSON,
		entity.UpdatedAt,
		entity.ID,
		entity.Version-1,
	)
	if err != nil {
		span.RecordError(err)
		return fmt.Errorf("update entity %s: %w", entity.ID, err)
	}

	if tag.RowsAffected() == 0 {
		// Either the entity doesn't exist or the version doesn't match.
		// Check which case it is.
		existing, checkErr := r.FindByID(ctx, entity.ID)
		if checkErr != nil {
			return fmt.Errorf("update entity %s: %w", entity.ID, domain.ErrStaleVersion)
		}
		if existing.Version != entity.Version-1 {
			return fmt.Errorf("update entity %s: %w", entity.ID, domain.ErrStaleVersion)
		}
		// Entity was deleted between read and update.
		return fmt.Errorf("update entity %s: %w", entity.ID, domain.ErrEntityNotFound)
	}

	r.logger.DebugContext(ctx, "entity updated",
		"entity_id", entity.ID,
		"new_version", entity.Version,
	)
	return nil
}

// List returns all entities from the database.
func (r *EntityRepository) List(ctx context.Context) ([]*domain.Entity, error) {
	ctx, span := tracer.Start(ctx, "postgres.EntityRepository.List")
	defer span.End()

	query := `
		SELECT id, name, region, data_residency_zone, status, version, labels, created_at, updated_at
		FROM entities
		ORDER BY created_at DESC
	`

	rows, err := r.pool.Query(ctx, query)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("list entities: %w", err)
	}
	defer rows.Close()

	var entities []*domain.Entity
	for rows.Next() {
		var entity domain.Entity
		var labelsJSON []byte
		var statusStr string
		var zoneStr string
		if err := rows.Scan(
			&entity.ID,
			&entity.Name,
			&entity.Region,
			&zoneStr,
			&statusStr,
			&entity.Version,
			&labelsJSON,
			&entity.CreatedAt,
			&entity.UpdatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan entity row: %w", err)
		}
		entity.Status = domain.EntityStatus(statusStr)
		entity.DataResidencyZone = domain.DataResidencyZone(zoneStr)
		if len(labelsJSON) > 0 {
			if err := json.Unmarshal(labelsJSON, &entity.Labels); err != nil {
				return nil, fmt.Errorf("unmarshal labels: %w", err)
			}
		}
		entities = append(entities, &entity)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate entity rows: %w", err)
	}

	if entities == nil {
		entities = []*domain.Entity{}
	}

	span.SetAttributes(attribute.Int("count", len(entities)))
	return entities, nil
}

// Delete removes an entity by its primary key.
func (r *EntityRepository) Delete(ctx context.Context, id string) error {
	ctx, span := tracer.Start(ctx, "postgres.EntityRepository.Delete",
		trace.WithAttributes(attribute.String("entity_id", id)),
	)
	defer span.End()

	query := `DELETE FROM entities WHERE id = $1`
	tag, err := r.pool.Exec(ctx, query, id)
	if err != nil {
		span.RecordError(err)
		return fmt.Errorf("delete entity %s: %w", id, err)
	}

	if tag.RowsAffected() == 0 {
		return fmt.Errorf("delete entity %s: %w", id, domain.ErrEntityNotFound)
	}

	return nil
}

// scanEntity scans a single entity row into a domain.Entity pointer.
// Used internally by scan methods.
func scanEntity(row pgx.Row) (*domain.Entity, error) {
	var entity domain.Entity
	var labelsJSON []byte
	var statusStr string
	var zoneStr string

	if err := row.Scan(
		&entity.ID,
		&entity.Name,
		&entity.Region,
		&zoneStr,
		&statusStr,
		&entity.Version,
		&labelsJSON,
		&entity.CreatedAt,
		&entity.UpdatedAt,
	); err != nil {
		if err == pgx.ErrNoRows {
			return nil, domain.ErrEntityNotFound
		}
		return nil, err
	}

	entity.Status = domain.EntityStatus(statusStr)
	entity.DataResidencyZone = domain.DataResidencyZone(zoneStr)

	if len(labelsJSON) > 0 {
		if err := json.Unmarshal(labelsJSON, &entity.Labels); err != nil {
			return nil, fmt.Errorf("unmarshal labels: %w", err)
		}
	}

	return &entity, nil
}

// Ensure time is used (suppress unused import warnings).
var _ = time.Now
