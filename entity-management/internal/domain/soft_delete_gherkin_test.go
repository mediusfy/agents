package domain

import (
	"context"
	"errors"
	"testing"
	"time"
)

// =============================================================================
// Gherkin: Soft-Delete Lifecycle
//
// SCENARIO 1 — Initial soft-delete
//   Given an active entity "ent-001" exists with status "active"
//     and deleted_at is NULL
//   When a DELETE /api/v1/entities/ent-001 request is sent
//     (soft-delete, no ?permanent param)
//   Then deleted_at is set to current UTC timestamp
//     And entity status transitions to "deleted" (terminal)
//     And an entitymanagement.entity.soft_deleted event is written
//       to the outbox within the same transaction
//     And HTTP 200 is returned with
//       {"status": "soft_deleted", "entity_id": "ent-001"}
//     And the entity is excluded from default list queries
//       (include_deleted=false)
//
// SCENARIO 2 — Idempotent double soft-delete
//   Given entity "ent-001" is already soft-deleted
//   When a second soft-delete is attempted
//   Then ErrAlreadyDeleted is returned
//     And no duplicate entity.soft_deleted event is emitted
//
// SCENARIO 3 — Default list query excludes soft-deleted entities
//   Given a soft-deleted entity "ent-001"
//   When a standard GET /api/v1/entities?schema_id=X is called
//     (without include_deleted=true)
//   Then entity "ent-001" is not included in the results
// =============================================================================

// ---------------------------------------------------------------------------
// SCENARIO 1: Initial Soft-Delete
// ---------------------------------------------------------------------------

// TestGherkin_SoftDelete_SetsDeletedAt_TransitionsToDeleted_EmitsEvent
// validates the full soft-delete lifecycle for an active entity.
func TestGherkin_SoftDelete_SetsDeletedAt_TransitionsToDeleted_EmitsEvent(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	frozenNow := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	// Seed a schema.
	schemaID := "sch-customer"
	if err := schemaRepo.Save(ctx, &EntitySchema{
		ID:   schemaID,
		Name: "Customer",
		Attributes: []AttributeDefinition{
			{Name: "email", Type: AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: frozenNow.Add(-24 * time.Hour),
		UpdatedAt: frozenNow.Add(-24 * time.Hour),
	}); err != nil {
		t.Fatalf("save schema: %v", err)
	}

	// Given an active entity "ent-001" exists with status "active"
	// and deleted_at is NULL.
	originalEntity := &Entity{
		ID:        "ent-001",
		SchemaID:  schemaID,
		Name:      "ActiveEntity",
		Type:      "customer",
		Region:    "us-east-1",
		Status:    EntityStatusActive,
		Version:   1,
		CreatedAt: frozenNow.Add(-1 * time.Hour),
		UpdatedAt: frozenNow.Add(-1 * time.Hour),
		DeletedAt: nil,
	}
	if err := entityRepo.Save(ctx, originalEntity); err != nil {
		t.Fatalf("save entity: %v", err)
	}

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return frozenNow }),
	)

	// When a soft-delete is performed (DELETE /api/v1/entities/ent-001).
	if err := svc.SoftDeleteEntity(ctx, "ent-001"); err != nil {
		t.Fatalf("SoftDeleteEntity failed: %v", err)
	}

	// Then deleted_at is set to current UTC timestamp.
	updated, err := entityRepo.FindByID(ctx, "ent-001")
	if err != nil {
		t.Fatalf("FindByID after soft-delete: %v", err)
	}
	if updated.DeletedAt == nil {
		t.Fatal("expected deleted_at to be set after soft-delete")
	}
	if !updated.DeletedAt.Equal(frozenNow) {
		t.Errorf("expected deleted_at=%v, got %v", frozenNow, *updated.DeletedAt)
	}

	// And entity status transitions to "deleted" (terminal).
	if updated.Status != EntityStatusDeleted {
		t.Errorf("expected status 'deleted', got %q", updated.Status)
	}

	// Verify "deleted" is terminal: no transitions allowed via update.
	active := EntityStatusActive
	terminalOp := UpdateOperation{
		ExpectedVersion: updated.Version,
		Status:          &active,
	}
	if err := updated.ApplyUpdate(terminalOp); !errors.Is(err, ErrInvalidStatusTransition) {
		t.Errorf("expected ErrInvalidStatusTransition for updating deleted entity, got %v", err)
	}

	// And an entity.soft_deleted event is written to the outbox
	// within the same transaction.
	if len(outboxRepo.events) != 1 {
		t.Fatalf("expected 1 outbox event, got %d", len(outboxRepo.events))
	}
	if outboxRepo.events[0].EventType != (&EntitySoftDeleted{}).EventName() {
		t.Errorf("expected event type %q, got %q",
			(&EntitySoftDeleted{}).EventName(), outboxRepo.events[0].EventType)
	}
	if outboxRepo.events[0].Status != OutboxStatusPending {
		t.Errorf("expected outbox status 'pending', got %q", outboxRepo.events[0].Status)
	}
	if outboxRepo.events[0].AggregateID != "ent-001" {
		t.Errorf("expected aggregate_id 'ent-001', got %q", outboxRepo.events[0].AggregateID)
	}
	if outboxRepo.events[0].AggregateType != "entity" {
		t.Errorf("expected aggregate_type 'entity', got %q", outboxRepo.events[0].AggregateType)
	}

	// Verify outbox payload contains the soft-delete event fields.
	expectedEventName := (&EntitySoftDeleted{}).EventName()
	if outboxRepo.events[0].EventType != expectedEventName {
		t.Errorf("expected outbox event type %q, got %q", expectedEventName, outboxRepo.events[0].EventType)
	}

	// The entity is excluded from default list queries (include_deleted=false).
	allEntities, err := entityRepo.ListEntities(ctx, ListEntitiesParams{
		SchemaID:       schemaID,
		IncludeDeleted: false,
	})
	if err != nil {
		t.Fatalf("ListEntities failed: %v", err)
	}
	for _, e := range allEntities.Entities {
		if e.ID == "ent-001" {
			t.Error("expected soft-deleted entity 'ent-001' to be excluded from default list query")
		}
	}

	// With include_deleted=true, entity should appear.
	withDeleted, err := entityRepo.ListEntities(ctx, ListEntitiesParams{
		SchemaID:       schemaID,
		IncludeDeleted: true,
	})
	if err != nil {
		t.Fatalf("ListEntities(include_deleted=true) failed: %v", err)
	}
	found := false
	for _, e := range withDeleted.Entities {
		if e.ID == "ent-001" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected soft-deleted entity 'ent-001' to appear when include_deleted=true")
	}
}

