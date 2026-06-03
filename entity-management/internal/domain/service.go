package domain

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type RequestIdempotencyStore interface {
	GetEntityID(ctx context.Context, requestKey string) (string, error)
	Save(ctx context.Context, requestKey, entityID string, ttl time.Duration) error
}

type UnitOfWork interface {
	Execute(ctx context.Context, fn func(uowCtx context.Context) error) error
}

type Service struct {
	schemas        SchemaRepository
	entities       EntityRepository
	outbox         OutboxRepository
	idempotency    RequestIdempotencyStore
	events         EventPublisher
	uow            UnitOfWork
	now            func() time.Time
	idempotencyTTL time.Duration
}

type ServiceOption func(*Service)

func WithClock(now func() time.Time) ServiceOption {
	return func(s *Service) { s.now = now }
}

func WithIdempotencyTTL(ttl time.Duration) ServiceOption {
	return func(s *Service) { s.idempotencyTTL = ttl }
}

func WithEvents(events EventPublisher) ServiceOption {
	return func(s *Service) { s.events = events }
}

func NewService(
	schemas SchemaRepository,
	entities EntityRepository,
	outbox OutboxRepository,
	idempotency RequestIdempotencyStore,
	uow UnitOfWork,
	opts ...ServiceOption,
) *Service {
	s := &Service{
		schemas:         schemas,
		entities:        entities,
		outbox:          outbox,
		idempotency:     idempotency,
		uow:             uow,
		now:             time.Now,
		idempotencyTTL:  7 * 24 * time.Hour,
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

type CreateEntityInput struct {
	SchemaID       string
	Name           string
	Type           string
	Region         string
	Attributes     map[string]any
	Metadata       map[string]any
	IdempotencyKey string
}

type CreateEntityResult struct {
	Entity  *Entity
	Created bool
	EventID string
}

func (s *Service) CreateEntity(ctx context.Context, input CreateEntityInput) (*CreateEntityResult, error) {
	if input.IdempotencyKey != "" {
		existingEntityID, err := s.idempotency.GetEntityID(ctx, input.IdempotencyKey)
		if err != nil {
			return nil, fmt.Errorf("idempotency lookup: %w", err)
		}
		if existingEntityID != "" {
			entity, err := s.entities.FindByID(ctx, existingEntityID)
			if err != nil {
				return nil, fmt.Errorf("idempotent entity lookup: %w", err)
			}
			return &CreateEntityResult{Entity: entity, Created: false}, nil
		}
	}

	schema, err := s.schemas.FindByID(ctx, input.SchemaID)
	if err != nil {
		return nil, fmt.Errorf("schema lookup: %w", err)
	}

	if err := validateAgainstSchema(schema, input.Attributes); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrValidationFailed, err)
	}

	now := s.now()
	entityID := uuid.New().String()
	eventID := uuid.New().String()

	entity := &Entity{
		ID:                entityID,
		SchemaID:          input.SchemaID,
		Name:              input.Name,
		Type:              input.Type,
		Region:            input.Region,
		DataResidencyZone: ResolveZone(input.Region),
		Status:            EntityStatusActive,
		Version:           1,
		Attributes:        input.Attributes,
		Metadata:          input.Metadata,
		CreatedAt:         now,
		UpdatedAt:         now,
	}

	outboxEvent := &OutboxEvent{
		ID:            uuid.New().String(),
		AggregateID:   entityID,
		AggregateType: "entity",
		EventType:     (&EntityCreated{}).EventName(),
		Payload:       marshalEntityCreated(eventID, entityID, input.Name, input.Type, input.Region, now),
		Status:        OutboxStatusPending,
		CreatedAt:     now,
	}

	if err := s.uow.Execute(ctx, func(uowCtx context.Context) error {
		if err := s.entities.Save(uowCtx, entity); err != nil {
			return fmt.Errorf("save entity: %w", err)
		}
		if err := s.outbox.Save(uowCtx, outboxEvent); err != nil {
			return fmt.Errorf("save outbox event: %w", err)
		}
		return nil
	}); err != nil {
		return nil, err
	}

	if input.IdempotencyKey != "" {
		if err := s.idempotency.Save(ctx, input.IdempotencyKey, entityID, s.idempotencyTTL); err != nil {
			return nil, fmt.Errorf("save idempotency key: %w", err)
		}
	}

	return &CreateEntityResult{Entity: entity, Created: true, EventID: eventID}, nil
}

