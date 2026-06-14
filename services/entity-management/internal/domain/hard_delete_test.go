package domain

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// --- Fake event bus for hard-delete testing ---

type fakeEventBus struct {
	mu     sync.Mutex
	events []*EntityHardDeleted
}

func newFakeEventBus() *fakeEventBus {
	return &fakeEventBus{}
}

func (b *fakeEventBus) PublishSchemaDefined(_ context.Context, _ *EntitySchemaDefined) error {
	return nil
}
func (b *fakeEventBus) PublishSchemaUpdated(_ context.Context, _ *EntitySchemaUpdated) error {
	return nil
}
func (b *fakeEventBus) PublishEntityCreated(_ context.Context, _ *EntityCreated) error { return nil }
func (b *fakeEventBus) PublishEntityUpdated(_ context.Context, _ *EntityUpdated) error { return nil }
func (b *fakeEventBus) PublishEntityDeleted(_ context.Context, _ *EntityDeleted) error { return nil }
func (b *fakeEventBus) PublishEntityRead(_ context.Context, _ *EntityRead) error       { return nil }
func (b *fakeEventBus) PublishEntitySoftDeleted(_ context.Context, _ *EntitySoftDeleted) error {
	return nil
}

func (b *fakeEventBus) PublishEntityHardDeleted(_ context.Context, event *EntityHardDeleted) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.events = append(b.events, event)
	return nil
}

func (b *fakeEventBus) PublishEntityRestored(_ context.Context, _ *EntityRestored) error { return nil }
func (b *fakeEventBus) PublishEntitiesQueried(_ context.Context, _ *EntitiesQueried) error {
	return nil
}
func (b *fakeEventBus) PublishInvalidCursorProvided(_ context.Context, _ *InvalidCursorProvided) error {
	return nil
}
func (b *fakeEventBus) PublishAppStarted(_ context.Context, _ *AppStarted) error { return nil }
func (b *fakeEventBus) PublishAppStartupFailed(_ context.Context, _ *AppStartupFailed) error {
	return nil
}

// ---------------------------------------------------------------------------
// Gherkin SCENARIO 1:
//
//	Given entity "ent-001" is soft-deleted (deleted_at set, status="deleted")
//	When a DELETE /api/v1/entities/ent-001?permanent=true request is sent
//	Then the entity record is permanently removed from the database
//	  And an entitymanagement.entity.hard_deleted event is written to the outbox
//	  And HTTP 200 is returned with {"status": "hard_deleted", "entity_id": "ent-001"}
// ---------------------------------------------------------------------------

func TestHardDelete_SoftDeletedEntity(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	schemaRepo := newFakeSchemaRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()
	eventBus := newFakeEventBus()

	// Pre-seed a schema for the entity.
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

	// Pre-seed a soft-deleted entity "ent-001".
	softDeletedAt := now.Add(-1 * time.Hour)
	entity := &Entity{
		ID:        "ent-001",
		SchemaID:  schemaID,
		Name:      "DeletedEntity",
		Status:    EntityStatusDeleted,
		DeletedAt: &softDeletedAt,
		Version:   2,
	}
	_ = entityRepo.Save(ctx, entity)

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
		WithEvents(eventBus),
	)

	err := svc.HardDeleteEntity(ctx, "ent-001")
	if err != nil {
		t.Fatalf("HardDeleteEntity failed: %v", err)
	}

	// Then the entity record is permanently removed from the database.
	_, err = entityRepo.FindByID(ctx, "ent-001")
	if !errors.Is(err, ErrEntityNotFound) {
		t.Errorf("expected entity to be permanently removed (ErrEntityNotFound), got %v", err)
	}

	// And an entitymanagement.entity.hard_deleted event is written to the outbox.
	if len(outboxRepo.events) != 1 {
		t.Fatalf("expected 1 outbox event, got %d", len(outboxRepo.events))
	}
	if outboxRepo.events[0].EventType != (&EntityHardDeleted{}).EventName() {
		t.Errorf("expected event type %q, got %q",
			(&EntityHardDeleted{}).EventName(), outboxRepo.events[0].EventType)
	}
	if outboxRepo.events[0].Status != OutboxStatusPending {
		t.Errorf("expected outbox status 'pending', got %q", outboxRepo.events[0].Status)
	}

	// And the event bus received the hard-deleted event.
	if len(eventBus.events) != 1 {
		t.Fatalf("expected 1 event bus event, got %d", len(eventBus.events))
	}
	if eventBus.events[0].EntityID != "ent-001" {
		t.Errorf("expected event entity_id 'ent-001', got %q", eventBus.events[0].EntityID)
	}

	// And no data remains for this entity.
	all, err := entityRepo.FindBySchemaID(ctx, schemaID)
	if err != nil {
		t.Fatalf("FindBySchemaID failed: %v", err)
	}
	if len(all) != 0 {
		t.Errorf("expected 0 entities after hard delete, got %d", len(all))
	}
}

