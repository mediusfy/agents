package application

import (
	"context"
	"log/slog"
	"sync"
	"testing"
	"time"

	"entity-management/internal/domain"
)

// ---------------------------------------------------------------------------
// In-memory fakes for application-layer testing
// ---------------------------------------------------------------------------

type fakeUpdateSchemaRepo struct {
	mu      sync.RWMutex
	schemas map[string]*domain.EntitySchema
}

func newFakeUpdateSchemaRepo() *fakeUpdateSchemaRepo {
	return &fakeUpdateSchemaRepo{schemas: make(map[string]*domain.EntitySchema)}
}

func (r *fakeUpdateSchemaRepo) Save(_ context.Context, schema *domain.EntitySchema) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.schemas[schema.ID] = schema
	return nil
}

func (r *fakeUpdateSchemaRepo) FindByID(_ context.Context, id string) (*domain.EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	s, ok := r.schemas[id]
	if !ok {
		return nil, domain.ErrSchemaNotFound
	}
	return s, nil
}

func (r *fakeUpdateSchemaRepo) FindByName(_ context.Context, name string) (*domain.EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, s := range r.schemas {
		if s.Name == name {
			return s, nil
		}
	}
	return nil, domain.ErrSchemaNotFound
}

func (r *fakeUpdateSchemaRepo) FindAll(_ context.Context) ([]*domain.EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*domain.EntitySchema
	for _, s := range r.schemas {
		result = append(result, s)
	}
	return result, nil
}

func (r *fakeUpdateSchemaRepo) Delete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.schemas, id)
	return nil
}

type fakeUpdateEntityRepo struct {
	mu       sync.RWMutex
	entities map[string]*domain.Entity
}

func newFakeUpdateEntityRepo() *fakeUpdateEntityRepo {
	return &fakeUpdateEntityRepo{entities: make(map[string]*domain.Entity)}
}

func (r *fakeUpdateEntityRepo) Save(_ context.Context, entity *domain.Entity) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entities[entity.ID] = entity
	return nil
}

func (r *fakeUpdateEntityRepo) FindByID(_ context.Context, id string) (*domain.Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, domain.ErrEntityNotFound
	}
	return e, nil
}

func (r *fakeUpdateEntityRepo) Update(_ context.Context, id string, _ domain.UpdateOperation) (*domain.Entity, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, domain.ErrEntityNotFound
	}
	return e, nil
}

func (r *fakeUpdateEntityRepo) UpdateStatus(_ context.Context, id string, status domain.EntityStatus) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return domain.ErrEntityNotFound
	}
	if !e.Status.CanTransitionTo(status) {
		return domain.ErrInvalidStatusTransition
	}
	e.Status = status
	e.Version++
	return nil
}

func (r *fakeUpdateEntityRepo) FindBySchemaID(_ context.Context, schemaID string) ([]*domain.Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*domain.Entity
	for _, e := range r.entities {
		if e.SchemaID == schemaID {
			result = append(result, e)
		}
	}
	return result, nil
}

func (r *fakeUpdateEntityRepo) List(_ context.Context, _ domain.EntityFilter) ([]*domain.Entity, error) {
	return nil, nil
}
func (r *fakeUpdateEntityRepo) SoftDelete(_ context.Context, _ string, _ time.Time) error { return nil }
func (r *fakeUpdateEntityRepo) Restore(_ context.Context, _ string) error                 { return nil }
func (r *fakeUpdateEntityRepo) HardDelete(_ context.Context, _ string) error              { return nil }
func (r *fakeUpdateEntityRepo) ListEntities(_ context.Context, _ domain.ListEntitiesParams) (*domain.PaginatedResult, error) {
	return &domain.PaginatedResult{}, nil
}

type fakeUpdateOutboxRepo struct {
	mu     sync.Mutex
	events []*domain.OutboxEvent
}

func newFakeUpdateOutboxRepo() *fakeUpdateOutboxRepo {
	return &fakeUpdateOutboxRepo{}
}

func (r *fakeUpdateOutboxRepo) Save(_ context.Context, event *domain.OutboxEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
	return nil
}

func (r *fakeUpdateOutboxRepo) MarkPublished(_ context.Context, _ string) error       { return nil }
func (r *fakeUpdateOutboxRepo) MarkFailed(_ context.Context, _ string, _ error) error { return nil }
func (r *fakeUpdateOutboxRepo) FetchPending(_ context.Context, limit int) ([]*domain.OutboxEvent, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var pending []*domain.OutboxEvent
	for _, e := range r.events {
		if e.Status == domain.OutboxStatusPending {
			pending = append(pending, e)
		}
	}
	if len(pending) > limit {
		pending = pending[:limit]
	}
	return pending, nil
}

