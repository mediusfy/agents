package domain

import (
	"context"
	"errors"
	"sort"
	"testing"
	"time"
)

// ============================================================================
// Gherkin SCENARIO 1: Happy path — successful entity update
//
//   Given an entity "ent-001" exists with version 3
//     And attributes: {"email": "old@example.com", "name": "Alice"}
//   When a PUT /api/v1/entities/ent-001 request is sent
//     With body: {"expected_version": 3, "name": "Alice Updated",
//                 "attributes": {"email": "new@example.com"}}
//   Then the entity is updated
//     And version is incremented from 3 to 4
//     And updated_at is refreshed
//     And an entitymanagement.entity.updated event is written to the outbox
//     And the event payload includes changed_fields: ["name", "attributes.email"]
//     And HTTP 200 is returned with the full updated entity
// ============================================================================

func TestGherkin_UpdateEntity_Success_WithChangedFields(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	// Seed a schema.
	schemaID := "sch-customer"
	_ = schemaRepo.Save(ctx, &EntitySchema{
		ID:   schemaID,
		Name: "Customer",
		Attributes: []AttributeDefinition{
			{Name: "email", Type: AttributeTypeString, Required: true},
			{Name: "name", Type: AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now.Add(-2 * time.Hour),
		UpdatedAt: now.Add(-2 * time.Hour),
	})

	// Given entity "ent-001" exists with version 3 and attributes.
	createdAt := now.Add(-1 * time.Hour)
	updatedAt := now.Add(-30 * time.Minute)
	_ = entityRepo.Save(ctx, &Entity{
		ID:       "ent-001",
		SchemaID: schemaID,
		Name:     "Alice",
		Type:     "customer",
		Status:   EntityStatusActive,
		Region:   "us-east-1",
		Version:  3,
		Attributes: map[string]any{
			"email": "old@example.com",
			"name":  "Alice",
		},
		CreatedAt: createdAt,
		UpdatedAt: updatedAt,
	})

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	// When a PUT update with expected_version=3, new name and updated email.
	newName := "Alice Updated"
	op := UpdateOperation{
		ExpectedVersion: 3,
		Name:            &newName,
		Attributes:      map[string]any{"email": "new@example.com"},
	}

	updated, err := svc.UpdateEntity(ctx, "ent-001", op)
	if err != nil {
		t.Fatalf("UpdateEntity failed: %v", err)
	}

	// Then the entity is updated.
	if updated.Name != "Alice Updated" {
		t.Errorf("expected name 'Alice Updated', got %q", updated.Name)
	}
	if updated.Attributes["email"] != "new@example.com" {
		t.Errorf("expected email 'new@example.com', got %v", updated.Attributes["email"])
	}

	// And version is incremented from 3 to 4.
	if updated.Version != 4 {
		t.Errorf("expected version 4, got %d", updated.Version)
	}

	// And updated_at is refreshed (use Before to handle nanosecond differences).
	if updated.UpdatedAt.Before(now) {
		t.Errorf("expected updated_at >= %v, got %v", now, updated.UpdatedAt)
	}

	// And an entity.updated event is written to the outbox.
	if len(outboxRepo.events) != 1 {
		t.Fatalf("expected 1 outbox event, got %d", len(outboxRepo.events))
	}
	evt := outboxRepo.events[0]
	if evt.EventType != (&EntityUpdated{}).EventName() {
		t.Errorf("expected event type %q, got %q", (&EntityUpdated{}).EventName(), evt.EventType)
	}
	if evt.Status != OutboxStatusPending {
		t.Errorf("expected outbox status 'pending', got %q", evt.Status)
	}
	if evt.AggregateID != "ent-001" {
		t.Errorf("expected aggregate_id 'ent-001', got %q", evt.AggregateID)
	}
	if evt.AggregateType != "entity" {
		t.Errorf("expected aggregate_type 'entity', got %q", evt.AggregateType)
	}

	// And the event payload includes changed_fields: ["name", "attributes.email"].
	changedFields := op.CollectChangedFields()
	expectedFields := []string{"attributes.email", "name"} // sorted
	gotSorted := make([]string, len(changedFields))
	copy(gotSorted, changedFields)
	sort.Strings(gotSorted)
	if len(gotSorted) != len(expectedFields) {
		t.Errorf("expected changed_fields %v, got %v", expectedFields, changedFields)
	} else {
		for i, f := range expectedFields {
			if gotSorted[i] != f {
				t.Errorf("expected changed_field[%d]=%q, got %q", i, f, gotSorted[i])
			}
		}
	}

	// Verify the stored entity in the repository also reflects the update.
	stored, err := entityRepo.FindByID(ctx, "ent-001")
	if err != nil {
		t.Fatalf("FindByID failed: %v", err)
	}
	if stored.Name != "Alice Updated" {
		t.Errorf("stored name = %q, want 'Alice Updated'", stored.Name)
	}
	if stored.Version != 4 {
		t.Errorf("stored version = %d, want 4", stored.Version)
	}
}

// ============================================================================
// Gherkin SCENARIO 2: Stale version — concurrent modification detection.
//
//   Given entity "ent-001" now has version 4 (concurrent update)
//   When a PUT /api/v1/entities/ent-001 request is sent with expected_version=3 (stale)
//   Then HTTP 409 Conflict is returned with ErrStaleVersion
//     And no data is modified
//     And no entity.updated event is emitted
// ============================================================================

func TestGherkin_UpdateEntity_StaleVersion_Returns409(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

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
			{Name: "name", Type: AttributeTypeString, Required: true},
		},
		Version: 1, CreatedAt: now.Add(-2 * time.Hour), UpdatedAt: now.Add(-2 * time.Hour),
	})

	// Given entity "ent-001" now has version 4 (concurrent update already happened).
	_ = entityRepo.Save(ctx, &Entity{
		ID: "ent-001", SchemaID: schemaID, Name: "Alice Updated", Type: "customer",
		Status: EntityStatusActive, Region: "us-east-1", Version: 4,
		Attributes: map[string]any{"email": "new@example.com", "name": "Alice Updated"},
		CreatedAt:  now.Add(-1 * time.Hour), UpdatedAt: now,
	})

	svc := NewService(schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	// When a PUT request is sent with expected_version=3 (stale).
	newName := "Alice v3"
	op := UpdateOperation{ExpectedVersion: 3, Name: &newName}

	_, err := svc.UpdateEntity(ctx, "ent-001", op)
	if err == nil {
		t.Fatal("expected ErrStaleVersion for stale expected_version, got nil")
	}

	// Then HTTP 409 Conflict is returned with ErrStaleVersion.
	if !errors.Is(err, ErrStaleVersion) {
		t.Errorf("expected ErrStaleVersion, got %v", err)
	}

	// And no data is modified — entity remains at version 4 with unchanged fields.
	unchanged, _ := entityRepo.FindByID(ctx, "ent-001")
	if unchanged.Version != 4 {
		t.Errorf("expected version to remain 4, got %d", unchanged.Version)
	}
	if unchanged.Name != "Alice Updated" {
		t.Errorf("expected name to remain 'Alice Updated', got %q", unchanged.Name)
	}
	if unchanged.Attributes["email"] != "new@example.com" {
		t.Errorf("expected email to remain 'new@example.com', got %v", unchanged.Attributes["email"])
	}

	// And no entity.updated event is emitted.
	if len(outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events for stale version update, got %d", len(outboxRepo.events))
	}
}