func (s *Service) UpdateEntity(ctx context.Context, id string, op UpdateOperation) (*Entity, error) {
	entity, err := s.entities.FindByID(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("find entity: %w", err)
	}

	changedFields := op.CollectChangedFields()

	if err := entity.ApplyUpdate(op); err != nil {
		return nil, err
	}

	eventID := uuid.New().String()
	outboxEvent := &OutboxEvent{
		ID:            uuid.New().String(),
		AggregateID:   id,
		AggregateType: "entity",
		EventType:     (&EntityUpdated{}).EventName(),
		Payload:       mountEntityUpdatedPayload(eventID, entity, op.ExpectedVersion, entity.Version, changedFields),
		Status:        OutboxStatusPending,
		CreatedAt:     s.now(),
	}

	if err := s.uow.Execute(ctx, func(uowCtx context.Context) error {
		if _, err := s.entities.Update(uowCtx, id, op); err != nil {
			return fmt.Errorf("persist update: %w", err)
		}
		if err := s.outbox.Save(uowCtx, outboxEvent); err != nil {
			return fmt.Errorf("save outbox event: %w", err)
		}
		return nil
	}); err != nil {
		return nil, err
	}

	return entity, nil
}

func (s *Service) SoftDeleteEntity(ctx context.Context, id string) error {
	entity, err := s.entities.FindByID(ctx, id)
	if err != nil {
		return fmt.Errorf("find entity: %w", err)
	}

	now := s.now()

	if err := entity.MarkDeleted(now); err != nil {
		return fmt.Errorf("soft delete: %w", err)
	}

	event := &EntitySoftDeleted{
		EventID:    uuid.New().String(),
		EntityID:   entity.ID,
		EntityName: entity.Name,
		Region:     entity.Region,
		DeletedAt:  now,
		OccurredAt: now,
	}

	outboxEvent := &OutboxEvent{
		ID:            uuid.New().String(),
		AggregateID:   id,
		AggregateType: "entity",
		EventType:     event.EventName(),
		Payload:       marshalEntitySoftDeleted(event),
		Status:        OutboxStatusPending,
		CreatedAt:     now,
	}

	if err := s.uow.Execute(ctx, func(uowCtx context.Context) error {
		if err := s.entities.SoftDelete(uowCtx, id, now); err != nil {
			return fmt.Errorf("soft delete persist: %w", err)
		}
		if err := s.outbox.Save(uowCtx, outboxEvent); err != nil {
			return fmt.Errorf("save outbox event: %w", err)
		}
		return nil
	}); err != nil {
		return err
	}

	if s.events != nil {
		_ = s.events.PublishEntitySoftDeleted(ctx, event)
	}

	return nil
}

func (s *Service) HardDeleteEntity(ctx context.Context, id string) error {
	entity, err := s.entities.FindByID(ctx, id)
	if err != nil {
		return fmt.Errorf("find entity: %w", err)
	}
	if !entity.IsSoftDeleted() {
		return fmt.Errorf("hard delete: %w", ErrNotDeleted)
	}

	now := s.now()

	event := &EntityHardDeleted{
		EventID:    uuid.New().String(),
		EntityID:   entity.ID,
		EntityName: entity.Name,
		Region:     entity.Region,
		DeletedAt:  *entity.DeletedAt,
		OccurredAt: now,
	}

	outboxEvent := &OutboxEvent{
		ID:            uuid.New().String(),
		AggregateID:   id,
		AggregateType: "entity",
		EventType:     event.EventName(),
		Payload:       mountEntityHardDeletedPayload(event),
		Status:        OutboxStatusPending,
		CreatedAt:     now,
	}

	if err := s.uow.Execute(ctx, func(uowCtx context.Context) error {
		if err := s.entities.HardDelete(uowCtx, id); err != nil {
			return fmt.Errorf("hard delete persist: %w", err)
		}
		if err := s.outbox.Save(uowCtx, outboxEvent); err != nil {
			return fmt.Errorf("save outbox event: %w", err)
		}
		return nil
	}); err != nil {
		return err
	}

	if s.events != nil {
		_ = s.events.PublishEntityHardDeleted(ctx, event)
	}

	return nil
}

func (s *Service) RestoreEntity(ctx context.Context, id string) error {
	entity, err := s.entities.FindByID(ctx, id)
	if err != nil {
		return fmt.Errorf("find entity: %w", err)
	}
	if !entity.IsSoftDeleted() {
		return fmt.Errorf("restore: %w", ErrNotDeleted)
	}

	now := s.now()
	entity.ApplyRestore(now)

	event := &EntityRestored{
		EventID:    uuid.New().String(),
		EntityID:   entity.ID,
		EntityName: entity.Name,
		Region:     entity.Region,
		OccurredAt: now,
	}

	outboxEvent := &OutboxEvent{
		ID:            uuid.New().String(),
		AggregateID:   id,
		AggregateType: "entity",
		EventType:     event.EventName(),
		Payload:       mountEntityRestoredPayload(event),
		Status:        OutboxStatusPending,
		CreatedAt:     now,
	}

	if err := s.uow.Execute(ctx, func(uowCtx context.Context) error {
		if err := s.entities.Restore(uowCtx, id); err != nil {
			return fmt.Errorf("restore persist: %w", err)
		}
		if err := s.outbox.Save(uowCtx, outboxEvent); err != nil {
			return fmt.Errorf("save outbox event: %w", err)
		}
		return nil
	}); err != nil {
		return err
	}

	if s.events != nil {
		_ = s.events.PublishEntityRestored(ctx, event)
	}

	return nil
}

