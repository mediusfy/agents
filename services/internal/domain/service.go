package domain

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"

	"github.com/drewjocham/agents/internal/ports"
)

const tracerName = "entity-service.domain"

// EntityService orchestrates entity use cases.
type EntityService struct {
	repo   EntityRepository
	events ports.EventBus
}

// NewEntityService creates a new domain service with its required ports.
func NewEntityService(repo EntityRepository, events ports.EventBus) *EntityService {
	return &EntityService{repo: repo, events: events}
}

// CreateEntity validates input, persists the entity, and publishes a domain event.
func (s *EntityService) CreateEntity(ctx context.Context, input CreateEntityInput) (*Entity, error) {
	ctx, span := otel.Tracer(tracerName).Start(ctx, "domain.EntityService.CreateEntity")
	defer span.End()

	span.SetAttributes(
		attribute.String("entity.name", input.Name),
		attribute.String("entity.type", input.Type),
	)

	if input.Name == "" {
		return nil, fmt.Errorf("%w", ErrNameRequired)
	}

	now := time.Now().UTC()

	entity := &Entity{
		ID:        uuid.NewString(),
		Name:      input.Name,
		Type:      input.Type,
		Version:   1,
		Metadata:  sanitiseMetadata(input.Metadata),
		CreatedAt: now,
		UpdatedAt: now,
	}

	if err := s.repo.Save(ctx, entity); err != nil {
		return nil, fmt.Errorf("persist entity: %w", err)
	}

	slog.InfoContext(ctx, "entity created",
		slog.String("entity_id", entity.ID),
		slog.String("name", entity.Name),
	)

	event := EntityCreatedEvent{Entity: *entity}
	if err := s.events.Publish(ctx, event); err != nil {
		slog.WarnContext(ctx, "failed to publish entity.created event",
			slog.String("entity_id", entity.ID),
			slog.Any("error", err),
		)
	}

	return entity, nil
}

// UpdateEntity validates input, applies changes using optimistic concurrency,
// and publishes a domain event.
func (s *EntityService) UpdateEntity(ctx context.Context, input UpdateEntityInput) (*Entity, error) {
	ctx, span := otel.Tracer(tracerName).Start(ctx, "domain.EntityService.UpdateEntity")
	defer span.End()

	span.SetAttributes(
		attribute.String("entity.id", input.ID),
		attribute.String("entity.name", input.Name),
	)

	if input.ID == "" {
		return nil, fmt.Errorf("%w: id is required", ErrInvalidInput)
	}
	if input.Name == "" {
		return nil, fmt.Errorf("%w: name is required", ErrInvalidInput)
	}

	entity, err := s.repo.FindByID(ctx, input.ID)
	if err != nil {
		return nil, fmt.Errorf("find entity for update: %w", err)
	}
	if entity == nil {
		return nil, fmt.Errorf("%w: %s", ErrEntityNotFound, input.ID)
	}

	entity.Name = input.Name
	entity.Version++
	entity.UpdatedAt = time.Now().UTC()

	if err := s.repo.Update(ctx, entity); err != nil {
		return nil, fmt.Errorf("persist entity update: %w", err)
	}

	slog.InfoContext(ctx, "entity updated",
		slog.String("entity_id", entity.ID),
		slog.Int("version", entity.Version),
	)

	event := EntityUpdatedEvent{
		EntityID: entity.ID,
		Name:     entity.Name,
		Version:  entity.Version,
	}
	if err := s.events.Publish(ctx, event); err != nil {
		slog.WarnContext(ctx, "failed to publish entity.updated event",
			slog.String("entity_id", entity.ID),
			slog.Any("error", err),
		)
	}

	return entity, nil
}

// FindByID retrieves an entity by its unique identifier.
func (s *EntityService) FindByID(ctx context.Context, id string) (*Entity, error) {
	ctx, span := otel.Tracer(tracerName).Start(ctx, "domain.EntityService.FindByID")
	defer span.End()

	span.SetAttributes(attribute.String("entity.id", id))

	entity, err := s.repo.FindByID(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("find entity: %w", err)
	}

	if entity == nil {
		return nil, fmt.Errorf("%w: %s", ErrEntityNotFound, id)
	}

	return entity, nil
}

// GetEntity is an alias for FindByID used by the gRPC handler.
func (s *EntityService) GetEntity(ctx context.Context, id string) (*Entity, error) {
	return s.FindByID(ctx, id)
}

// ListEntities returns a paginated list of entities.
func (s *EntityService) ListEntities(ctx context.Context, input ListInput) (*ListResult, error) {
	ctx, span := otel.Tracer(tracerName).Start(ctx, "domain.EntityService.ListEntities")
	defer span.End()

	span.SetAttributes(
		attribute.Int("page", input.Page),
		attribute.Int("limit", input.Limit),
	)

	if input.Page < 1 {
		input.Page = 1
	}
	if input.Limit < 1 || input.Limit > 100 {
		input.Limit = 20
	}

	result, err := s.repo.List(ctx, input)
	if err != nil {
		return nil, fmt.Errorf("list entities: %w", err)
	}

	span.SetAttributes(attribute.Int("result.count", len(result.Items)))
	slog.DebugContext(ctx, "entities listed",
		slog.Int("total", result.Total),
		slog.Int("returned", len(result.Items)),
	)

	return result, nil
}

func sanitiseMetadata(m map[string]string) map[string]string {
	if m == nil {
		return make(map[string]string)
	}
	return m
}
