package domain

import (
	"context"
	"fmt"
	"time"

	"entity-management/internal/ports"

	cloudevents "github.com/cloudevents/sdk-go/v2/event"
	"github.com/google/uuid"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("domain.Service")

// Service orchestrates entity hard-deletion business logic.
type Service struct {
	repo     ports.Repository
	eventBus ports.EventBus
}

// NewService injects the repository and event bus ports.
func NewService(repo ports.Repository, eventBus ports.EventBus) *Service {
	return &Service{repo: repo, eventBus: eventBus}
}

// HardDelete performs the complete hard-delete workflow:
//  1. Load the entity — return ErrNotFound if absent.
//  2. Verify the entity is soft-deleted — return ErrNotDeleted if active.
//  3. Permanently delete the row (committed atomically with an outbox entry).
//  4. Publish the CloudEvent to the message bus.
//
// Returns the deleted entity on success.
func (s *Service) HardDelete(ctx context.Context, id string) (*Entity, error) {
	ctx, span := tracer.Start(ctx, "domain.Service.HardDelete",
		trace.WithAttributes(attribute.String("entity.id", id)))
	defer span.End()

	// --- Step 1: Load ---
	entity, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("load entity: %w", err)
	}

	// --- Step 2: Guard ---
	if !entity.IsSoftDeleted() {
		span.SetAttributes(attribute.String("outcome", "rejected_not_deleted"))
		return nil, ErrNotDeleted
	}

	// --- Step 3: Hard delete (includes outbox insert) ---
	if err := s.repo.HardDelete(ctx, entity); err != nil {
		return nil, fmt.Errorf("hard delete: %w", err)
	}

	// --- Step 4: Publish CloudEvent ---
	ce, err := s.buildHardDeletedEvent(entity)
	if err != nil {
		return nil, fmt.Errorf("build event: %w", err)
	}
	if err := s.eventBus.Publish(ctx, *ce); err != nil {
		// Non-fatal — the outbox ensures eventual delivery.
		span.RecordError(err)
	}

	span.SetAttributes(attribute.String("outcome", "hard_deleted"))
	return entity, nil
}

func (s *Service) buildHardDeletedEvent(entity *Entity) (*cloudevents.Event, error) {
	ce := cloudevents.New()
	ce.SetID(uuid.New().String())
	ce.SetSource("entity-management")
	ce.SetSubject(string(SubjectEntityHardDeleted))
	ce.SetType("entitymanagement.entity.hard_deleted")
	ce.SetTime(time.Now().UTC())
	ce.SetDataContentType("application/json")
	if err := ce.SetData("application/json", EntityHardDeletedEvent{
		EntityID: entity.ID,
	}); err != nil {
		return nil, err
	}
	return &ce, nil
}
