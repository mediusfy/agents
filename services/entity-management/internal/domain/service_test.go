package domain

import (
	"context"
	"errors"
	"testing"
	"time"
)

// --- Fake implementations for testing ---

// --- Tests ---

func TestCreateEntity_Success(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

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
			{Name: "name", Type: AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
	}); err != nil {
		t.Fatalf("save schema: %v", err)
	}

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
		WithIdempotencyTTL(7*24*time.Hour),
	)

	input := CreateEntityInput{
		SchemaID:       schemaID,
		Name:           "Alice",
		Type:           "customer",
		Region:         "eu-west-1",
		Attributes:     map[string]any{"email": "alice@example.com", "name": "Alice"},
		IdempotencyKey: "create-customer-001",
	}

	result, err := svc.CreateEntity(ctx, input)
	if err != nil {
		t.Fatalf("CreateEntity failed: %v", err)
	}

	// Then an entity is created with status "active" and version 1
	if result.Entity.Status != EntityStatusActive {
		t.Errorf("expected status 'active', got %q", result.Entity.Status)
	}
	if result.Entity.Version != 1 {
		t.Errorf("expected version 1, got %d", result.Entity.Version)
	}
	if !result.Created {
		t.Error("expected Created to be true for new entity")
	}
	if result.Entity.ID == "" {
		t.Error("expected non-empty entity ID")
	}

	// The entity is tagged with DataResidencyZone="eu-west-1"
	if result.Entity.DataResidencyZone != ZoneEUWest1 {
		t.Errorf("expected DataResidencyZone=eu-west-1, got %v", result.Entity.DataResidencyZone)
	}

	// An entitymanagement.entity.created event is enqueued in the outbox within the same transaction
	if len(outboxRepo.events) != 1 {
		t.Fatalf("expected 1 outbox event, got %d", len(outboxRepo.events))
	}
	createdEvent := (&EntityCreated{}).EventName()
	if outboxRepo.events[0].EventType != createdEvent {
		t.Errorf("expected event type %q, got %q", createdEvent, outboxRepo.events[0].EventType)
	}
	if outboxRepo.events[0].Status != OutboxStatusPending {
		t.Errorf("expected outbox event status 'pending', got %q", outboxRepo.events[0].Status)
	}

	// The idempotency key is stored
	entityID, err := idempotency.GetEntityID(ctx, "create-customer-001")
	if err != nil {
		t.Fatalf("GetEntityID failed: %v", err)
	}
	if entityID != result.Entity.ID {
		t.Errorf("expected idempotency to map to %q, got %q", result.Entity.ID, entityID)
	}
}

func TestCreateEntity_IdempotentReplay(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

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
			{Name: "name", Type: AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
	}); err != nil {
		t.Fatalf("save schema: %v", err)
	}

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
		WithIdempotencyTTL(7*24*time.Hour),
	)

	// First creation
	input1 := CreateEntityInput{
		SchemaID:       schemaID,
		Name:           "Alice",
		Type:           "customer",
		Region:         "eu-west-1",
		Attributes:     map[string]any{"email": "alice@example.com", "name": "Alice"},
		IdempotencyKey: "create-customer-001",
	}

	result1, err := svc.CreateEntity(ctx, input1)
	if err != nil {
		t.Fatalf("First CreateEntity failed: %v", err)
	}
	outboxCount1 := len(outboxRepo.events)

	// Second creation with same idempotency key
	input2 := CreateEntityInput{
		SchemaID:       schemaID,
		Name:           "Alice",
		Type:           "customer",
		Region:         "eu-west-1",
		Attributes:     map[string]any{"email": "alice@example.com", "name": "Alice"},
		IdempotencyKey: "create-customer-001",
	}

	result2, err := svc.CreateEntity(ctx, input2)
	if err != nil {
		t.Fatalf("Second (idempotent) CreateEntity failed: %v", err)
	}

	// The existing entity "E1" is returned
	if result2.Entity.ID != result1.Entity.ID {
		t.Errorf("expected same entity ID %q for idempotent replay, got %q", result1.Entity.ID, result2.Entity.ID)
	}
	if result2.Created {
		t.Error("expected Created=false for idempotent replay")
	}

	// No duplicate entity is created
	allEntities, err := entityRepo.FindBySchemaID(ctx, schemaID)
	if err != nil {
		t.Fatalf("FindBySchemaID failed: %v", err)
	}
	if len(allEntities) != 1 {
		t.Errorf("expected exactly 1 entity (no duplicate), got %d", len(allEntities))
	}

	// No duplicate entity.created event is emitted
	if len(outboxRepo.events) != outboxCount1 {
		t.Errorf("expected no new outbox events for idempotent replay, was %d now %d", outboxCount1, len(outboxRepo.events))
	}
}

