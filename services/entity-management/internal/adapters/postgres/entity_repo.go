package postgres

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/domain"
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

func (r *EntityRepository) executor(ctx context.Context) pgxExecutor {
	return getExecutor(ctx, r.pool)
}

func (r *EntityRepository) Save(ctx context.Context, entity *domain.Entity) error {
	ctx, span := r.tracer.Start(ctx, "postgres.EntityRepository.Save",
		trace.WithAttributes(
			attribute.String("entity_id", entity.ID),
			attribute.String("schema_id", entity.SchemaID),
		))
	defer span.End()

	attrsJSON, _ := json.Marshal(entity.Attributes)
	metaJSON, _ := json.Marshal(entity.Metadata)

	query := `
		INSERT INTO entities (id, schema_id, name, type, region, data_residency_zone,
		                      status, version, attributes, metadata, created_at, updated_at, deleted_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10::jsonb, $11, $12, $13)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name, type = EXCLUDED.type, region = EXCLUDED.region,
			data_residency_zone = EXCLUDED.data_residency_zone, status = EXCLUDED.status,
			version = EXCLUDED.version, attributes = EXCLUDED.attributes,
			metadata = EXCLUDED.metadata, updated_at = EXCLUDED.updated_at,
			deleted_at = EXCLUDED.deleted_at
	`

	_, err := r.executor(ctx).Exec(ctx, query,
		entity.ID, entity.SchemaID, entity.Name, entity.Type, entity.Region,
		string(entity.DataResidencyZone), string(entity.Status), entity.Version,
		string(attrsJSON), string(metaJSON), entity.CreatedAt, entity.UpdatedAt, entity.DeletedAt,
	)
	if err != nil {
		return fmt.Errorf("save entity: %w", err)
	}
	return nil
}

func (r *EntityRepository) FindByID(ctx context.Context, id string) (*domain.Entity, error) {
	ctx, span := r.tracer.Start(ctx, "postgres.EntityRepository.FindByID",
		trace.WithAttributes(attribute.String("entity_id", id)))
	defer span.End()

	query := `SELECT id, schema_id, name, type, region, data_residency_zone,
		status, version, attributes, metadata, created_at, updated_at, deleted_at
		FROM entities WHERE id = $1`

	entity, err := r.scanEntity(ctx, r.executor(ctx).QueryRow(ctx, query, id))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("find entity by id: %w", domain.ErrEntityNotFound)
		}
		return nil, fmt.Errorf("find entity by id: %w", err)
	}
	return entity, nil
}

