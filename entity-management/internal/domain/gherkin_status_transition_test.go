package domain

import (
	"context"
	"errors"
	"testing"
	"time"
)

// Gherkin: Given an entity exists with status "active"
//
//	When a user updates the entity setting status="inactive"
//	Then the transition succeeds
//	  And an entitymanagement.entity.updated event is emitted
//	  with changed_fields including "status"
func TestGherkin_ActiveToInactive_EmitsEventWithChangedFields(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	// Seed schema.
	schemaID := "sch-test"
	_ = schemaRepo.Save(ctx, &EntitySchema{
		ID:   schemaID,
		Name: "Test",
		Attributes: []AttributeDefinition{
			{Name: "email", Type: AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
	})

	// Seed an active entity.
	entity := &Entity{
		ID:       "ent-001",
		SchemaID: schemaID,
		Name:     "TestEntity",
		Status:   EntityStatusActive,
		Version:  1,
		CreatedAt: now,
		UpdatedAt: now,
	}
	_ = entityRepo.Save(ctx, entity)

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	// When updating status to "inactive".
	inactive := EntityStatusInactive
	op := UpdateOperation{
		ExpectedVersion: 1,
		Status:          &inactive,
	}

	updated, err := svc.UpdateEntity(ctx, "ent-001", op)
	if err != nil {
		t.Fatalf("UpdateEntity (active->inactive) failed: %v", err)
	}

	// Then the transition succeeds.
	if updated.Status != EntityStatusInactive {
		t.Errorf("expected status 'inactive', got %q", updated.Status)
	}
	if updated.Version != 2 {
		t.Errorf("expected version 2, got %d", updated.Version)
	}

	// And an entity.updated event is emitted in the outbox.
	if len(outboxRepo.events) != 1 {
		t.Fatalf("expected 1 outbox event, got %d", len(outboxRepo.events))
	}
	if outboxRepo.events[0].EventType != (&EntityUpdated{}).EventName() {
		t.Errorf("expected event type %q, got %q",
			(&EntityUpdated{}).EventName(), outboxRepo.events[0].EventType)
	}

	// And changed_fields includes "status".
	changedFields := op.CollectChangedFields()
	foundStatus := false
	for _, f := range changedFields {
		if f == "status" {
			foundStatus = true
			break
		}
	}
	if !foundStatus {
		t.Errorf("expected changed_fields to include 'status', got %v", changedFields)
	}
}

// Gherkin: Given an entity exists with status "inactive"
//
//	When a user updates the entity setting status="active"
//	Then the transition succeeds
func TestGherkin_InactiveToActive_Succeeds(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	schemaID := "sch-test"
	_ = schemaRepo.Save(ctx, &EntitySchema{
		ID:   schemaID,
		Name: "Test",
		Attributes: []AttributeDefinition{{Name: "email", Type: AttributeTypeString, Required: true}},
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
	})

	entity := &Entity{
		ID:       "ent-002",
		SchemaID: schemaID,
		Name:     "InactiveEntity",
		Status:   EntityStatusInactive,
		Version:  1,
		CreatedAt: now,
		UpdatedAt: now,
	}
	_ = entityRepo.Save(ctx, entity)

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	active := EntityStatusActive
	op := UpdateOperation{
		ExpectedVersion: 1,
		Status:          &active,
	}

	updated, err := svc.UpdateEntity(ctx, "ent-002", op)
	if err != nil {
		t.Fatalf("UpdateEntity (inactive->active) failed: %v", err)
	}
	if updated.Status != EntityStatusActive {
		t.Errorf("expected status 'active', got %q", updated.Status)
	}
	if updated.Version != 2 {
		t.Errorf("expected version 2, got %d", updated.Version)
	}
}

// Gherkin: Given an entity exists with status "active"
//
//	When a soft-delete is performed (via DELETE endpoint)
//	Then the entity status transitions to "deleted" (terminal state)
func TestGherkin_SoftDelete_TransitionsToDeleted(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	schemaID := "sch-test"
	_ = schemaRepo.Save(ctx, &EntitySchema{
		ID:   schemaID,
		Name: "Test",
		Attributes: []AttributeDefinition{{Name: "email", Type: AttributeTypeString, Required: true}},
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
	})

	entity := &Entity{
		ID:       "ent-003",
		SchemaID: schemaID,
		Name:     "ActiveEntity",
		Status:   EntityStatusActive,
		Version:  1,
		CreatedAt: now,
		UpdatedAt: now,
	}
	_ = entityRepo.Save(ctx, entity)

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	// When soft-delete is performed.
	err := svc.SoftDeleteEntity(ctx, "ent-003")
	if err != nil {
		t.Fatalf("SoftDeleteEntity failed: %v", err)
	}

	// Then the entity status transitions to "deleted" (terminal state).
	updated, err := entityRepo.FindByID(ctx, "ent-003")
	if err != nil {
		t.Fatalf("FindByID after soft-delete failed: %v", err)
	}
	if updated.Status != EntityStatusDeleted {
		t.Errorf("expected status 'deleted', got %q", updated.Status)
	}
	if updated.DeletedAt == nil {
		t.Error("expected deleted_at to be set after soft-delete")
	}
	if updated.Version != 2 {
		t.Errorf("expected version 2, got %d", updated.Version)
	}

	// Verify deleted is terminal: no transitions allowed via regular update.
	deletedEntity := updated
	active := EntityStatusActive
	deletedOp := UpdateOperation{
		ExpectedVersion: deletedEntity.Version,
		Status:          &active,
	}
	err = deletedEntity.ApplyUpdate(deletedOp)
	if !errors.Is(err, ErrInvalidStatusTransition) {
		t.Errorf("expected ErrInvalidStatusTransition for updating deleted entity, got %v", err)
	}

	// Verify only the restore endpoint exits the deleted state.
	restoreErr := svc.RestoreEntity(ctx, "ent-003")
	if restoreErr != nil {
		t.Fatalf("RestoreEntity failed: %v", restoreErr)
	}
	restored, _ := entityRepo.FindByID(ctx, "ent-003")
	if restored.Status != EntityStatusActive {
		t.Errorf("expected status 'active' after restore, got %q", restored.Status)
	}
	if restored.DeletedAt != nil {
		t.Error("expected deleted_at to be nil after restore")
	}
}

// Gherkin: Given an entity exists with status "deleted" (after soft-delete)
//
//	When a user attempts a status-only update setting status="active"
//	Then ErrInvalidStatusTransition is returned
//	  And the only way to exit "deleted" is via the restore endpoint
func TestGherkin_Deleted_CannotTransitionViaUpdate_OnlyViaRestore(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	schemaID := "sch-test"
	_ = schemaRepo.Save(ctx, &EntitySchema{
		ID:   schemaID,
		Name: "Test",
		Attributes: []AttributeDefinition{{Name: "email", Type: AttributeTypeString, Required: true}},
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
	})

	// Seed a soft-deleted entity (deleted_at set, status="deleted").
	deletedAt := now.Add(-1 * time.Hour)
	entity := &Entity{
		ID:        "ent-004",
		SchemaID:  schemaID,
		Name:      "DeletedEntity",
		Status:    EntityStatusDeleted,
		DeletedAt: &deletedAt,
		Version:   2,
		CreatedAt: now.Add(-2 * time.Hour),
		UpdatedAt: deletedAt,
	}
	_ = entityRepo.Save(ctx, entity)

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	// When a user attempts a status-only update setting status="active"
	active := EntityStatusActive
	op := UpdateOperation{
		ExpectedVersion: 2,
		Status:          &active,
	}

	_, err := svc.UpdateEntity(ctx, "ent-004", op)
	if err == nil {
		t.Fatal("expected error for updating deleted entity, got nil")
	}

	// Then ErrInvalidStatusTransition is returned.
	if !errors.Is(err, ErrInvalidStatusTransition) {
		t.Errorf("expected ErrInvalidStatusTransition, got %v", err)
	}

	// And no data is modified.
	unchanged, _ := entityRepo.FindByID(ctx, "ent-004")
	if unchanged.Status != EntityStatusDeleted {
		t.Errorf("expected status to remain 'deleted', got %q", unchanged.Status)
	}
	if unchanged.Version != 2 {
		t.Errorf("expected version to remain 2, got %d", unchanged.Version)
	}

	// The only way to exit "deleted" is via the restore endpoint.
	restoreErr := svc.RestoreEntity(ctx, "ent-004")
	if restoreErr != nil {
		t.Fatalf("RestoreEntity failed: %v", restoreErr)
	}
	restored, _ := entityRepo.FindByID(ctx, "ent-004")
	if restored.Status != EntityStatusActive {
		t.Errorf("expected status 'active' after restore, got %q", restored.Status)
	}
	if restored.DeletedAt != nil {
		t.Error("expected deleted_at to be nil after restore")
	}
}

// Gherkin: Given an entity exists with status "inactive"
//
//	When a user attempts to set status to an invalid value "unknown"
//	Then ErrInvalidStatusTransition is returned
//	  And no data is modified
func TestGherkin_InvalidStatus_ReturnsErrorAndNoModification(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	schemaID := "sch-test"
	_ = schemaRepo.Save(ctx, &EntitySchema{
		ID:   schemaID,
		Name: "Test",
		Attributes: []AttributeDefinition{{Name: "email", Type: AttributeTypeString, Required: true}},
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
	})

	entity := &Entity{
		ID:       "ent-005",
		SchemaID: schemaID,
		Name:     "InactiveEntity",
		Status:   EntityStatusInactive,
		Version:  1,
		CreatedAt: now,
		UpdatedAt: now,
	}
	_ = entityRepo.Save(ctx, entity)

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	// When a user attempts to set status to an invalid value "unknown".
	unknown := EntityStatus("unknown")
	op := UpdateOperation{
		ExpectedVersion: 1,
		Status:          &unknown,
	}

	_, err := svc.UpdateEntity(ctx, "ent-005", op)
	if err == nil {
		t.Fatal("expected error for invalid status, got nil")
	}

	// Then ErrInvalidStatusTransition is returned.
	if !errors.Is(err, ErrInvalidStatusTransition) {
		t.Errorf("expected ErrInvalidStatusTransition, got %v", err)
	}

	// And no data is modified.
	unchanged, _ := entityRepo.FindByID(ctx, "ent-005")
	if unchanged.Status != EntityStatusInactive {
		t.Errorf("expected status to remain 'inactive', got %q", unchanged.Status)
	}
	if unchanged.Version != 1 {
		t.Errorf("expected version to remain 1, got %d", unchanged.Version)
	}

	// No outbox events were written.
	if len(outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events for failed update, got %d", len(outboxRepo.events))
	}
}
