package application

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/domain"
)

type ListEntitiesRequest struct {
	SchemaID       string   `json:"schema_id"`
	Limit          int      `json:"limit"`
	Cursor         string   `json:"cursor,omitempty"`
	Filters        []string `json:"filters,omitempty"`
	IncludeDeleted bool     `json:"include_deleted,omitempty"`
	RequestOrigin  string   `json:"request_origin,omitempty"`
}

type ListEntitiesResponse struct {
	Entities   []*EntityListItem `json:"entities"`
	NextCursor string            `json:"next_cursor,omitempty"`
	TotalCount int               `json:"total_count"`
}

type EntityListItem struct {
	ID        string     `json:"id"`
	SchemaID  string     `json:"schema_id"`
	Name      string     `json:"name"`
	Type      string     `json:"type"`
	Region    string     `json:"region"`
	Status    string     `json:"status"`
	CreatedAt time.Time  `json:"created_at"`
	UpdatedAt time.Time  `json:"updated_at"`
	DeletedAt *time.Time `json:"deleted_at,omitempty"`
}

type ListEntitiesUseCase struct {
	entities domain.EntityRepository
	events   domain.EventPublisher
	logger   *slog.Logger
	tracer   trace.Tracer
}

func NewListEntitiesUseCase(
	entities domain.EntityRepository,
	events domain.EventPublisher,
	logger *slog.Logger,
) *ListEntitiesUseCase {
	return &ListEntitiesUseCase{
		entities: entities,
		events:   events,
		logger:   logger.With("component", "ListEntitiesUseCase"),
		tracer:   otel.Tracer(tracerName),
	}
}

func (uc *ListEntitiesUseCase) Execute(ctx context.Context, req ListEntitiesRequest) (*ListEntitiesResponse, error) {
	startTime := time.Now()
	ctx, span := uc.tracer.Start(ctx, "application.ListEntitiesUseCase.Execute",
		trace.WithAttributes(
			attribute.String("schema_id", req.SchemaID),
			attribute.Int("limit", req.Limit),
			attribute.Bool("has_cursor", req.Cursor != ""),
			attribute.Int("filter_count", len(req.Filters)),
			attribute.Bool("include_deleted", req.IncludeDeleted),
		))
	defer span.End()

	filters := make([]domain.Filter, 0, len(req.Filters))
	for _, raw := range req.Filters {
		f, err := domain.ParseFilter(raw)
		if err != nil {
			span.RecordError(err)
			return nil, fmt.Errorf("parse filter %q: %w", raw, err)
		}
		filters = append(filters, f)
	}

	limit := req.Limit
	if limit <= 0 {
		limit = 1
	}
	if limit > 100 {
		limit = 100
	}

	params := domain.ListEntitiesParams{
		SchemaID:       req.SchemaID,
		Limit:          limit + 1,
		Cursor:         req.Cursor,
		Filters:        filters,
		IncludeDeleted: req.IncludeDeleted,
	}

	result, err := uc.entities.ListEntities(ctx, params)
	if err != nil {
		span.RecordError(err)
		if errors.Is(err, domain.ErrInvalidCursor) {
			uc.publishInvalidCursorEvent(ctx, req)
		}
		return nil, fmt.Errorf("list entities: %w", err)
	}

	var nextCursor string
	entities := result.Entities
	if len(entities) > limit {
		last := entities[limit-1]
		entities = entities[:limit]
		nextCursor = encodeCursor(last.CreatedAt, last.ID)
	}

	items := make([]*EntityListItem, 0, len(entities))
	for _, e := range entities {
		items = append(items, &EntityListItem{
			ID:        e.ID,
			SchemaID:  e.SchemaID,
			Name:      e.Name,
			Type:      e.Type,
			Region:    e.Region,
			Status:    string(e.Status),
			CreatedAt: e.CreatedAt,
			UpdatedAt: e.UpdatedAt,
			DeletedAt: e.DeletedAt,
		})
	}

	hasNextPage := nextCursor != ""
	durationMs := int(time.Since(startTime).Milliseconds())

	span.SetAttributes(
		attribute.Int("result_count", len(items)),
		attribute.Bool("has_next_page", hasNextPage),
		attribute.Int("duration_ms", durationMs),
	)

	uc.publishEntitiesQueriedEvent(ctx, req, limit, hasNextPage, result.TotalCount, durationMs)

	return &ListEntitiesResponse{
		Entities:   items,
		NextCursor: nextCursor,
		TotalCount: result.TotalCount,
	}, nil
}

func (uc *ListEntitiesUseCase) publishEntitiesQueriedEvent(
	ctx context.Context,
	req ListEntitiesRequest,
	limit int,
	hasNextPage bool,
	totalCount int,
	durationMs int,
) {
	event := &domain.EntitiesQueried{
		EventID:        uuid.New().String(),
		SchemaID:       req.SchemaID,
		Limit:          limit,
		FiltersApplied: req.Filters,
		HasCursor:      req.Cursor != "",
		HasNextPage:    hasNextPage,
		TotalCount:     totalCount,
		DurationMs:     durationMs,
		OccurredAt:     time.Now().UTC(),
	}
	if err := uc.events.PublishEntitiesQueried(ctx, event); err != nil {
		uc.logger.WarnContext(ctx, "failed to publish entities.queried event", "schema_id", req.SchemaID, "error", err)
	}
}

func (uc *ListEntitiesUseCase) publishInvalidCursorEvent(ctx context.Context, req ListEntitiesRequest) {
	event := &domain.InvalidCursorProvided{
		EventID:        uuid.New().String(),
		ProvidedCursor: req.Cursor,
		SchemaID:       req.SchemaID,
		ErrorDetail:    "invalid cursor token",
		RequestOrigin:  req.RequestOrigin,
		OccurredAt:     time.Now().UTC(),
	}
	if err := uc.events.PublishInvalidCursorProvided(ctx, event); err != nil {
		uc.logger.WarnContext(ctx, "failed to publish invalid_cursor event", "schema_id", req.SchemaID, "error", err)
	}
}

func encodeCursor(createdAt time.Time, id string) string {
	data := []byte(createdAt.UTC().Format(time.RFC3339Nano) + "|" + id)
	return base64.StdEncoding.EncodeToString(data)
}
