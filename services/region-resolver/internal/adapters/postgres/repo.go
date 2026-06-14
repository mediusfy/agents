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

	"github.com/prodanlabs/region-resolver/internal/domain"
)

const (
	tracerName   = "region-resolver.postgres"
	attrEntityID = "entity_id"
)

type EntityRepository struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
	tracer trace.Tracer
}

func NewEntityRepository(pool *pgxpool.Pool, logger *slog.Logger) *EntityRepository {
	return &EntityRepository{
		pool:   pool,
		logger: logger.With("adapter", "postgres.EntityRepository"),
		tracer: otel.Tracer(tracerName),
	}
}

func (r *EntityRepository) Save(ctx context.Context, entity *domain.Entity) error {
	ctx, span := r.tracer.Start(ctx, "postgres.EntityRepository.Save",
		trace.WithAttributes(
			attribute.String(attrEntityID, entity.ID),
		))
	defer span.End()

	labelsJSON, err := json.Marshal(entity.Labels)
	if err != nil {
		return fmt.Errorf("marshal entity labels: %w", err)
	}

	query := `
		INSERT INTO entities (id, name, region, data_residency_zone, status, version, labels, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name, region = EXCLUDED.region,
			data_residency_zone = EXCLUDED.data_residency_zone, status = EXCLUDED.status,
			version = EXCLUDED.version, labels = EXCLUDED.labels, updated_at = EXCLUDED.updated_at
	`

	_, err = r.pool.Exec(ctx, query,
		entity.ID, entity.Name, entity.Region, string(entity.DataResidencyZone),
		string(entity.Status), entity.Version, labelsJSON, entity.CreatedAt, entity.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("save entity: %w", err)
	}
	return nil
}

func (r *EntityRepository) FindByID(ctx context.Context, id string) (*domain.Entity, error) {
	ctx, span := r.tracer.Start(ctx, "postgres.EntityRepository.FindByID",
		trace.WithAttributes(attribute.String(attrEntityID, id)))
	defer span.End()

	query := `SELECT id, name, region, data_residency_zone, status, version, labels, created_at, updated_at 
	          FROM entities WHERE id = $1`

	var name, region, zone, status string
	var version int
	var labelsJSON []byte
	var createdAt, updatedAt time.Time

	err := r.pool.QueryRow(ctx, query, id).Scan(
		&id, &name, &region, &zone, &status, &version, &labelsJSON, &createdAt, &updatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrEntityNotFound
		}
		return nil, fmt.Errorf("find entity by id: %w", err)
	}

	var labels map[string]string
	if len(labelsJSON) > 0 {
		if err := json.Unmarshal(labelsJSON, &labels); err != nil {
			return nil, fmt.Errorf("unmarshal entity labels: %w", err)
		}
	}

	return &domain.Entity{
		ID:                id,
		Name:              name,
		Region:            region,
		DataResidencyZone: domain.DataResidencyZone(zone),
		Status:            domain.EntityStatus(status),
		Version:           version,
		Labels:            labels,
		CreatedAt:         createdAt,
		UpdatedAt:         updatedAt,
	}, nil
}

func (r *EntityRepository) Update(ctx context.Context, entity *domain.Entity) error {
	ctx, span := r.tracer.Start(ctx, "postgres.EntityRepository.Update",
		trace.WithAttributes(
			attribute.String(attrEntityID, entity.ID),
		))
	defer span.End()

	labelsJSON, err := json.Marshal(entity.Labels)
	if err != nil {
		return fmt.Errorf("marshal entity labels: %w", err)
	}

	query := `
		UPDATE entities
		SET name = $1, status = $2, version = $3, labels = $4, updated_at = $5
		WHERE id = $6 AND version = $7
	`
	prevVersion := entity.Version - 1
	cmdTag, err := r.pool.Exec(ctx, query,
		entity.Name, string(entity.Status), entity.Version, labelsJSON, entity.UpdatedAt,
		entity.ID, prevVersion,
	)
	if err != nil {
		return fmt.Errorf("update entity: %w", err)
	}

	if cmdTag.RowsAffected() == 0 {
		var exists bool
		err = r.pool.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM entities WHERE id = $1)", entity.ID).Scan(&exists)
		if err != nil {
			return fmt.Errorf("check entity existence: %w", err)
		}
		if !exists {
			return domain.ErrEntityNotFound
		}
		return domain.ErrConcurrentModification
	}

	return nil
}

func (r *EntityRepository) List(ctx context.Context) ([]*domain.Entity, error) {
	ctx, span := r.tracer.Start(ctx, "postgres.EntityRepository.List")
	defer span.End()

	query := `SELECT id, name, region, data_residency_zone, status, version, labels, created_at, updated_at FROM entities`
	rows, err := r.pool.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("list entities: %w", err)
	}
	defer rows.Close()

	var entities []*domain.Entity
	for rows.Next() {
		var id, name, region, zone, status string
		var version int
		var labelsJSON []byte
		var createdAt, updatedAt time.Time

		err := rows.Scan(&id, &name, &region, &zone, &status, &version, &labelsJSON, &createdAt, &updatedAt)
		if err != nil {
			return nil, fmt.Errorf("scan listed entity: %w", err)
		}

		var labels map[string]string
		if len(labelsJSON) > 0 {
			if err := json.Unmarshal(labelsJSON, &labels); err != nil {
				return nil, fmt.Errorf("unmarshal listed entity labels: %w", err)
			}
		}

		entities = append(entities, &domain.Entity{
			ID:                id,
			Name:              name,
			Region:            region,
			DataResidencyZone: domain.DataResidencyZone(zone),
			Status:            domain.EntityStatus(status),
			Version:           version,
			Labels:            labels,
			CreatedAt:         createdAt,
			UpdatedAt:         updatedAt,
		})
	}
	if err = rows.Err(); err != nil {
		return nil, fmt.Errorf("rows iteration: %w", err)
	}

	return entities, nil
}

func (r *EntityRepository) Delete(ctx context.Context, id string) error {
	ctx, span := r.tracer.Start(ctx, "postgres.EntityRepository.Delete",
		trace.WithAttributes(attribute.String(attrEntityID, id)))
	defer span.End()

	query := `DELETE FROM entities WHERE id = $1`
	cmdTag, err := r.pool.Exec(ctx, query, id)
	if err != nil {
		return fmt.Errorf("delete entity: %w", err)
	}

	if cmdTag.RowsAffected() == 0 {
		return domain.ErrEntityNotFound
	}
	return nil
}

var _ domain.EntityRepository = (*EntityRepository)(nil)