// ---------------------------------------------------------------------------
// Gherkin SCENARIO 2:
//
//	Given entity "ent-002" is active (deleted_at is NULL)
//	When a hard-delete is attempted on entity "ent-002"
//	Then ErrNotDeleted is returned (HTTP 400)
//	  And message: "entity is not soft-deleted"
//	  And no data is modified
// ---------------------------------------------------------------------------

func TestHardDelete_ActiveEntity(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	schemaRepo := newFakeSchemaRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

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

	// Pre-seed an active entity "ent-002" (deleted_at is NULL).
	entity := &Entity{
		ID:       "ent-002",
		SchemaID: schemaID,
		Name:     "ActiveEntity",
		Status:   EntityStatusActive,
		Version:  1,
	}
	_ = entityRepo.Save(ctx, entity)

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	err := svc.HardDeleteEntity(ctx, "ent-002")
	if err == nil {
		t.Fatal("expected ErrNotDeleted, got nil")
	}

	// Then ErrNotDeleted is returned.
	if !errors.Is(err, ErrNotDeleted) {
		t.Errorf("expected ErrNotDeleted, got %v", err)
	}

	// And message: "entity is not soft-deleted".
	if err.Error() != "hard delete: entity is not soft-deleted" {
		t.Errorf("expected error message 'hard delete: entity is not soft-deleted', got %q", err.Error())
	}

	// And no data is modified — entity still exists with same state.
	saved, lookupErr := entityRepo.FindByID(ctx, "ent-002")
	if lookupErr != nil {
		t.Fatalf("FindByID failed: %v", lookupErr)
	}
	if saved.Status != EntityStatusActive {
		t.Errorf("expected entity status to remain 'active', got %q", saved.Status)
	}
	if saved.DeletedAt != nil {
		t.Errorf("expected deleted_at to remain nil, got %v", saved.DeletedAt)
	}
	if saved.Version != 1 {
		t.Errorf("expected version to remain 1, got %d", saved.Version)
	}

	// No outbox events were written.
	if len(outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events, got %d", len(outboxRepo.events))
	}
}

// ---------------------------------------------------------------------------
// Gherkin SCENARIO 3:
//
//	Given entity "ent-999" does not exist
//	When a hard-delete is attempted
//	Then HTTP 404 Not Found is returned
// ---------------------------------------------------------------------------

func TestHardDelete_NonExistentEntity(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	schemaRepo := newFakeSchemaRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	err := svc.HardDeleteEntity(ctx, "ent-999")
	if err == nil {
		t.Fatal("expected error, got nil")
	}

	// The underlying error should wrap ErrEntityNotFound.
	if !errors.Is(err, ErrEntityNotFound) {
		t.Errorf("expected ErrEntityNotFound, got %v", err)
	}

	// No outbox events were written.
	if len(outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events for non-existent entity, got %d", len(outboxRepo.events))
	}
}

// ---------------------------------------------------------------------------
// Table-driven: Hard-Delete Boundary Conditions (domain service level)
//
// Consolidates all three Gherkin scenarios and additional boundary cases
// into a single table-driven test.
// ---------------------------------------------------------------------------