type fakeUpdateIdempotency struct{}

func (s *fakeUpdateIdempotency) GetEntityID(_ context.Context, _ string) (string, error) {
	return "", nil
}
func (s *fakeUpdateIdempotency) Save(_ context.Context, _, _ string, _ time.Duration) error {
	return nil
}

type fakeUpdateUnitOfWork struct{}

func (u *fakeUpdateUnitOfWork) Execute(_ context.Context, fn func(uowCtx context.Context) error) error {
	return fn(context.Background())
}

// ---------------------------------------------------------------------------
// Application-layer tests for the Gherkin scenarios
// ---------------------------------------------------------------------------

func testUpdateLogger(t *testing.T) *slog.Logger {
	t.Helper()
	return slog.New(slog.DiscardHandler)
}

// Gherkin SCENARIO 1: Happy path — successful entity update with version increment.
func TestGherkin_UpdateEntity_Success_AppLayer(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	schemaRepo := newFakeUpdateSchemaRepo()
	entityRepo := newFakeUpdateEntityRepo()
	outboxRepo := newFakeUpdateOutboxRepo()
	idempotency := &fakeUpdateIdempotency{}
	uow := &fakeUpdateUnitOfWork{}

	schemaID := "sch-customer"
	_ = schemaRepo.Save(ctx, &domain.EntitySchema{
		ID:   schemaID,
		Name: "Customer",
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
			{Name: "name", Type: domain.AttributeTypeString, Required: true},
		},
		Version: 1, CreatedAt: now.Add(-2 * time.Hour), UpdatedAt: now.Add(-2 * time.Hour),
	})

	_ = entityRepo.Save(ctx, &domain.Entity{
		ID: "ent-001", SchemaID: schemaID, Name: "Alice", Type: "customer",
		Region: "us-east-1", Status: domain.EntityStatusActive, Version: 3,
		Attributes: map[string]any{"email": "old@example.com", "name": "Alice"},
		CreatedAt:  now.Add(-1 * time.Hour), UpdatedAt: now.Add(-30 * time.Minute),
	})

	svc := domain.NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		domain.WithClock(func() time.Time { return now }),
	)
	uc := NewUpdateEntityUseCase(svc, testUpdateLogger(t))

	newName := "Alice Updated"
	req := UpdateEntityRequest{
		EntityID:        "ent-001",
		ExpectedVersion: 3,
		Name:            &newName,
		Attributes:      map[string]any{"email": "new@example.com"},
	}

	resp, err := uc.Execute(ctx, req)
	if err != nil {
		t.Fatalf("UpdateEntityUseCase.Execute failed: %v", err)
	}

	// Then the entity is updated.
	if resp.Name != "Alice Updated" {
		t.Errorf("expected name 'Alice Updated', got %q", resp.Name)
	}
	if resp.Attributes["email"] != "new@example.com" {
		t.Errorf("expected email 'new@example.com', got %v", resp.Attributes["email"])
	}
	if resp.Attributes["name"] != "Alice" {
		t.Errorf("expected original attribute 'name' = 'Alice', got %v", resp.Attributes["name"])
	}

	// And version is incremented from 3 to 4.
	if resp.Version != 4 {
		t.Errorf("expected version 4, got %d", resp.Version)
	}

	// And updated_at is refreshed.
	if resp.UpdatedAt.Before(now) {
		t.Errorf("expected updated_at >= %v, got %v", now, resp.UpdatedAt)
	}

	// And an entity.updated event is written to the outbox.
	if len(outboxRepo.events) != 1 {
		t.Fatalf("expected 1 outbox event, got %d", len(outboxRepo.events))
	}
	if outboxRepo.events[0].EventType != (&domain.EntityUpdated{}).EventName() {
		t.Errorf("expected event type %q, got %q",
			(&domain.EntityUpdated{}).EventName(), outboxRepo.events[0].EventType)
	}
}

