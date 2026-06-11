// Package postgres implements the domain.EntityRepository port using
// PostgreSQL via the pgx/v5 driver.
package postgres

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

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

	row := r.pool.QueryRow(ctx, query, id)
	entity, err := scanEntity(row)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("query entity %s: %w", id, err)
	}

	span.SetAttributes(
		attribute.String("region", entity.Region),
		attribute.String("data_residency_zone", string(entity.DataResidencyZone)),
		attribute.Int("version", entity.Version),
	)

	return entity, nil
}

// Update persists an entity's current state, overwriting the existing row.
func (r *EntityRepository) Update(ctx context.Context, entity *domain.Entity) error {
	ctx, span := tracer.Start(ctx, "postgres.EntityRepository.Update",
		trace.WithAttributes(
			attribute.String("entity_id", entity.ID),
			attribute.Int("new_version", entity.Version),
		),
	)
	defer span.End()

	labelsJSON, err := json.Marshal(entity.Labels)
	if err != nil {
		return fmt.Errorf("marshal labels: %w", err)
	}

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
		return fmt.Errorf("update entity %s: %w", entity.ID, domain.ErrStaleVersion)
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
		entity, err := scanRow(rows)
		if err != nil {
			return nil, fmt.Errorf("scan entity row: %w", err)
		}
		entities = append(entities, entity)
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

// scanEntity scans a pgx.Row into a domain.Entity pointer.
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

// scanRow scans a pgx.Rows into a domain.Entity pointer.
func scanRow(rows pgx.Rows) (*domain.Entity, error) {
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
