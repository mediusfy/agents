package domain

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// --- Fake implementations for testing ---

type fakeSchemaRepo struct {
	schemas map[string]*EntitySchema
	mu      sync.RWMutex
}

func newFakeSchemaRepo() *fakeSchemaRepo {
	return &fakeSchemaRepo{schemas: make(map[string]*EntitySchema)}
}

func (r *fakeSchemaRepo) Save(_ context.Context, schema *EntitySchema) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.schemas[schema.ID] = schema
	return nil
}

func (r *fakeSchemaRepo) FindByID(_ context.Context, id string) (*EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	s, ok := r.schemas[id]
	if !ok {
		return nil, ErrSchemaNotFound
	}
	return s, nil
}

func (r *fakeSchemaRepo) FindByName(_ context.Context, name string) (*EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, s := range r.schemas {
		if s.Name == name {
			return s, nil
		}
	}
	return nil, ErrSchemaNotFound
}

func (r *fakeSchemaRepo) FindAll(_ context.Context) ([]*EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*EntitySchema
	for _, s := range r.schemas {
		result = append(result, s)
	}
	return result, nil
}

func (r *fakeSchemaRepo) Delete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.schemas, id)
	return nil
}

type fakeEntityRepo struct {
	entities map[string]*Entity
	mu       sync.RWMutex
}

func newFakeEntityRepo() *fakeEntityRepo {
	return &fakeEntityRepo{entities: make(map[string]*Entity)}
}

func (r *fakeEntityRepo) Save(_ context.Context, entity *Entity) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entities[entity.ID] = entity
	return nil
}

func (r *fakeEntityRepo) FindByID(_ context.Context, id string) (*Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, ErrEntityNotFound
	}
	return e, nil
}

func (r *fakeEntityRepo) Update(_ context.Context, id string, op UpdateOperation) (*Entity, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, ErrEntityNotFound
	}
	if err := e.ApplyUpdate(op); err != nil {
		return nil, err
	}
	return e, nil
}

func (r *fakeEntityRepo) UpdateStatus(_ context.Context, id string, status EntityStatus) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return ErrEntityNotFound
	}
	if !e.Status.CanTransitionTo(status) {
		return ErrInvalidStatusTransition
	}
	e.Status = status
	e.Version++
	return nil
}

func (r *fakeEntityRepo) FindBySchemaID(_ context.Context, schemaID string) ([]*Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*Entity
	for _, e := range r.entities {
		if e.SchemaID == schemaID {
			result = append(result, e)
		}
	}
	return result, nil
}

func (r *fakeEntityRepo) List(_ context.Context, filter EntityFilter) ([]*Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*Entity
	for _, e := range r.entities {
		if filter.Status != nil && e.Status != *filter.Status {
			continue
		}
		if filter.Region != nil && e.Region != *filter.Region {
			continue
		}
		if filter.Zone != nil && e.DataResidencyZone != *filter.Zone {
			continue
		}
		result = append(result, e)
	}
	return result, nil
}

func (r *fakeEntityRepo) SoftDelete(_ context.Context, id string, deletedAt time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return ErrEntityNotFound
	}
	if e.DeletedAt != nil {
		return ErrAlreadyDeleted
	}
	e.DeletedAt = &deletedAt
	e.Status = EntityStatusDeleted
	e.Version++
	e.UpdatedAt = deletedAt
	return nil
}

func (r *fakeEntityRepo) Restore(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return ErrEntityNotFound
	}
	if e.DeletedAt == nil {
		return ErrNotDeleted
	}
	e.DeletedAt = nil
	e.Status = EntityStatusActive
	e.Version++
	e.UpdatedAt = time.Now()
	return nil
}

func (r *fakeEntityRepo) HardDelete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.entities[id]; !ok {
		return ErrEntityNotFound
	}
	delete(r.entities, id)
	return nil
}

func (r *fakeEntityRepo) ListEntities(_ context.Context, params ListEntitiesParams) (*PaginatedResult, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var filtered []*Entity
	for _, e := range r.entities {
		if e.SchemaID != params.SchemaID {
			continue
		}
		if !params.IncludeDeleted && e.DeletedAt != nil {
			continue
		}
		filtered = append(filtered, e)
	}
	return &PaginatedResult{
		Entities:   filtered,
		TotalCount: len(filtered),
	}, nil
}

type fakeOutboxRepo struct {
	events []*OutboxEvent
	mu     sync.Mutex
}

func newFakeOutboxRepo() *fakeOutboxRepo {
	return &fakeOutboxRepo{}
}

func (r *fakeOutboxRepo) Save(_ context.Context, event *OutboxEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
	return nil
}

func (r *fakeOutboxRepo) MarkPublished(_ context.Context, _ string) error { return nil }

func (r *fakeOutboxRepo) MarkFailed(_ context.Context, _ string, _ error) error { return nil }

func (r *fakeOutboxRepo) FetchPending(_ context.Context, limit int) ([]*OutboxEvent, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var pending []*OutboxEvent
	for _, e := range r.events {
		if e.Status == OutboxStatusPending {
			pending = append(pending, e)
		}
	}
	if len(pending) > limit {
		pending = pending[:limit]
	}
	return pending, nil
}

type fakeRequestIdempotency struct {
	mu     sync.RWMutex
	store  map[string]string // requestKey -> entityID
	expiry map[string]time.Time
}

func newFakeRequestIdempotency() *fakeRequestIdempotency {
	return &fakeRequestIdempotency{
		store:  make(map[string]string),
		expiry: make(map[string]time.Time),
	}
}

func (s *fakeRequestIdempotency) GetEntityID(_ context.Context, requestKey string) (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	entityID, ok := s.store[requestKey]
	if !ok {
		return "", nil
	}
	expiry, ok := s.expiry[requestKey]
	if ok && time.Now().After(expiry) {
		return "", nil
	}
	return entityID, nil
}

func (s *fakeRequestIdempotency) Save(_ context.Context, requestKey, entityID string, ttl time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.store[requestKey] = entityID
	s.expiry[requestKey] = time.Now().Add(ttl)
	return nil
}

type fakeUnitOfWork struct{}

func newFakeUnitOfWork() *fakeUnitOfWork { return &fakeUnitOfWork{} }

func (u *fakeUnitOfWork) Execute(_ context.Context, fn func(uowCtx context.Context) error) error {
	return fn(context.Background())
}

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