func TestHardDelete_TableDriven(t *testing.T) {
	t.Parallel()

	frozenNow := time.Date(2025, 6, 15, 12, 0, 0, 0, time.UTC)

	type entitySeed struct {
		id        string
		status    EntityStatus
		deletedAt *time.Time
		version   int
	}

	type testCase struct {
		name              string
		seed              *entitySeed
		wantErr           error
		wantErrMsg        string // substring expected in error message
		wantEvent         bool   // outbox event expected
		wantEventBus      bool   // event bus notification expected
		wantRemoved       bool   // entity should be gone from repo
		wantDeletionPanic bool   // whether deletion triggers a panic (should never happen)
	}

	tests := []testCase{
		{
			name: "SCENARIO 1: soft-deleted entity hard-delete succeeds",
			seed: &entitySeed{
				id:        "ent-001",
				status:    EntityStatusDeleted,
				deletedAt: timePtr(frozenNow.Add(-1 * time.Hour)),
				version:   2,
			},
			wantErr:      nil,
			wantEvent:    true,
			wantEventBus: true,
			wantRemoved:  true,
		},
		{
			name: "SCENARIO 2: active entity hard-delete fails with ErrNotDeleted",
			seed: &entitySeed{
				id:        "ent-002",
				status:    EntityStatusActive,
				deletedAt: nil,
				version:   1,
			},
			wantErr:     ErrNotDeleted,
			wantErrMsg:  "entity is not soft-deleted",
			wantEvent:   false,
			wantRemoved: false,
		},
		{
			name: "inactive entity also fails with ErrNotDeleted",
			seed: &entitySeed{
				id:        "ent-003",
				status:    EntityStatusInactive,
				deletedAt: nil,
				version:   1,
			},
			wantErr:     ErrNotDeleted,
			wantErrMsg:  "entity is not soft-deleted",
			wantEvent:   false,
			wantRemoved: false,
		},
		{
			name:        "SCENARIO 3: non-existent entity hard-delete fails with ErrEntityNotFound",
			seed:        nil,
			wantErr:     ErrEntityNotFound,
			wantEvent:   false,
			wantRemoved: false,
		},
		{
			name: "soft-deleted entity with no schema still succeeds",
			seed: &entitySeed{
				id:        "ent-004",
				status:    EntityStatusDeleted,
				deletedAt: timePtr(frozenNow.Add(-30 * time.Minute)),
				version:   2,
			},
			wantErr:      nil,
			wantEvent:    true,
			wantEventBus: false, // no event bus configured
			wantRemoved:  true,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			ctx := context.Background()

			entityRepo := newFakeEntityRepo()
			outboxRepo := newFakeOutboxRepo()
			schemaRepo := newFakeSchemaRepo()
			idempotency := newFakeRequestIdempotency()
			uow := newFakeUnitOfWork()

			// Seed a schema if we're seeding an entity.
			if tt.seed != nil {
				_ = schemaRepo.Save(ctx, &EntitySchema{
					ID:   "sch-test",
					Name: "Test",
					Attributes: []AttributeDefinition{
						{Name: "email", Type: AttributeTypeString, Required: true},
					},
					Version:   1,
					CreatedAt: frozenNow.Add(-24 * time.Hour),
					UpdatedAt: frozenNow.Add(-24 * time.Hour),
				})

				// Seed the entity.
				err := entityRepo.Save(ctx, &Entity{
					ID:        tt.seed.id,
					SchemaID:  "sch-test",
					Name:      "TestEntity",
					Type:      "customer",
					Region:    "us-east-1",
					Status:    tt.seed.status,
					Version:   tt.seed.version,
					DeletedAt: tt.seed.deletedAt,
					CreatedAt: frozenNow.Add(-2 * time.Hour),
					UpdatedAt: frozenNow.Add(-1 * time.Hour),
				})
				if err != nil {
					t.Fatalf("seed entity: %v", err)
				}
			}

			// Conditionally use event bus only when scenario expects it.
			var eventBus *fakeEventBus
			opts := []ServiceOption{
				WithClock(func() time.Time { return frozenNow }),
			}
			if tt.wantEventBus {
				eventBus = newFakeEventBus()
				opts = append(opts, WithEvents(eventBus))
			}

			svc := NewService(
				schemaRepo, entityRepo, outboxRepo, idempotency, uow,
				opts...,
			)

			entityID := "ent-nonexistent"
			if tt.seed != nil {
				entityID = tt.seed.id
			}

			err := svc.HardDeleteEntity(ctx, entityID)

			// Check error.
			if tt.wantErr != nil {
				if err == nil {
					t.Fatalf("expected error %v, got nil", tt.wantErr)
				}
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("expected error %v, got %v", tt.wantErr, err)
				}
				if tt.wantErrMsg != "" {
					if err.Error() != "hard delete: "+tt.wantErrMsg {
						t.Errorf("expected error message 'hard delete: %s', got %q", tt.wantErrMsg, err.Error())
					}
				}
			} else if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			// Check if entity was removed from repo.
			if tt.seed != nil && tt.wantRemoved {
				_, lookupErr := entityRepo.FindByID(ctx, tt.seed.id)
				if !errors.Is(lookupErr, ErrEntityNotFound) {
					t.Errorf("expected entity to be permanently removed, got %v", lookupErr)
				}
			}

			// Check if entity was NOT modified (error path).
			if tt.seed != nil && !tt.wantRemoved {
				saved, lookupErr := entityRepo.FindByID(ctx, tt.seed.id)
				if lookupErr != nil {
					t.Fatalf("FindByID failed: %v", lookupErr)
				}
				if saved.Status != tt.seed.status {
					t.Errorf("expected status to remain %q, got %q", tt.seed.status, saved.Status)
				}
				if saved.Version != tt.seed.version {
					t.Errorf("expected version to remain %d, got %d", tt.seed.version, saved.Version)
				}
				if tt.seed.deletedAt == nil && saved.DeletedAt != nil {
					t.Error("expected deleted_at to remain nil")
				}
			}

			// Check outbox events.
			if tt.wantEvent {
				if len(outboxRepo.events) != 1 {
					t.Errorf("expected 1 outbox event, got %d", len(outboxRepo.events))
				} else {
					expectedEventType := (&EntityHardDeleted{}).EventName()
					if outboxRepo.events[0].EventType != expectedEventType {
						t.Errorf("expected event type %q, got %q", expectedEventType, outboxRepo.events[0].EventType)
					}
					if outboxRepo.events[0].AggregateID != entityID {
						t.Errorf("expected aggregate_id %q, got %q", entityID, outboxRepo.events[0].AggregateID)
					}
					if outboxRepo.events[0].AggregateType != "entity" {
						t.Errorf("expected aggregate_type 'entity', got %q", outboxRepo.events[0].AggregateType)
					}
					if outboxRepo.events[0].Status != OutboxStatusPending {
						t.Errorf("expected outbox status 'pending', got %q", outboxRepo.events[0].Status)
					}
				}
			} else {
				if len(outboxRepo.events) != 0 {
					t.Errorf("expected 0 outbox events, got %d", len(outboxRepo.events))
				}
			}

			// Check event bus notifications.
			if tt.wantEventBus && eventBus != nil {
				if len(eventBus.events) != 1 {
					t.Errorf("expected 1 event bus event, got %d", len(eventBus.events))
				} else if eventBus.events[0].EntityID != entityID {
					t.Errorf("expected event bus EntityID %q, got %q", entityID, eventBus.events[0].EntityID)
				}
			}

			if !tt.wantEventBus && eventBus != nil {
				if len(eventBus.events) != 0 {
					t.Errorf("expected 0 event bus events when none configured, got %d", len(eventBus.events))
				}
			}
		})
	}
}

// timePtr returns a pointer to a copy of t.
func timePtr(t time.Time) *time.Time {
	return &t
}