// Gherkin SCENARIO 2: Stale version — concurrent modification detection.
func TestGherkin_UpdateEntity_StaleVersion_AppLayer(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	schemaRepo := newFakeUpdateSchemaRepo()
	entityRepo := newFakeUpdateEntityRepo()
	outboxRepo := newFakeUpdateOutboxRepo()
	idempotency := &fakeUpdateIdempotency{}
	uow := &fakeUpdateUnitOfWork{}

	schemaID := "sch-customer"
	_ = schemaRepo.Save(ctx, &domain.EntitySchema{
		ID: schemaID, Name: "Customer",
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
			{Name: "name", Type: domain.AttributeTypeString, Required: true},
		},
		Version: 1, CreatedAt: now.Add(-2 * time.Hour), UpdatedAt: now.Add(-2 * time.Hour),
	})

	// Entity is at version 4 (concurrent update already happened).
	_ = entityRepo.Save(ctx, &domain.Entity{
		ID: "ent-001", SchemaID: schemaID, Name: "Alice Updated", Type: "customer",
		Region: "us-east-1", Status: domain.EntityStatusActive, Version: 4,
		Attributes: map[string]any{"email": "new@example.com", "name": "Alice Updated"},
		CreatedAt:  now.Add(-1 * time.Hour), UpdatedAt: now,
	})

	svc := domain.NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		domain.WithClock(func() time.Time { return now }),
	)
	uc := NewUpdateEntityUseCase(svc, testUpdateLogger(t))

	// When a PUT request is sent with expected_version=3 (stale).
	newName := "Alice v3"
	req := UpdateEntityRequest{
		EntityID:        "ent-001",
		ExpectedVersion: 3,
		Name:            &newName,
	}

	_, err := uc.Execute(ctx, req)
	if err == nil {
		t.Fatal("expected ErrStaleVersion, got nil")
	}

	// No data is modified.
	unchanged, _ := entityRepo.FindByID(ctx, "ent-001")
	if unchanged.Version != 4 {
		t.Errorf("expected version to remain 4, got %d", unchanged.Version)
	}
	if unchanged.Name != "Alice Updated" {
		t.Errorf("expected name to remain 'Alice Updated', got %q", unchanged.Name)
	}

	// No outbox events.
	if len(outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events, got %d", len(outboxRepo.events))
	}
}

// Gherkin SCENARIO 3: Immutable field — rejection of changes to protected fields.
func TestGherkin_UpdateEntity_ImmutableField_AppLayer(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	schemaRepo := newFakeUpdateSchemaRepo()
	entityRepo := newFakeUpdateEntityRepo()
	outboxRepo := newFakeUpdateOutboxRepo()
	idempotency := &fakeUpdateIdempotency{}
	uow := &fakeUpdateUnitOfWork{}

	schemaID := "sch-customer"
	_ = schemaRepo.Save(ctx, &domain.EntitySchema{
		ID: schemaID, Name: "Customer",
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
			{Name: "name", Type: domain.AttributeTypeString, Required: true},
		},
		Version: 1, CreatedAt: now.Add(-2 * time.Hour), UpdatedAt: now.Add(-2 * time.Hour),
	})

	// Entity at version 3 in us-east-1.
	_ = entityRepo.Save(ctx, &domain.Entity{
		ID: "ent-001", SchemaID: schemaID, Name: "Alice", Type: "customer",
		Region: "us-east-1", DataResidencyZone: domain.ZoneUSEast1,
		Status: domain.EntityStatusActive, Version: 3,
		Attributes: map[string]any{"email": "alice@example.com", "name": "Alice"},
		CreatedAt:  now.Add(-1 * time.Hour), UpdatedAt: now.Add(-30 * time.Minute),
	})

	svc := domain.NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		domain.WithClock(func() time.Time { return now }),
	)
	uc := NewUpdateEntityUseCase(svc, testUpdateLogger(t))

	// When a PUT request includes an immutable field change like "region".
	newRegion := "eu-west-1"
	req := UpdateEntityRequest{
		EntityID:        "ent-001",
		ExpectedVersion: 3,
		Region:          &newRegion,
	}

	_, err := uc.Execute(ctx, req)
	if err == nil {
		t.Fatal("expected ErrImmutableField, got nil")
	}

	// No changes are persisted.
	unchanged, _ := entityRepo.FindByID(ctx, "ent-001")
	if unchanged.Region != "us-east-1" {
		t.Errorf("expected region to remain 'us-east-1', got %q", unchanged.Region)
	}
	if unchanged.Version != 3 {
		t.Errorf("expected version to remain 3, got %d", unchanged.Version)
	}

	// No outbox events.
	if len(outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events, got %d", len(outboxRepo.events))
	}
}