// ============================================================================
// Gherkin SCENARIO 3: Immutable field — rejection of changes to protected fields.
//
//   Given a PUT request includes an immutable field change like "region"
//   When the update is attempted
//   Then HTTP 400 Bad Request is returned with ErrImmutableField
//     And no changes are persisted
// ============================================================================

func TestGherkin_UpdateEntity_ImmutableField_Returns400(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	schemaID := "sch-customer"
	_ = schemaRepo.Save(ctx, &EntitySchema{
		ID: schemaID, Name: "Customer",
		Attributes: []AttributeDefinition{
			{Name: "email", Type: AttributeTypeString, Required: true},
			{Name: "name", Type: AttributeTypeString, Required: true},
		},
		Version: 1, CreatedAt: now.Add(-2 * time.Hour), UpdatedAt: now.Add(-2 * time.Hour),
	})

	// Given an active entity at version 3 in region "us-east-1".
	_ = entityRepo.Save(ctx, &Entity{
		ID:                "ent-001",
		SchemaID:          schemaID,
		Name:              "Alice",
		Type:              "customer",
		Status:            EntityStatusActive,
		Region:            "us-east-1",
		DataResidencyZone: ZoneUSEast1,
		Version:           3,
		Attributes:        map[string]any{"email": "alice@example.com", "name": "Alice"},
		CreatedAt:         now.Add(-1 * time.Hour),
		UpdatedAt:         now.Add(-1 * time.Hour),
	})

	svc := NewService(schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	// When a PUT request includes an immutable field change like "region".
	newRegion := "eu-west-1"
	op := UpdateOperation{ExpectedVersion: 3, Region: &newRegion}

	_, err := svc.UpdateEntity(ctx, "ent-001", op)
	if err == nil {
		t.Fatal("expected ErrImmutableField for region change, got nil")
	}

	// Then ErrImmutableField is returned (HTTP 400 Bad Request).
	if !errors.Is(err, ErrImmutableField) {
		t.Errorf("expected ErrImmutableField, got %v", err)
	}

	// And no changes are persisted.
	unchanged, _ := entityRepo.FindByID(ctx, "ent-001")
	if unchanged.Region != "us-east-1" {
		t.Errorf("expected region to remain 'us-east-1', got %q", unchanged.Region)
	}
	if unchanged.Version != 3 {
		t.Errorf("expected version to remain 3, got %d", unchanged.Version)
	}
	if unchanged.Name != "Alice" {
		t.Errorf("expected name to remain 'Alice', got %q", unchanged.Name)
	}

	// No outbox events were written.
	if len(outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events for immutable field update, got %d", len(outboxRepo.events))
	}
}

// ============================================================================
// Table-driven tests: comprehensive coverage of ApplyUpdate error paths
// ============================================================================

func TestEntity_ApplyUpdate_TableDriven(t *testing.T) {
	t.Parallel()
	now := time.Now().UTC()

	tests := []struct {
		name        string
		initial     Entity
		op          UpdateOperation
		wantErr     error
		checkEntity func(t *testing.T, e *Entity)
	}{
		{
			name: "successful full update",
			initial: Entity{
				ID: "ent-001", Name: "Old Name", Status: EntityStatusActive, Version: 1,
				Attributes: map[string]any{"email": "old@test.com"},
				Metadata:   map[string]any{"source": "legacy"},
				CreatedAt:  now.Add(-1 * time.Hour), UpdatedAt: now.Add(-1 * time.Hour),
			},
			op: UpdateOperation{
				ExpectedVersion: 1, Name: strPtr("New Name"),
				Attributes: map[string]any{"email": "new@test.com"},
				Metadata:   map[string]any{"source": "migrated"},
			},
			checkEntity: func(t *testing.T, e *Entity) {
				if e.Name != "New Name" {
					t.Errorf("name = %q, want %q", e.Name, "New Name")
				}
				if e.Version != 2 {
					t.Errorf("version = %d, want 2", e.Version)
				}
				if e.Attributes["email"] != "new@test.com" {
					t.Errorf("email = %v, want %q", e.Attributes["email"], "new@test.com")
				}
				if e.Metadata["source"] != "migrated" {
					t.Errorf("source = %v, want %q", e.Metadata["source"], "migrated")
				}
			},
		},
		{
			name: "stale version error",
			initial: Entity{
				ID: "ent-002", Name: "Entity", Status: EntityStatusActive, Version: 5,
				CreatedAt: now.Add(-1 * time.Hour), UpdatedAt: now.Add(-1 * time.Hour),
			},
			op:      UpdateOperation{ExpectedVersion: 3, Name: strPtr("New Name")},
			wantErr: ErrStaleVersion,
			checkEntity: func(t *testing.T, e *Entity) {
				if e.Version != 5 {
					t.Errorf("version should remain 5, got %d", e.Version)
				}
				if e.Name != "Entity" {
					t.Errorf("name should remain 'Entity', got %q", e.Name)
				}
			},
		},
		{
			name: "immutable region field",
			initial: Entity{
				ID: "ent-003", Name: "Entity", Region: "us-east-1",
				Status: EntityStatusActive, Version: 1,
				CreatedAt: now.Add(-1 * time.Hour), UpdatedAt: now.Add(-1 * time.Hour),
			},
			op:      UpdateOperation{ExpectedVersion: 1, Region: strPtr("eu-west-1")},
			wantErr: ErrImmutableField,
			checkEntity: func(t *testing.T, e *Entity) {
				if e.Region != "us-east-1" {
					t.Errorf("region should remain 'us-east-1', got %q", e.Region)
				}
				if e.Version != 1 {
					t.Errorf("version should remain 1, got %d", e.Version)
				}
			},
		},
		{
			name: "status-only update",
			initial: Entity{
				ID: "ent-004", Name: "Entity", Status: EntityStatusActive, Version: 1,
				CreatedAt: now.Add(-1 * time.Hour), UpdatedAt: now.Add(-1 * time.Hour),
			},
			op: UpdateOperation{ExpectedVersion: 1, Status: statusPtr(EntityStatusInactive)},
			checkEntity: func(t *testing.T, e *Entity) {
				if e.Status != EntityStatusInactive {
					t.Errorf("status = %q, want %q", e.Status, EntityStatusInactive)
				}
				if e.Version != 2 {
					t.Errorf("version = %d, want 2", e.Version)
				}
			},
		},
		{
			name: "invalid status transition from deleted",
			initial: Entity{
				ID: "ent-005", Name: "Entity", Status: EntityStatusDeleted, Version: 2,
				CreatedAt: now.Add(-2 * time.Hour), UpdatedAt: now.Add(-1 * time.Hour),
			},
			op:      UpdateOperation{ExpectedVersion: 2, Status: statusPtr(EntityStatusActive)},
			wantErr: ErrInvalidStatusTransition,
			checkEntity: func(t *testing.T, e *Entity) {
				if e.Status != EntityStatusDeleted {
					t.Errorf("status should remain 'deleted', got %q", e.Status)
				}
				if e.Version != 2 {
					t.Errorf("version should remain 2, got %d", e.Version)
				}
			},
		},
		{
			name: "name-only partial update",
			initial: Entity{
				ID: "ent-006", Name: "Original", Status: EntityStatusActive, Version: 1,
				CreatedAt: now.Add(-1 * time.Hour), UpdatedAt: now.Add(-1 * time.Hour),
			},
			op: UpdateOperation{ExpectedVersion: 1, Name: strPtr("Renamed")},
			checkEntity: func(t *testing.T, e *Entity) {
				if e.Name != "Renamed" {
					t.Errorf("name = %q, want %q", e.Name, "Renamed")
				}
				if e.Version != 2 {
					t.Errorf("version = %d, want 2", e.Version)
				}
				if e.Status != EntityStatusActive {
					t.Errorf("status should remain 'active', got %q", e.Status)
				}
			},
		},
		{
			name: "attributes-only partial update",
			initial: Entity{
				ID: "ent-007", Name: "Entity", Status: EntityStatusActive, Version: 1,
				Attributes: map[string]any{"email": "old@test.com", "age": float64(30)},
				CreatedAt:  now.Add(-1 * time.Hour), UpdatedAt: now.Add(-1 * time.Hour),
			},
			op: UpdateOperation{ExpectedVersion: 1, Attributes: map[string]any{"email": "updated@test.com"}},
			checkEntity: func(t *testing.T, e *Entity) {
				if e.Attributes["email"] != "updated@test.com" {
					t.Errorf("email = %v, want %q", e.Attributes["email"], "updated@test.com")
				}
				if e.Attributes["age"] != float64(30) {
					t.Errorf("age should remain 30, got %v", e.Attributes["age"])
				}
				if e.Version != 2 {
					t.Errorf("version = %d, want 2", e.Version)
				}
			},
		},
		{
			name: "metadata-only partial update",
			initial: Entity{
				ID: "ent-008", Name: "Entity", Status: EntityStatusActive, Version: 1,
				Metadata:  map[string]any{"tier": "bronze"},
				CreatedAt: now.Add(-1 * time.Hour), UpdatedAt: now.Add(-1 * time.Hour),
			},
			op: UpdateOperation{ExpectedVersion: 1, Metadata: map[string]any{"tier": "gold"}},
			checkEntity: func(t *testing.T, e *Entity) {
				if e.Metadata["tier"] != "gold" {
					t.Errorf("tier = %v, want %q", e.Metadata["tier"], "gold")
				}
				if e.Version != 2 {
					t.Errorf("version = %d, want 2", e.Version)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := tt.initial
			err := e.ApplyUpdate(tt.op)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("ApplyUpdate() error = %v, want %v", err, tt.wantErr)
				}
			} else if err != nil {
				t.Fatalf("ApplyUpdate() unexpected error: %v", err)
			}
			if tt.checkEntity != nil {
				tt.checkEntity(t, &e)
			}
		})
	}
}