func mountEntityUpdatedPayload(eventID string, entity *Entity, prevVer, newVer int, changedFields []string) []byte {
	return []byte(fmt.Sprintf(
		`{"event_id":"%s","entity_id":"%s","entity_name":"%s","status":"%s","region":"%s","previous_version":%d,"new_version":%d,"changed_fields":%q,"occurred_at":"%s"}`,
		eventID, entity.ID, entity.Name, entity.Status, entity.Region,
		prevVer, newVer, changedFields,
		entity.UpdatedAt.Format(time.RFC3339Nano),
	))
}

func marshalEntitySoftDeleted(event *EntitySoftDeleted) []byte {
	return []byte(fmt.Sprintf(
		`{"event_id":"%s","entity_id":"%s","entity_name":"%s","region":"%s","deleted_at":"%s","occurred_at":"%s"}`,
		event.EventID, event.EntityID, event.EntityName, event.Region,
		event.DeletedAt.Format(time.RFC3339Nano),
		event.OccurredAt.Format(time.RFC3339Nano),
	))
}

func mountEntityHardDeletedPayload(event *EntityHardDeleted) []byte {
	return []byte(fmt.Sprintf(
		`{"event_id":"%s","entity_id":"%s","entity_name":"%s","region":"%s","deleted_at":"%s","occurred_at":"%s"}`,
		event.EventID, event.EntityID, event.EntityName, event.Region,
		event.DeletedAt.Format(time.RFC3339Nano),
		event.OccurredAt.Format(time.RFC3339Nano),
	))
}

func mountEntityRestoredPayload(event *EntityRestored) []byte {
	return []byte(fmt.Sprintf(
		`{"event_id":"%s","entity_id":"%s","entity_name":"%s","region":"%s","occurred_at":"%s"}`,
		event.EventID, event.EntityID, event.EntityName, event.Region,
		event.OccurredAt.Format(time.RFC3339Nano),
	))
}

func validateAgainstSchema(schema *EntitySchema, attrs map[string]any) error {
	if attrs == nil {
		attrs = make(map[string]any)
	}

	for _, attr := range schema.Attributes {
		val, exists := attrs[attr.Name]

		if attr.Required && !exists {
			return fmt.Errorf("%w: %q", ErrMissingRequiredAttr, attr.Name)
		}

		if !exists {
			continue
		}

		if err := validateAttributeType(attr.Type, val); err != nil {
			return fmt.Errorf("attribute %q: %w", attr.Name, err)
		}

		if attr.Constraint != nil {
			if err := validateConstraint(attr.Constraint, val); err != nil {
				return fmt.Errorf("attribute %q: %w", attr.Name, err)
			}
		}
	}

	return nil
}

func validateAttributeType(expected AttributeType, val any) error {
	if val == nil {
		return nil
	}
	switch expected {
	case AttributeTypeString:
		if _, ok := val.(string); !ok {
			return fmt.Errorf("expected string, got %T", val)
		}
	case AttributeTypeInt:
		switch val.(type) {
		case int, int32, int64, float64:
			return nil
		default:
			return fmt.Errorf("expected int, got %T", val)
		}
	case AttributeTypeBool:
		if _, ok := val.(bool); !ok {
			return fmt.Errorf("expected bool, got %T", val)
		}
	case AttributeTypeEnum:
		if _, ok := val.(string); !ok {
			return fmt.Errorf("expected string for enum, got %T", val)
		}
	case AttributeTypeJSON, AttributeTypeMap:
		return nil
	}
	return nil
}

func validateConstraint(c *Constraint, val any) error {
	if len(c.Enum) > 0 {
		str, ok := val.(string)
		if !ok {
			return nil
		}
		for _, e := range c.Enum {
			if str == e {
				return nil
			}
		}
		return fmt.Errorf("value %q not in allowed enum set %v", str, c.Enum)
	}
	return nil
}

func marshalEntityCreated(eventID, entityID, entityName, entityType, region string, occurredAt time.Time) []byte {
	return []byte(fmt.Sprintf(
		`{"event_id":"%s","entity_id":"%s","entity_name":"%s","entity_type":"%s","region":"%s","occurred_at":"%s"}`,
		eventID, entityID, entityName, entityType,
		region, occurredAt.Format(time.RFC3339Nano),
	))
}