func TestCreateEntity_ExpiredIdempotencyKey(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()
	eightDaysAgo := now.Add(-8 * 24 * time.Hour)

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()

	// Pre-populate an expired idempotency key (8 days old)
	idempotency := newFakeRequestIdempotency()
	idempotency.mu.Lock()
	idempotency.store["expired-key"] = "old-entity-id"
	idempotency.expiry["expired-key"] = eightDaysAgo
	idempotency.mu.Unlock()

	uow := newFakeUnitOfWork()

	schemaID := "sch-customer"
	if err := schemaRepo.Save(ctx, &EntitySchema{
		ID:   schemaID,
		Name: "Customer",
		Attributes: []AttributeDefinition{
			{Name: "email", Type: AttributeTypeString, Required: true},
			{Name: "name", Type: AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
	}); err != nil {
		t.Fatalf("save schema: %v", err)
	}

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
		WithIdempotencyTTL(7*24*time.Hour),
	)

	input := CreateEntityInput{
		SchemaID:       schemaID,
		Name:           "Bob",
		Type:           "customer",
		Region:         "eu-west-1",
		Attributes:     map[string]any{"email": "bob@example.com", "name": "Bob"},
		IdempotencyKey: "expired-key",
	}

	result, err := svc.CreateEntity(ctx, input)
	if err != nil {
		t.Fatalf("CreateEntity with expired key failed: %v", err)
	}

	// A new entity is created (not the old one)
	if result.Entity.ID == "old-entity-id" {
		t.Error("expected a NEW entity to be created, not the expired one")
	}
	if !result.Created {
		t.Error("expected Created=true for new entity with expired key")
	}
	if result.Entity.Name != "Bob" {
		t.Errorf("expected entity name 'Bob', got %q", result.Entity.Name)
	}

	// The expired key should be updated with the new entity ID
	newEntityID, err := idempotency.GetEntityID(ctx, "expired-key")
	if err != nil {
		t.Fatalf("GetEntityID failed: %v", err)
	}
	if newEntityID == "old-entity-id" {
		t.Error("expected idempotency key to be updated with new entity ID, not the old one")
	}
	if newEntityID != result.Entity.ID {
		t.Errorf("expected idempotency key to map to new entity ID %q, got %q", result.Entity.ID, newEntityID)
	}
}

func TestCreateEntity_RequiredAttributes(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

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
			{Name: "name", Type: AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
	}); err != nil {
		t.Fatalf("save schema: %v", err)
	}

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	// Missing required attribute "email"
	input := CreateEntityInput{
		SchemaID:   schemaID,
		Name:       "NoEmail",
		Type:       "customer",
		Region:     "us-east-1",
		Attributes: map[string]any{"name": "NoEmail"},
	}

	_, err := svc.CreateEntity(ctx, input)
	if err == nil {
		t.Fatal("expected error for missing required attribute, got nil")
	}
	if !errors.Is(err, ErrValidationFailed) {
		t.Errorf("expected ErrValidationFailed, got %v", err)
	}
}

func TestCreateEntity_SchemaNotFound(t *testing.T) {
	t.Parallel()

	ctx := context.Background()

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
	)

	input := CreateEntityInput{
		SchemaID: "nonexistent-schema",
		Name:     "Test",
		Type:     "test",
		Region:   "us-east-1",
	}

	_, err := svc.CreateEntity(ctx, input)
	if err == nil {
		t.Fatal("expected error for nonexistent schema, got nil")
	}
	if !errors.Is(err, ErrSchemaNotFound) {
		t.Errorf("expected ErrSchemaNotFound, got %v", err)
	}
}

func TestResolveZone(t *testing.T) {
	t.Parallel()

	tests := []struct {
		region string
		want   DataResidencyZone
	}{
		{"us-east-1", ZoneUSEast1},
		{"us-west-2", ZoneUSEast1},
		{"eu-west-1", ZoneEUWest1},
		{"eu-central-1", ZoneEUWest1},
		{"ap-southeast-1", DataResidencyZone("ap-southeast-1")},
	}

	for _, tt := range tests {
		got := ResolveZone(tt.region)
		if got != tt.want {
			t.Errorf("ResolveZone(%q) = %q, want %q", tt.region, got, tt.want)
		}
	}
}