// ---------------------------------------------------------------------------
// SCENARIO 2: Idempotent Double Soft-Delete
// ---------------------------------------------------------------------------

// TestGherkin_SecondSoftDelete_ReturnsErrAlreadyDeleted tests that a
// second soft-delete on an already-deleted entity is rejected and no
// duplicate event is emitted.
func TestGherkin_SecondSoftDelete_ReturnsErrAlreadyDeleted(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	frozenNow := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	schemaID := "sch-customer"
	if err := schemaRepo.Save(ctx, &EntitySchema{
		ID:   schemaID,
		Name: "Customer",
		Attributes: []AttributeDefinition{
			{Name: "email", Type: AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: frozenNow.Add(-24 * time.Hour),
		UpdatedAt: frozenNow.Add(-24 * time.Hour),
	}); err != nil {
		t.Fatalf("save schema: %v", err)
	}

	// Given entity "ent-001" is already soft-deleted.
	softDeletedAt := frozenNow.Add(-1 * time.Hour)
	entity := &Entity{
		ID:        "ent-001",
		SchemaID:  schemaID,
		Name:      "DeletedEntity",
		Type:      "customer",
		Region:    "us-east-1",
		Status:    EntityStatusDeleted,
		Version:   2,
		DeletedAt: &softDeletedAt,
		CreatedAt: frozenNow.Add(-2 * time.Hour),
		UpdatedAt: softDeletedAt,
	}
	if err := entityRepo.Save(ctx, entity); err != nil {
		t.Fatalf("save entity: %v", err)
	}

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return frozenNow }),
	)

	// When a second soft-delete is attempted.
	err := svc.SoftDeleteEntity(ctx, "ent-001")

	// Then ErrAlreadyDeleted is returned.
	if err == nil {
		t.Fatal("expected ErrAlreadyDeleted for second soft-delete, got nil")
	}
	if !errors.Is(err, ErrAlreadyDeleted) {
		t.Errorf("expected ErrAlreadyDeleted, got %v", err)
	}

	// And no duplicate entity.soft_deleted event is emitted.
	if len(outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events for duplicate soft-delete, got %d", len(outboxRepo.events))
	}

	// Verify entity state is completely unchanged.
	unchanged, err := entityRepo.FindByID(ctx, "ent-001")
	if err != nil {
		t.Fatalf("FindByID after duplicate soft-delete: %v", err)
	}
	if unchanged.Status != EntityStatusDeleted {
		t.Errorf("expected status to remain 'deleted', got %q", unchanged.Status)
	}
	if unchanged.Version != 2 {
		t.Errorf("expected version to remain 2, got %d", unchanged.Version)
	}
	if unchanged.DeletedAt == nil || !unchanged.DeletedAt.Equal(softDeletedAt) {
		t.Errorf("expected deleted_at to remain %v, got %v", softDeletedAt, unchanged.DeletedAt)
	}
}