func (r *EntityRepository) Update(ctx context.Context, id string, op domain.UpdateOperation) (*domain.Entity, error) {
	ctx, span := r.tracer.Start(ctx, "postgres.EntityRepository.Update",
		trace.WithAttributes(attribute.String("entity_id", id)))
	defer span.End()

	entity, err := r.FindByID(ctx, id)
	if err != nil {
		return nil, err
	}

	if err := entity.ApplyUpdate(op); err != nil {
		return nil, err
	}

	attrsJSON, _ := json.Marshal(entity.Attributes)
	metaJSON, _ := json.Marshal(entity.Metadata)

	query := `
		UPDATE entities SET name=$2, type=$3, region=$4, status=$5,
		    version=$6, attributes=$7::jsonb, metadata=$8::jsonb,
		    updated_at=$9, deleted_at=$10
		WHERE id=$1 AND version=$11
	`
	tag, err := r.executor(ctx).Exec(ctx, query,
		id, entity.Name, entity.Type, entity.Region, string(entity.Status),
		entity.Version, string(attrsJSON), string(metaJSON),
		entity.UpdatedAt, entity.DeletedAt, op.ExpectedVersion,
	)
	if err != nil {
		return nil, fmt.Errorf("update entity: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return nil, fmt.Errorf("update entity %s: %w (expected version %d)", id, domain.ErrStaleVersion, op.ExpectedVersion)
	}

	return entity, nil
}

func (r *EntityRepository) UpdateStatus(ctx context.Context, id string, status domain.EntityStatus) error {
	ctx, span := r.tracer.Start(ctx, "postgres.EntityRepository.UpdateStatus",
		trace.WithAttributes(
			attribute.String("entity_id", id),
			attribute.String("new_status", string(status)),
		))
	defer span.End()

	now := time.Now().UTC()
	query := `UPDATE entities SET status=$2, updated_at=$3, version=version+1 WHERE id=$1`
	tag, err := r.executor(ctx).Exec(ctx, query, id, string(status), now)
	if err != nil {
		return fmt.Errorf("update status: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("update status: %w", domain.ErrEntityNotFound)
	}
	return nil
}

func (r *EntityRepository) SoftDelete(ctx context.Context, id string, deletedAt time.Time) error {
	query := `UPDATE entities SET deleted_at=$2, updated_at=$2, status='deleted', version=version+1 WHERE id=$1 AND deleted_at IS NULL`
	tag, err := r.executor(ctx).Exec(ctx, query, id, deletedAt)
	if err != nil {
		return fmt.Errorf("soft delete entity: %w", err)
	}
	if tag.RowsAffected() == 0 {
		exists, checkErr := r.exists(ctx, id)
		if checkErr != nil {
			return fmt.Errorf("soft delete existence check: %w", checkErr)
		}
		if !exists {
			return fmt.Errorf("soft delete: %w", domain.ErrEntityNotFound)
		}
		return fmt.Errorf("soft delete: %w", domain.ErrAlreadyDeleted)
	}
	return nil
}

func (r *EntityRepository) Restore(ctx context.Context, id string) error {
	query := `UPDATE entities SET deleted_at=NULL, status='active', updated_at=NOW(), version=version+1 WHERE id=$1 AND deleted_at IS NOT NULL`
	tag, err := r.executor(ctx).Exec(ctx, query, id)
	if err != nil {
		return fmt.Errorf("restore entity: %w", err)
	}
	if tag.RowsAffected() == 0 {
		exists, checkErr := r.exists(ctx, id)
		if checkErr != nil {
			return fmt.Errorf("restore existence check: %w", checkErr)
		}
		if !exists {
			return fmt.Errorf("restore: %w", domain.ErrEntityNotFound)
		}
		return fmt.Errorf("restore: %w", domain.ErrNotDeleted)
	}
	return nil
}

func (r *EntityRepository) HardDelete(ctx context.Context, id string) error {
	tag, err := r.pool.Exec(ctx, `DELETE FROM entities WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("hard delete entity: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("hard delete: %w", domain.ErrEntityNotFound)
	}
	return nil
}

func (r *EntityRepository) FindBySchemaID(ctx context.Context, schemaID string) ([]*domain.Entity, error) {
	query := `SELECT id, schema_id, name, type, region, data_residency_zone,
		status, version, attributes, metadata, created_at, updated_at, deleted_at
		FROM entities WHERE schema_id = $1 ORDER BY created_at DESC`
	return r.scanEntities(ctx, query, schemaID)
}

func (r *EntityRepository) List(ctx context.Context, filter domain.EntityFilter) ([]*domain.Entity, error) {
	args := make([]any, 0, 4)
	argIdx := 1
	where := ""

	if filter.Status != nil {
		where += fmt.Sprintf(" AND status = $%d", argIdx)
		args = append(args, string(*filter.Status))
		argIdx++
	}
	if filter.Region != nil {
		where += fmt.Sprintf(" AND region = $%d", argIdx)
		args = append(args, *filter.Region)
		argIdx++
	}
	if filter.Zone != nil {
		where += fmt.Sprintf(" AND data_residency_zone = $%d", argIdx)
		args = append(args, string(*filter.Zone))
		argIdx++
	}

	limit := filter.Limit
	if limit <= 0 {
		limit = 100
	}
	offset := filter.Offset
	if offset < 0 {
		offset = 0
	}

	query := `SELECT id, schema_id, name, type, region, data_residency_zone,
		status, version, attributes, metadata, created_at, updated_at, deleted_at
		FROM entities WHERE 1=1` + where + `
		ORDER BY created_at DESC LIMIT $` + fmt.Sprintf("%d", argIdx) + ` OFFSET $` + fmt.Sprintf("%d", argIdx+1)
	args = append(args, limit, offset)

	return r.scanEntities(ctx, query, args...)
}

func (r *EntityRepository) ListEntities(ctx context.Context, params domain.ListEntitiesParams) (*domain.PaginatedResult, error) {
	ctx, span := r.tracer.Start(ctx, "postgres.EntityRepository.ListEntities",
		trace.WithAttributes(
			attribute.String("schema_id", params.SchemaID),
			attribute.Int("limit", params.Limit),
			attribute.Int("filter_count", len(params.Filters)),
			attribute.Bool("include_deleted", params.IncludeDeleted),
		))
	defer span.End()

	var (
		whereParts []string
		args       []any
		argIdx     = 1
	)

	whereParts = append(whereParts, fmt.Sprintf("schema_id = $%d", argIdx))
	args = append(args, params.SchemaID)
	argIdx++

	if !params.IncludeDeleted {
		whereParts = append(whereParts, "deleted_at IS NULL")
	}

	if params.Cursor != "" {
		cursor, err := decodeCursorToken(params.Cursor)
		if err != nil {
			return nil, fmt.Errorf("list entities: %w", err)
		}
		whereParts = append(whereParts,
			fmt.Sprintf("(created_at, id) < ($%d::timestamptz, $%d)", argIdx, argIdx+1))
		args = append(args, cursor.CreatedAt, cursor.ID)
		argIdx += 2
	}

	for _, f := range params.Filters {
		clause, err := buildFilterClause(f, argIdx)
		if err != nil {
			return nil, fmt.Errorf("list entities: build filter: %w", err)
		}
		whereParts = append(whereParts, clause)
		args = append(args, f.Value)
		argIdx++
	}

	whereClause := strings.Join(whereParts, " AND ")

	dataQuery := fmt.Sprintf(`
		SELECT id, schema_id, name, type, region, data_residency_zone,
		       status, version, attributes, metadata, created_at, updated_at, deleted_at
		FROM entities WHERE %s ORDER BY created_at DESC, id DESC LIMIT $%d
	`, whereClause, argIdx)
	argsData := append(args, params.Limit)

	entities, err := r.scanEntities(ctx, dataQuery, argsData...)
	if err != nil {
		return nil, fmt.Errorf("list entities: query: %w", err)
	}

	countQuery := fmt.Sprintf(`SELECT COUNT(*) FROM entities WHERE %s`, whereClause)
	var totalCount int
	if err := r.executor(ctx).QueryRow(ctx, countQuery, args...).Scan(&totalCount); err != nil {
		return nil, fmt.Errorf("list entities: count: %w", err)
	}

	return &domain.PaginatedResult{
		Entities:   entities,
		TotalCount: totalCount,
	}, nil
}

func decodeCursorToken(token string) (domain.Cursor, error) {
	decoded, err := base64.StdEncoding.DecodeString(token)
	if err != nil {
		return domain.Cursor{}, fmt.Errorf("%w: base64 decode: %w", domain.ErrInvalidCursor, err)
	}
	parts := strings.SplitN(string(decoded), "|", 2)
	if len(parts) != 2 {
		return domain.Cursor{}, domain.ErrInvalidCursor
	}
	createdAt, err := time.Parse(time.RFC3339Nano, parts[0])
	if err != nil {
		return domain.Cursor{}, fmt.Errorf("%w: parse timestamp: %w", domain.ErrInvalidCursor, err)
	}
	return domain.Cursor{CreatedAt: createdAt, ID: parts[1]}, nil
}

func buildFilterClause(f domain.Filter, argIdx int) (string, error) {
	field := mapFilterField(f.Field)
	switch f.Op {
	case domain.FilterOpEqual:
		return fmt.Sprintf("%s = $%d", field, argIdx), nil
	case domain.FilterOpNotEqual:
		return fmt.Sprintf("%s != $%d", field, argIdx), nil
	case domain.FilterOpContains:
		return fmt.Sprintf("%s ILIKE '%%' || $%d || '%%'", field, argIdx), nil
	case domain.FilterOpGreaterThan:
		return fmt.Sprintf("%s > $%d", field, argIdx), nil
	case domain.FilterOpLessThan:
		return fmt.Sprintf("%s < $%d", field, argIdx), nil
	default:
		return "", fmt.Errorf("%w: unknown operator %q", domain.ErrInvalidFilter, f.Op)
	}
}

func mapFilterField(field string) string {
	switch field {
	case "id", "name", "type", "region", "status", "version":
		return field
	case "data_residency_zone", "zone":
		return "data_residency_zone"
	default:
		return fmt.Sprintf("attributes->>'%s'", field)
	}
}

func (r *EntityRepository) exists(ctx context.Context, id string) (bool, error) {
	var exists bool
	if err := r.executor(ctx).QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM entities WHERE id = $1)`, id).Scan(&exists); err != nil {
		return false, fmt.Errorf("entity exists check: %w", err)
	}
	return exists, nil
}

func (r *EntityRepository) scanEntity(_ context.Context, row pgx.Row) (*domain.Entity, error) {
	var (
		id, schemaID, name, etype, region, zone, status string
		version                                         int
		attrsJSON, metaJSON                             []byte
		createdAt, updatedAt                            time.Time
		deletedAt                                       *time.Time
	)
	if err := row.Scan(
		&id, &schemaID, &name, &etype, &region, &zone,
		&status, &version, &attrsJSON, &metaJSON, &createdAt, &updatedAt, &deletedAt,
	); err != nil {
		return nil, err
	}

	attrs := make(map[string]any)
	if len(attrsJSON) > 0 {
		json.Unmarshal(attrsJSON, &attrs)
	}
	meta := make(map[string]any)
	if len(metaJSON) > 0 {
		json.Unmarshal(metaJSON, &meta)
	}

	return &domain.Entity{
		ID: id, SchemaID: schemaID, Name: name, Type: etype,
		Region: region, DataResidencyZone: domain.DataResidencyZone(zone),
		Status: domain.EntityStatus(status), Version: version,
		Attributes: attrs, Metadata: meta,
		CreatedAt: createdAt, UpdatedAt: updatedAt, DeletedAt: deletedAt,
	}, nil
}

func (r *EntityRepository) scanEntities(ctx context.Context, query string, args ...any) ([]*domain.Entity, error) {
	rows, err := r.executor(ctx).Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("query entities: %w", err)
	}
	defer rows.Close()

	var entities []*domain.Entity
	for rows.Next() {
		entity, err := r.scanEntity(ctx, rows)
		if err != nil {
			return nil, fmt.Errorf("scan entity row: %w", err)
		}
		entities = append(entities, entity)
	}
	if entities == nil {
		entities = []*domain.Entity{}
	}
	return entities, rows.Err()
}

var _ domain.EntityRepository = (*EntityRepository)(nil)
