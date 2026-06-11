package domain

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// Service implements the core region-resolver business logic.
// All dependencies are injected via constructor (no global state).
type Service struct {
	entities EntityRepository
	events   EventPublisher
	now      func() time.Time
}

// ServiceOption is a functional option for Service construction.
type ServiceOption func(*Service)

// WithClock overrides the default clock for testing.
func WithClock(now func() time.Time) ServiceOption {
	return func(s *Service) { s.now = now }
}

// NewService creates a new region-resolver Service with injected ports.
func NewService(
	entities EntityRepository,
	events EventPublisher,
	opts ...ServiceOption,
) *Service {
	s := &Service{
		entities: entities,
		events:   events,
		now:      time.Now,
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// CreateEntityInput holds parameters for entity creation.
type CreateEntityInput struct {
	Name   string
	Region string
	Labels map[string]string
}

// CreateEntityResult wraps the outcome of entity creation.
type CreateEntityResult struct {
	Entity  *Entity
	EventID string
}

// CreateEntity creates a new entity, resolves its data residency zone from
// the region, persists it, and publishes a domain event.
//
// Gherkin compliance:
//   - Entity.DataResidencyZone is resolved via ResolveZone(region)
//   - Observability spans include the region attribute
func (s *Service) CreateEntity(ctx context.Context, input CreateEntityInput) (*CreateEntityResult, error) {
	if input.Name == "" {
		return nil, fmt.Errorf("create entity: %w: name is required", ErrInvalidEntity)
	}
	if input.Region == "" {
		return nil, fmt.Errorf("create entity: %w: region is required", ErrInvalidEntity)
	}

	now := s.now()
	eventID := uuid.New().String()

	entity := &Entity{
		ID:                uuid.New().String(),
		Name:              input.Name,
		Region:            input.Region,
		DataResidencyZone: ResolveZone(input.Region),
		Status:            EntityStatusActive,
		Version:           1,
		Labels:            input.Labels,
		CreatedAt:         now,
		UpdatedAt:         now,
	}

	if err := s.entities.Save(ctx, entity); err != nil {
		return nil, fmt.Errorf("create entity: save: %w", err)
	}

	event := &EntityCreated{
		EventID:           eventID,
		EntityID:          entity.ID,
		EntityName:        entity.Name,
		Region:            entity.Region,
		DataResidencyZone: entity.DataResidencyZone,
		OccurredAt:        now,
	}
	if err := s.events.PublishEntityCreated(ctx, event); err != nil {
		// Non-blocking: event publishing failures MUST NOT break the
		// create operation. Logging is handled by the caller.
		_ = err
	}

	return &CreateEntityResult{
		Entity:  entity,
		EventID: eventID,
	}, nil
}

// GetEntity retrieves an entity by its unique ID.
func (s *Service) GetEntity(ctx context.Context, id string) (*Entity, error) {
	if id == "" {
		return nil, fmt.Errorf("get entity: %w: id is required", ErrInvalidEntity)
	}

	entity, err := s.entities.FindByID(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("get entity: %w", err)
	}
	return entity, nil
}

// UpdateEntity applies a partial update to an existing entity. It enforces
// immutable field protection and optimistic concurrency.
//
// Gherkin compliance:
//   - If data_residency_zone is in the update, ErrImmutableField is returned
//   - Expected version mismatch returns ErrStaleVersion
//   - On success, version is incremented and an EntityUpdated event is published
func (s *Service) UpdateEntity(ctx context.Context, id string, op UpdateOperation) (*Entity, error) {
	entity, err := s.entities.FindByID(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("update entity: %w", err)
	}

	previousVersion := entity.Version
	changedFields := op.CollectChangedFields()

	if err := entity.ApplyUpdate(op); err != nil {
		return nil, fmt.Errorf("update entity: %w", err)
	}

	if err := s.entities.Update(ctx, entity); err != nil {
		return nil, fmt.Errorf("update entity: persist: %w", err)
	}

	eventID := uuid.New().String()
	event := &EntityUpdated{
		EventID:         eventID,
		EntityID:        entity.ID,
		EntityName:      entity.Name,
		PreviousVersion: previousVersion,
		NewVersion:      entity.Version,
		ChangedFields:   changedFields,
		OccurredAt:      s.now(),
	}
	if err := s.events.PublishEntityUpdated(ctx, event); err != nil {
		_ = err
	}

	return entity, nil
}

// DeleteEntity deletes an entity by its ID.
func (s *Service) DeleteEntity(ctx context.Context, id string) error {
	entity, err := s.entities.FindByID(ctx, id)
	if err != nil {
		return fmt.Errorf("delete entity: %w", err)
	}

	if err := s.entities.Delete(ctx, id); err != nil {
		return fmt.Errorf("delete entity: %w", err)
	}

	event := &EntityDeleted{
		EventID:    uuid.New().String(),
		EntityID:   entity.ID,
		EntityName: entity.Name,
		Region:     entity.Region,
		OccurredAt: s.now(),
	}
	if err := s.events.PublishEntityDeleted(ctx, event); err != nil {
		_ = err
	}

	return nil
}

// ListEntities returns all entities from the repository.
func (s *Service) ListEntities(ctx context.Context) ([]*Entity, error) {
	return s.entities.List(ctx)
}