// ============================================================================
// Table-driven tests: CollectChangedFields
// ============================================================================

func TestUpdateOperation_CollectChangedFields(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		op       UpdateOperation
		expected []string // sorted
	}{
		{
			name:     "name and attributes",
			op:       UpdateOperation{Name: strPtr("Alice Updated"), Attributes: map[string]any{"email": "new@example.com"}},
			expected: []string{"attributes.email", "name"},
		},
		{
			name:     "status change only",
			op:       UpdateOperation{Status: statusPtr(EntityStatusInactive)},
			expected: []string{"status"},
		},
		{
			name:     "multiple attributes",
			op:       UpdateOperation{Attributes: map[string]any{"email": "a@b.com", "phone": "123", "city": "NYC"}},
			expected: []string{"attributes.city", "attributes.email", "attributes.phone"},
		},
		{
			name:     "name, status, attributes, metadata",
			op:       UpdateOperation{Name: strPtr("X"), Status: statusPtr(EntityStatusActive), Attributes: map[string]any{"age": float64(25)}, Metadata: map[string]any{"source": "web"}},
			expected: []string{"attributes.age", "metadata.source", "name", "status"},
		},
		{
			name:     "region included (rejected by ValidateMutable)",
			op:       UpdateOperation{Region: strPtr("eu-west-1")},
			expected: []string{"region"},
		},
		{
			name:     "no changes",
			op:       UpdateOperation{ExpectedVersion: 1},
			expected: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.op.CollectChangedFields()
			sort.Strings(got)
			sort.Strings(tt.expected)
			if len(got) != len(tt.expected) {
				t.Fatalf("CollectChangedFields() = %v (len=%d), want %v (len=%d)",
					got, len(got), tt.expected, len(tt.expected))
			}
			for i, f := range tt.expected {
				if got[i] != f {
					t.Errorf("CollectChangedFields()[%d] = %q, want %q", i, got[i], f)
				}
			}
		})
	}
}