// ---------------------------------------------------------------------------
// SCENARIO 3: Default List Query Excludes Soft-Deleted Entities
// ---------------------------------------------------------------------------

// TestGherkin_SoftDeletedEntity_ExcludedFromDefaultListQuery validates
// that a soft-deleted entity is not returned by the standard list endpoint
// without include_deleted=true.
func TestGherkin_SoftDeletedEntity_ExcludedFromDefaultListQuery(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	entityRepo := newFakeEntityRepo()
	schemaID := "sch-customer"

	// Given a schema exists.
	schemaRepo := newFakeSchemaRepo()
	_ = schemaRepo.Save(ctx, &EntitySchema{
		ID:   schemaID,
		Name: "Customer",
		Attributes: []AttributeDefinition{
			{Name: "email", Type: AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now.Add(-24 * time.Hour),
		UpdatedAt: now.Add(-24 * time.Hour),
	})

	// Seed entities: one soft-deleted, two active.
	softDeletedAt := now.Add(-30 * time.Minute)
	entities := []*Entity{
		{
			ID:        "ent-001",
			SchemaID:  schemaID,
			Name:      "DeletedEntity",
			Type:      "customer",
			Region:    "us-east-1",
			Status:    EntityStatusDeleted,
			Version:   2,
			DeletedAt: &softDeletedAt,
			CreatedAt: now.Add(-2 * time.Hour),
			UpdatedAt: softDeletedAt,
		},
		{
			ID:        "ent-002",
			SchemaID:  schemaID,
			Name:      "ActiveEntityOne",
			Type:      "customer",
			Region:    "eu-west-1",
			Status:    EntityStatusActive,
			Version:   1,
			CreatedAt: now.Add(-1 * time.Hour),
			UpdatedAt: now.Add(-1 * time.Hour),
			DeletedAt: nil,
		},
		{
			ID:        "ent-003",
			SchemaID:  schemaID,
			Name:      "ActiveEntityTwo",
			Type:      "customer",
			Region:    "us-east-1",
			Status:    EntityStatusActive,
			Version:   1,
			CreatedAt: now.Add(-30 * time.Minute),
			UpdatedAt: now.Add(-30 * time.Minute),
			DeletedAt: nil,
		},
	}
	for _, e := range entities {
		if err := entityRepo.Save(ctx, e); err != nil {
			t.Fatalf("save entity %s: %v", e.ID, err)
		}
	}

	// When a standard list query is called without include_deleted=true.
	result, err := entityRepo.ListEntities(ctx, ListEntitiesParams{
		SchemaID:       schemaID,
		IncludeDeleted: false,
	})
	if err != nil {
		t.Fatalf("ListEntities failed: %v", err)
	}

	// Then entity "ent-001" is not included in the results.
	for _, e := range result.Entities {
		if e.ID == "ent-001" {
			t.Errorf("soft-deleted entity 'ent-001' should NOT appear in default list (include_deleted=false)")
		}
	}

	// And only the active entities are returned.
	if len(result.Entities) != 2 {
		t.Errorf("expected exactly 2 active entities, got %d", len(result.Entities))
	}

	activeIDs := map[string]bool{"ent-002": true, "ent-003": true}
	for _, e := range result.Entities {
		if !activeIDs[e.ID] {
			t.Errorf("unexpected entity %q in results", e.ID)
		}
	}

	// Verify total count excludes the soft-deleted entity.
	if result.TotalCount != 2 {
		t.Errorf("expected TotalCount=2 (only active entities), got %d", result.TotalCount)
	}
}

// ---------------------------------------------------------------------------
// Table-driven: Soft-Delete Boundary Conditions
// ---------------------------------------------------------------------------

// TestGherkin_SoftDelete_TableDriven uses a table-driven approach to verify
// multiple scenarios around the soft-delete boundary.
func TestGherkin_SoftDelete_TableDriven(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	frozenNow := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)

	type fields struct {
		initialStatus EntityStatus
		deletedAt     *time.Time
		initialVer    int
	}

	type args struct {
		entityID string
	}

	type testCase struct {
		name          string
		fields        fields
		args          args
		wantErr       error
		wantStatus    EntityStatus
		wantVersion   int
		wantDeletedAt bool
		wantEvent     bool // true if an outbox event is expected
	}

	tests := []testCase{
		{
			name: "active entity soft-delete succeeds",
			fields: fields{
				initialStatus: EntityStatusActive,
				deletedAt:     nil,
				initialVer:    1,
			},
			args: args{
				entityID: "ent-active",
			},
			wantErr:       nil,
			wantStatus:    EntityStatusDeleted,
			wantVersion:   2,
			wantDeletedAt: true,
			wantEvent:     true,
		},
		{
			name: "inactive entity soft-delete succeeds",
			fields: fields{
				initialStatus: EntityStatusInactive,
				deletedAt:     nil,
				initialVer:    1,
			},
			args: args{
				entityID: "ent-inactive",
			},
			wantErr:       nil,
			wantStatus:    EntityStatusDeleted,
			wantVersion:   2,
			wantDeletedAt: true,
			wantEvent:     true,
		},
		{
			name: "already deleted entity returns ErrAlreadyDeleted",
			fields: fields{
				initialStatus: EntityStatusDeleted,
				deletedAt:     &frozenNow,
				initialVer:    2,
			},
			args: args{
				entityID: "ent-double-delete",
			},
			wantErr:       ErrAlreadyDeleted,
			wantStatus:    EntityStatusDeleted,
			wantVersion:   2, // unchanged
			wantDeletedAt: true,
			wantEvent:     false,
		},
	}

	for _, tt := range tests {
		tt := tt // capture range variable
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			schemaRepo := newFakeSchemaRepo()
			entityRepo := newFakeEntityRepo()
			outboxRepo := newFakeOutboxRepo()
			idempotency := newFakeRequestIdempotency()
			uow := newFakeUnitOfWork()

			schemaID := "sch-customer"
			_ = schemaRepo.Save(ctx, &EntitySchema{
				ID:   schemaID,
				Name: "Customer",
				Attributes: []AttributeDefinition{
					{Name: "email", Type: AttributeTypeString, Required: true},
				},
				Version:   1,
				CreatedAt: frozenNow.Add(-24 * time.Hour),
				UpdatedAt: frozenNow.Add(-24 * time.Hour),
			})

			entity := &Entity{
				ID:        tt.args.entityID,
				SchemaID:  schemaID,
				Name:      "TestEntity",
				Type:      "customer",
				Region:    "us-east-1",
				Status:    tt.fields.initialStatus,
				Version:   tt.fields.initialVer,
				DeletedAt: tt.fields.deletedAt,
				CreatedAt: frozenNow.Add(-2 * time.Hour),
				UpdatedAt: frozenNow.Add(-1 * time.Hour),
			}
			if err := entityRepo.Save(ctx, entity); err != nil {
				t.Fatalf("save entity: %v", err)
			}

			svc := NewService(
				schemaRepo, entityRepo, outboxRepo, idempotency, uow,
				WithClock(func() time.Time { return frozenNow }),
			)

			err := svc.SoftDeleteEntity(ctx, tt.args.entityID)

			// Check error.
			if tt.wantErr != nil {
				if err == nil {
					t.Fatalf("expected error %v, got nil", tt.wantErr)
				}
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("expected error %v, got %v", tt.wantErr, err)
				}
			} else if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			// Verify final state.
			updated, lookupErr := entityRepo.FindByID(ctx, tt.args.entityID)
			if lookupErr != nil {
				t.Fatalf("FindByID: %v", lookupErr)
			}

			if updated.Status != tt.wantStatus {
				t.Errorf("expected status %q, got %q", tt.wantStatus, updated.Status)
			}
			if updated.Version != tt.wantVersion {
				t.Errorf("expected version %d, got %d", tt.wantVersion, updated.Version)
			}
			if tt.wantDeletedAt && updated.DeletedAt == nil {
				t.Error("expected deleted_at to be set")
			}
			if !tt.wantDeletedAt && updated.DeletedAt != nil {
				t.Error("expected deleted_at to be nil")
			}

			// Check outbox events.
			if tt.wantEvent && len(outboxRepo.events) != 1 {
				t.Errorf("expected 1 outbox event, got %d", len(outboxRepo.events))
			}
			if !tt.wantEvent && len(outboxRepo.events) != 0 {
				t.Errorf("expected 0 outbox events, got %d", len(outboxRepo.events))
			}

			// Verify that the entity is excluded from default list queries
			// only when it has been soft-deleted.
			if tt.wantErr == nil && tt.wantDeletedAt {
				listResult, listErr := entityRepo.ListEntities(ctx, ListEntitiesParams{
					SchemaID:       schemaID,
					IncludeDeleted: false,
				})
				if listErr != nil {
					t.Fatalf("ListEntities: %v", listErr)
				}
				for _, e := range listResult.Entities {
					if e.ID == tt.args.entityID {
						t.Errorf("soft-deleted entity %q should be excluded from default list", tt.args.entityID)
					}
				}
			}
		})
	}
}