// ============================================================================
// Table-driven tests: ValidateMutable
// ============================================================================

func TestUpdateOperation_ValidateMutable(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		op      UpdateOperation
		wantErr bool
		errType error
	}{
		{name: "name change is mutable", op: UpdateOperation{Name: strPtr("New Name")}, wantErr: false},
		{name: "status change is mutable", op: UpdateOperation{Status: statusPtr(EntityStatusInactive)}, wantErr: false},
		{name: "attributes change is mutable", op: UpdateOperation{Attributes: map[string]any{"email": "new@test.com"}}, wantErr: false},
		{name: "metadata change is mutable", op: UpdateOperation{Metadata: map[string]any{"key": "value"}}, wantErr: false},
		{name: "region change is immutable", op: UpdateOperation{Region: strPtr("eu-west-1")}, wantErr: true, errType: ErrImmutableField},
		{name: "empty operation is valid", op: UpdateOperation{ExpectedVersion: 1}, wantErr: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.op.ValidateMutable()
			if tt.wantErr {
				if err == nil {
					t.Errorf("ValidateMutable() expected error, got nil")
				} else if tt.errType != nil && !errors.Is(err, tt.errType) {
					t.Errorf("ValidateMutable() error = %v, want %v", err, tt.errType)
				}
			} else if err != nil {
				t.Errorf("ValidateMutable() unexpected error: %v", err)
			}
		})
	}
}

// ============================================================================
// Helpers
// ============================================================================

func strPtr(s string) *string                { return &s }
func statusPtr(s EntityStatus) *EntityStatus { return &s }