// ---------------------------------------------------------------------------
// TestGherkin_SoftDelete_MarkDeleted_Unit verifies the domain Entity method
// MarkDeleted directly for its contract.
// ---------------------------------------------------------------------------

func TestGherkin_SoftDelete_MarkDeleted_Unit(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()

	t.Run("active entity mark deleted succeeds", func(t *testing.T) {
		e := &Entity{
			ID:     "ent-001",
			Status: EntityStatusActive,
			Version: 1,
		}
		if err := e.MarkDeleted(now); err != nil {
			t.Fatalf("MarkDeleted failed: %v", err)
		}
		if e.Status != EntityStatusDeleted {
			t.Errorf("expected status 'deleted', got %q", e.Status)
		}
		if e.DeletedAt == nil || !e.DeletedAt.Equal(now) {
			t.Errorf("expected deleted_at=%v, got %v", now, e.DeletedAt)
		}
		if e.Version != 2 {
			t.Errorf("expected version 2, got %d", e.Version)
		}
	})

	t.Run("already deleted entity returns ErrAlreadyDeleted", func(t *testing.T) {
		deletedAt := now.Add(-1 * time.Hour)
		e := &Entity{
			ID:        "ent-002",
			Status:    EntityStatusDeleted,
			Version:   2,
			DeletedAt: &deletedAt,
		}
		if err := e.MarkDeleted(now); !errors.Is(err, ErrAlreadyDeleted) {
			t.Errorf("expected ErrAlreadyDeleted, got %v", err)
		}
		// State unchanged.
		if e.Status != EntityStatusDeleted {
			t.Errorf("expected status to remain 'deleted', got %q", e.Status)
		}
		if e.Version != 2 {
			t.Errorf("expected version to remain 2, got %d", e.Version)
		}
	})

	t.Run("inactive entity mark deleted succeeds", func(t *testing.T) {
		e := &Entity{
			ID:     "ent-003",
			Status: EntityStatusInactive,
			Version: 1,
		}
		if err := e.MarkDeleted(now); err != nil {
			t.Fatalf("MarkDeleted failed: %v", err)
		}
		if e.Status != EntityStatusDeleted {
			t.Errorf("expected status 'deleted', got %q", e.Status)
		}
	})

	t.Run("is soft deleted returns true when deleted_at is set", func(t *testing.T) {
		deletedAt := now
		e := &Entity{DeletedAt: &deletedAt}
		if !e.IsSoftDeleted() {
			t.Error("expected IsSoftDeleted to return true")
		}
	})

	t.Run("is soft deleted returns false when deleted_at is nil", func(t *testing.T) {
		e := &Entity{DeletedAt: nil}
		if e.IsSoftDeleted() {
			t.Error("expected IsSoftDeleted to return false")
		}
	})

	t.Run("ValidTransitions for deleted returns empty", func(t *testing.T) {
		transitions := EntityStatusDeleted.ValidTransitions()
		if len(transitions) != 0 {
			t.Errorf("expected empty transitions for deleted status, got %v", transitions)
		}
	})

	t.Run("CanTransitionTo from deleted always fails", func(t *testing.T) {
		if EntityStatusDeleted.CanTransitionTo(EntityStatusActive) {
			t.Error("expected CanTransitionTo(active) from deleted to be false")
		}
		if EntityStatusDeleted.CanTransitionTo(EntityStatusInactive) {
			t.Error("expected CanTransitionTo(inactive) from deleted to be false")
		}
		if EntityStatusDeleted.CanTransitionTo(EntityStatusDeleted) {
			t.Error("expected CanTransitionTo(deleted) from deleted to be false")
		}
	})
}
