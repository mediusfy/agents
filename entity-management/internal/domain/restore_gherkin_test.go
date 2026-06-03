package domain

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// =============================================================================
// Gherkin: Soft-Delete Restore Lifecycle
//
// SCENARIO 1 — Successful restore of soft-deleted entity
//   Given entity "ent-001" is soft-deleted
//     (deleted_at = "2024-01-15T10:00:00Z", status="deleted")
//   When a POST /api/v1/entities/ent-001/restore request is sent
//   Then deleted_at is cleared (set to NULL)
//     And status transitions to "active"
//     And an entitymanagement.entity.restored event is written to the outbox
//     And HTTP 200 is returned with
//       {"status": "restored", "entity_id": "ent-001"}
//     And the entity is now visible in standard list queries
//
// SCENARIO 2 — Restore attempted on active entity
//   Given entity "ent-002" is active (deleted_at is NULL)
//   When a restore is attempted on entity "ent-002"
//   Then ErrNotDeleted is returned (HTTP 400)
//     And message: "entity is not soft-deleted"
//     And no data is modified
//     And no entity.restored event is emitted
// =============================================================================

// ---------------------------------------------------------------------------
// Fake repos for restore tests
//
// IMPORTANT: FindByID returns a COPY of the entity to simulate database
// semantics where in-memory mutations (ApplyRestore) do not automatically
// propagate to the stored record until explicitly saved.
// ---------------------------------------------------------------------------

type fakeRestoreSchemaRepo struct {
	mu      sync.RWMutex
	schemas map[string]*EntitySchema
}

func newFakeRestoreSchemaRepo() *fakeRestoreSchemaRepo {
	return &fakeRestoreSchemaRepo{schemas: make(map[string]*EntitySchema)}
}

func (r *fakeRestoreSchemaRepo) Save(_ context.Context, schema *EntitySchema) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	cp := *schema
	r.schemas[schema.ID] = &cp
	return nil
}

func (r *fakeRestoreSchemaRepo) FindByID(_ context.Context, id string) (*EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	s, ok := r.schemas[id]
	if !ok {
		return nil, ErrSchemaNotFound
	}
	cp := *s
	return &cp, nil
}

func (r *fakeRestoreSchemaRepo) FindByName(_ context.Context, name string) (*EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, s := range r.schemas {
		if s.Name == name {
			cp := *s
			return &cp, nil
		}
	}
	return nil, ErrSchemaNotFound
}

func (r *fakeRestoreSchemaRepo) FindAll(_ context.Context) ([]*EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*EntitySchema
	for _, s := range r.schemas {
		cp := *s
		result = append(result, &cp)
	}
	return result, nil
}

func (r *fakeRestoreSchemaRepo) Delete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.schemas, id)
	return nil
}

// clock-aware entity repo that uses a function to get the current time
// so tests can freeze time.
type fakeRestoreEntityRepo struct {
	mu       sync.RWMutex
	entities map[string]*Entity
	now      func() time.Time
}

func newFakeRestoreEntityRepo() *fakeRestoreEntityRepo {
	return &fakeRestoreEntityRepo{
		entities: make(map[string]*Entity),
		now:      time.Now,
	}
}

func (r *fakeRestoreEntityRepo) withClock(now func() time.Time) *fakeRestoreEntityRepo {
	r.now = now
	return r
}

func (r *fakeRestoreEntityRepo) Save(_ context.Context, entity *Entity) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	cp := copyEntity(entity)
	r.entities[entity.ID] = cp
	return nil
}

func (r *fakeRestoreEntityRepo) FindByID(_ context.Context, id string) (*Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, ErrEntityNotFound
	}
	return copyEntity(e), nil
}

func (r *fakeRestoreEntityRepo) Update(_ context.Context, id string, op UpdateOperation) (*Entity, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, ErrEntityNotFound
	}
	if err := e.ApplyUpdate(op); err != nil {
		return nil, err
	}
	return copyEntity(e), nil
}

func (r *fakeRestoreEntityRepo) UpdateStatus(_ context.Context, id string, status EntityStatus) error {
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

func (r *fakeRestoreEntityRepo) FindBySchemaID(_ context.Context, schemaID string) ([]*Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*Entity
	for _, e := range r.entities {
		if e.SchemaID == schemaID {
			result = append(result, copyEntity(e))
		}
	}
	return result, nil
}

func (r *fakeRestoreEntityRepo) List(_ context.Context, filter EntityFilter) ([]*Entity, error) {
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
		result = append(result, copyEntity(e))
	}
	return result, nil
}

func (r *fakeRestoreEntityRepo) SoftDelete(_ context.Context, id string, deletedAt time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return ErrEntityNotFound
	}
	if e.DeletedAt != nil {
		return ErrAlreadyDeleted
	}
	e.Status = EntityStatusDeleted
	e.DeletedAt = &deletedAt
	e.Version++
	e.UpdatedAt = deletedAt
	return nil
}

func (r *fakeRestoreEntityRepo) Restore(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return ErrEntityNotFound
	}
	if e.DeletedAt == nil {
		return ErrNotDeleted
	}
	now := r.now()
	e.DeletedAt = nil
	e.Status = EntityStatusActive
	e.Version++
	e.UpdatedAt = now
	return nil
}

func (r *fakeRestoreEntityRepo) HardDelete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.entities[id]; !ok {
		return ErrEntityNotFound
	}
	delete(r.entities, id)
	return nil
}

func (r *fakeRestoreEntityRepo) ListEntities(_ context.Context, params ListEntitiesParams) (*PaginatedResult, error) {
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
		filtered = append(filtered, copyEntity(e))
	}
	return &PaginatedResult{
		Entities:   filtered,
		TotalCount: len(filtered),
	}, nil
}

// copyEntity creates a shallow copy of an Entity with a deep copy of
// pointer fields (DeletedAt) to prevent cross-test contamination.
func copyEntity(e *Entity) *Entity {
	cp := *e
	if e.DeletedAt != nil {
		d := *e.DeletedAt
		cp.DeletedAt = &d
	}
	return &cp
}

type fakeRestoreOutboxRepo struct {
	mu     sync.Mutex
	events []*OutboxEvent
}

func newFakeRestoreOutboxRepo() *fakeRestoreOutboxRepo {
	return &fakeRestoreOutboxRepo{}
}

func (r *fakeRestoreOutboxRepo) Save(_ context.Context, event *OutboxEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
	return nil
}

func (r *fakeRestoreOutboxRepo) MarkPublished(_ context.Context, _ string) error { return nil }

func (r *fakeRestoreOutboxRepo) MarkFailed(_ context.Context, _ string, _ error) error { return nil }

func (r *fakeRestoreOutboxRepo) FetchPending(_ context.Context, limit int) ([]*OutboxEvent, error) {
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

type fakeRestoreIdempotency struct {
	mu     sync.RWMutex
	store  map[string]string
	expiry map[string]time.Time
}

func newFakeRestoreIdempotency() *fakeRestoreIdempotency {
	return &fakeRestoreIdempotency{
		store:  make(map[string]string),
		expiry: make(map[string]time.Time),
	}
}

func (s *fakeRestoreIdempotency) GetEntityID(_ context.Context, requestKey string) (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	entityID, ok := s.store[requestKey]
	if !ok {
		return "", nil
	}
	return entityID, nil
}

func (s *fakeRestoreIdempotency) Save(_ context.Context, requestKey, entityID string, ttl time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.store[requestKey] = entityID
	s.expiry[requestKey] = time.Now().Add(ttl)
	return nil
}

type fakeRestoreUOW struct{}

func newFakeRestoreUOW() *fakeRestoreUOW { return &fakeRestoreUOW{} }

func (u *fakeRestoreUOW) Execute(_ context.Context, fn func(uowCtx context.Context) error) error {
	return fn(context.Background())
}

type fakeRestoreEventBus struct {
	mu     sync.Mutex
	events []*EntityRestored
}

func newFakeRestoreEventBus() *fakeRestoreEventBus {
	return &fakeRestoreEventBus{}
}

func (b *fakeRestoreEventBus) PublishSchemaDefined(_ context.Context, _ *EntitySchemaDefined) error {
	return nil
}
func (b *fakeRestoreEventBus) PublishSchemaUpdated(_ context.Context, _ *EntitySchemaUpdated) error {
	return nil
}
func (b *fakeRestoreEventBus) PublishEntityCreated(_ context.Context, _ *EntityCreated) error {
	return nil
}
func (b *fakeRestoreEventBus) PublishEntityUpdated(_ context.Context, _ *EntityUpdated) error {
	return nil
}
func (b *fakeRestoreEventBus) PublishEntityDeleted(_ context.Context, _ *EntityDeleted) error {
	return nil
}
func (b *fakeRestoreEventBus) PublishEntityRead(_ context.Context, _ *EntityRead) error {
	return nil
}
func (b *fakeRestoreEventBus) PublishEntitySoftDeleted(_ context.Context, _ *EntitySoftDeleted) error {
	return nil
}
func (b *fakeRestoreEventBus) PublishEntityHardDeleted(_ context.Context, _ *EntityHardDeleted) error {
	return nil
}
func (b *fakeRestoreEventBus) PublishEntityRestored(_ context.Context, event *EntityRestored) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.events = append(b.events, event)
	return nil
}
func (b *fakeRestoreEventBus) PublishEntitiesQueried(_ context.Context, _ *EntitiesQueried) error {
	return nil
}
func (b *fakeRestoreEventBus) PublishInvalidCursorProvided(_ context.Context, _ *InvalidCursorProvided) error {
	return nil
}
func (b *fakeRestoreEventBus) PublishAppStarted(_ context.Context, _ *AppStarted) error {
	return nil
}
func (b *fakeRestoreEventBus) PublishAppStartupFailed(_ context.Context, _ *AppStartupFailed) error {
	return nil
}

type failingRestoreEventPublisher struct {
	called bool
}

func (f *failingRestoreEventPublisher) PublishSchemaDefined(_ context.Context, _ *EntitySchemaDefined) error {
	return nil
}
func (f *failingRestoreEventPublisher) PublishSchemaUpdated(_ context.Context, _ *EntitySchemaUpdated) error {
	return nil
}
func (f *failingRestoreEventPublisher) PublishEntityCreated(_ context.Context, _ *EntityCreated) error {
	return nil
}
func (f *failingRestoreEventPublisher) PublishEntityUpdated(_ context.Context, _ *EntityUpdated) error {
	return nil
}
func (f *failingRestoreEventPublisher) PublishEntityDeleted(_ context.Context, _ *EntityDeleted) error {
	return nil
}
func (f *failingRestoreEventPublisher) PublishEntityRead(_ context.Context, _ *EntityRead) error {
	return nil
}
func (f *failingRestoreEventPublisher) PublishEntitySoftDeleted(_ context.Context, _ *EntitySoftDeleted) error {
	return nil
}
func (f *failingRestoreEventPublisher) PublishEntityHardDeleted(_ context.Context, _ *EntityHardDeleted) error {
	return nil
}
func (f *failingRestoreEventPublisher) PublishEntityRestored(_ context.Context, _ *EntityRestored) error {
	f.called = true
	return errors.New("nats: connection refused")
}
func (f *failingRestoreEventPublisher) PublishEntitiesQueried(_ context.Context, _ *EntitiesQueried) error {
	return nil
}
func (f *failingRestoreEventPublisher) PublishInvalidCursorProvided(_ context.Context, _ *InvalidCursorProvided) error {
	return nil
}
func (f *failingRestoreEventPublisher) PublishAppStarted(_ context.Context, _ *AppStarted) error {
	return nil
}
func (f *failingRestoreEventPublisher) PublishAppStartupFailed(_ context.Context, _ *AppStartupFailed) error {
	return nil
}

// ---------------------------------------------------------------------------
// SCENARIO 1: Successful Restore of Soft-Deleted Entity
// ---------------------------------------------------------------------------

func TestGherkin_Restore_ClearsDeletedAt_TransitionsToActive_EmitsEvent(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	frozenNow := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)

	schemaRepo := newFakeRestoreSchemaRepo()
	entityRepo := newFakeRestoreEntityRepo().withClock(func() time.Time { return frozenNow })
	outboxRepo := newFakeRestoreOutboxRepo()
	idempotency := newFakeRestoreIdempotency()
	uow := newFakeRestoreUOW()
	eventBus := newFakeRestoreEventBus()

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

	// Given entity "ent-001" is soft-deleted
	// (deleted_at = "2024-01-15T10:00:00Z", status="deleted")
	softDeletedAt := time.Date(2024, 1, 15, 10, 0, 0, 0, time.UTC)
	originalEntity := &Entity{
		ID:        "ent-001",
		SchemaID:  schemaID,
		Name:      "RestorableEntity",
		Type:      "customer",
		Region:    "us-east-1",
		Status:    EntityStatusDeleted,
		Version:   2,
		DeletedAt: &softDeletedAt,
		CreatedAt: frozenNow.Add(-2 * time.Hour),
		UpdatedAt: softDeletedAt,
	}
	if err := entityRepo.Save(ctx, originalEntity); err != nil {
		t.Fatalf("save entity: %v", err)
	}

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return frozenNow }),
		WithEvents(eventBus),
	)

	// When a restore is performed
	if err := svc.RestoreEntity(ctx, "ent-001"); err != nil {
		t.Fatalf("RestoreEntity failed: %v", err)
	}

	// Then deleted_at is cleared (set to NULL)
	updated, err := entityRepo.FindByID(ctx, "ent-001")
	if err != nil {
		t.Fatalf("FindByID after restore: %v", err)
	}
	if updated.DeletedAt != nil {
		t.Fatalf("expected deleted_at to be nil after restore, got %v", *updated.DeletedAt)
	}

	// And status transitions to "active"
	if updated.Status != EntityStatusActive {
		t.Errorf("expected status 'active', got %q", updated.Status)
	}

	// And version is incremented from 2 to 3
	if updated.Version != 3 {
		t.Errorf("expected version 3 after restore, got %d", updated.Version)
	}

	// And updated_at is refreshed to frozenNow
	if !updated.UpdatedAt.Equal(frozenNow) {
		t.Errorf("expected updated_at=%v, got %v", frozenNow, updated.UpdatedAt)
	}

	// And an entitymanagement.entity.restored event is written to the outbox
	if len(outboxRepo.events) != 1 {
		t.Fatalf("expected 1 outbox event, got %d", len(outboxRepo.events))
	}

	outboxEvent := outboxRepo.events[0]
	expectedEventType := (&EntityRestored{}).EventName()
	if outboxEvent.EventType != expectedEventType {
		t.Errorf("expected outbox event type %q, got %q", expectedEventType, outboxEvent.EventType)
	}
	if outboxEvent.Status != OutboxStatusPending {
		t.Errorf("expected outbox status 'pending', got %q", outboxEvent.Status)
	}
	if outboxEvent.AggregateID != "ent-001" {
		t.Errorf("expected aggregate_id 'ent-001', got %q", outboxEvent.AggregateID)
	}
	if outboxEvent.AggregateType != "entity" {
		t.Errorf("expected aggregate_type 'entity', got %q", outboxEvent.AggregateType)
	}

	// Verify the event bus received the EntityRestored event
	if len(eventBus.events) != 1 {
		t.Fatalf("expected 1 event bus event, got %d", len(eventBus.events))
	}
	if eventBus.events[0].EntityID != "ent-001" {
		t.Errorf("expected event entity_id 'ent-001', got %q", eventBus.events[0].EntityID)
	}
	if eventBus.events[0].EntityName != "RestorableEntity" {
		t.Errorf("expected event entity_name 'RestorableEntity', got %q", eventBus.events[0].EntityName)
	}
	if eventBus.events[0].Region != "us-east-1" {
		t.Errorf("expected event region 'us-east-1', got %q", eventBus.events[0].Region)
	}
	if eventBus.events[0].EventID == "" {
		t.Error("expected event EventID to be non-empty")
	}

	// And the entity is now visible in standard list queries (include_deleted=false)
	listResult, err := entityRepo.ListEntities(ctx, ListEntitiesParams{
		SchemaID:       schemaID,
		IncludeDeleted: false,
	})
	if err != nil {
		t.Fatalf("ListEntities failed: %v", err)
	}

	found := false
	for _, e := range listResult.Entities {
		if e.ID == "ent-001" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected restored entity 'ent-001' to be visible in standard list queries")
	}

	if listResult.TotalCount != 1 {
		t.Errorf("expected TotalCount=1, got %d", listResult.TotalCount)
	}
}

// ---------------------------------------------------------------------------
// SCENARIO 2: Restore Attempted on Active Entity
// ---------------------------------------------------------------------------

func TestGherkin_Restore_ActiveEntity_ReturnsErrNotDeleted(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	frozenNow := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)

	schemaRepo := newFakeRestoreSchemaRepo()
	entityRepo := newFakeRestoreEntityRepo().withClock(func() time.Time { return frozenNow })
	outboxRepo := newFakeRestoreOutboxRepo()
	idempotency := newFakeRestoreIdempotency()
	uow := newFakeRestoreUOW()
	eventBus := newFakeRestoreEventBus()

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

	// Given entity "ent-002" is active (deleted_at is NULL)
	originalEntity := &Entity{
		ID:        "ent-002",
		SchemaID:  schemaID,
		Name:      "ActiveEntity",
		Type:      "customer",
		Region:    "eu-west-1",
		Status:    EntityStatusActive,
		Version:   1,
		DeletedAt: nil,
		CreatedAt: frozenNow.Add(-2 * time.Hour),
		UpdatedAt: frozenNow.Add(-1 * time.Hour),
	}
	if err := entityRepo.Save(ctx, originalEntity); err != nil {
		t.Fatalf("save entity: %v", err)
	}

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return frozenNow }),
		WithEvents(eventBus),
	)

	// When a restore is attempted on entity "ent-002"
	err := svc.RestoreEntity(ctx, "ent-002")

	// Then ErrNotDeleted is returned
	if err == nil {
		t.Fatal("expected ErrNotDeleted, got nil")
	}
	if !errors.Is(err, ErrNotDeleted) {
		t.Errorf("expected ErrNotDeleted, got %v", err)
	}

	// And message: "entity is not soft-deleted"
	if err.Error() != "restore: entity is not soft-deleted" {
		t.Errorf("expected error message 'restore: entity is not soft-deleted', got %q", err.Error())
	}

	// And no data is modified
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
	if saved.Name != "ActiveEntity" {
		t.Errorf("expected name to remain 'ActiveEntity', got %q", saved.Name)
	}
	if !saved.CreatedAt.Equal(frozenNow.Add(-2 * time.Hour)) {
		t.Errorf("expected created_at to remain unchanged")
	}
	if !saved.UpdatedAt.Equal(frozenNow.Add(-1 * time.Hour)) {
		t.Errorf("expected updated_at to remain unchanged")
	}

	// And no entity.restored event is emitted
	if len(outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events for failed restore, got %d", len(outboxRepo.events))
	}
	if len(eventBus.events) != 0 {
		t.Errorf("expected 0 event bus events for failed restore, got %d", len(eventBus.events))
	}

	// And the entity is still visible in standard list queries
	listResult, err := entityRepo.ListEntities(ctx, ListEntitiesParams{
		SchemaID:       schemaID,
		IncludeDeleted: false,
	})
	if err != nil {
		t.Fatalf("ListEntities failed: %v", err)
	}

	found := false
	for _, e := range listResult.Entities {
		if e.ID == "ent-002" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected active entity 'ent-002' to still be visible in list queries")
	}
	if listResult.TotalCount != 1 {
		t.Errorf("expected TotalCount=1, got %d", listResult.TotalCount)
	}
}

// ---------------------------------------------------------------------------
// SCENARIO 3: Restore Attempted on Nonexistent Entity
// ---------------------------------------------------------------------------

func TestGherkin_Restore_NonExistentEntity_ReturnsErrEntityNotFound(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	frozenNow := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)

	schemaRepo := newFakeRestoreSchemaRepo()
	entityRepo := newFakeRestoreEntityRepo().withClock(func() time.Time { return frozenNow })
	outboxRepo := newFakeRestoreOutboxRepo()
	idempotency := newFakeRestoreIdempotency()
	uow := newFakeRestoreUOW()
	eventBus := newFakeRestoreEventBus()

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

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return frozenNow }),
		WithEvents(eventBus),
	)

	err := svc.RestoreEntity(ctx, "ent-999")
	if err == nil {
		t.Fatal("expected error for non-existent entity, got nil")
	}
	if !errors.Is(err, ErrEntityNotFound) {
		t.Errorf("expected ErrEntityNotFound, got %v", err)
	}
	if len(outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events, got %d", len(outboxRepo.events))
	}
	if len(eventBus.events) != 0 {
		t.Errorf("expected 0 event bus events, got %d", len(eventBus.events))
	}
}

// ---------------------------------------------------------------------------
// Table-driven: Restore Boundary Conditions
// ---------------------------------------------------------------------------

func TestGherkin_Restore_TableDriven(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	frozenNow := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)
	softDeletedAt := frozenNow.Add(-1 * time.Hour)

	type fields struct {
		initialStatus EntityStatus
		deletedAt     *time.Time
		initialVer    int
	}

	type testCase struct {
		name        string
		fields      fields
		entityID    string
		wantErr     error
		wantStatus  EntityStatus
		wantVersion int
		wantCleared bool
		wantEvent   bool
		wantVisible bool
	}

	tests := []testCase{
		{
			name: "soft-deleted entity restore succeeds",
			fields: fields{
				initialStatus: EntityStatusDeleted,
				deletedAt:     &softDeletedAt,
				initialVer:    2,
			},
			entityID:    "ent-restore-success",
			wantErr:     nil,
			wantStatus:  EntityStatusActive,
			wantVersion: 3,
			wantCleared: true,
			wantEvent:   true,
			wantVisible: true,
		},
		{
			name: "active entity restore returns ErrNotDeleted",
			fields: fields{
				initialStatus: EntityStatusActive,
				deletedAt:     nil,
				initialVer:    1,
			},
			entityID:    "ent-active-restore-fail",
			wantErr:     ErrNotDeleted,
			wantStatus:  EntityStatusActive,
			wantVersion: 1,
			wantCleared: false,
			wantEvent:   false,
			wantVisible: true,
		},
		{
			name: "inactive entity restore returns ErrNotDeleted",
			fields: fields{
				initialStatus: EntityStatusInactive,
				deletedAt:     nil,
				initialVer:    1,
			},
			entityID:    "ent-inactive-restore-fail",
			wantErr:     ErrNotDeleted,
			wantStatus:  EntityStatusInactive,
			wantVersion: 1,
			wantCleared: false,
			wantEvent:   false,
			wantVisible: true,
		},
		{
			name: "already restored entity restore returns ErrNotDeleted",
			fields: fields{
				initialStatus: EntityStatusActive,
				deletedAt:     nil,
				initialVer:    3,
			},
			entityID:    "ent-already-restored",
			wantErr:     ErrNotDeleted,
			wantStatus:  EntityStatusActive,
			wantVersion: 3,
			wantCleared: false,
			wantEvent:   false,
			wantVisible: true,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			schemaRepo := newFakeRestoreSchemaRepo()
			entityRepo := newFakeRestoreEntityRepo().withClock(func() time.Time { return frozenNow })
			outboxRepo := newFakeRestoreOutboxRepo()
			idempotency := newFakeRestoreIdempotency()
			uow := newFakeRestoreUOW()
			eventBus := newFakeRestoreEventBus()

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
				ID:        tt.entityID,
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
				WithEvents(eventBus),
			)

			err := svc.RestoreEntity(ctx, tt.entityID)

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

			updated, lookupErr := entityRepo.FindByID(ctx, tt.entityID)
			if lookupErr != nil {
				t.Fatalf("FindByID: %v", lookupErr)
			}

			if updated.Status != tt.wantStatus {
				t.Errorf("expected status %q, got %q", tt.wantStatus, updated.Status)
			}
			if updated.Version != tt.wantVersion {
				t.Errorf("expected version %d, got %d", tt.wantVersion, updated.Version)
			}
			if tt.wantCleared && updated.DeletedAt != nil {
				t.Errorf("expected deleted_at to be nil, got %v", *updated.DeletedAt)
			}
			if !tt.wantCleared && updated.DeletedAt != nil {
				t.Errorf("expected deleted_at to remain nil, got %v", *updated.DeletedAt)
			}

			if tt.wantEvent && len(outboxRepo.events) != 1 {
				t.Errorf("expected 1 outbox event, got %d", len(outboxRepo.events))
			}
			if !tt.wantEvent && len(outboxRepo.events) != 0 {
				t.Errorf("expected 0 outbox events, got %d", len(outboxRepo.events))
			}
			if tt.wantEvent && len(eventBus.events) != 1 {
				t.Errorf("expected 1 event bus event, got %d", len(eventBus.events))
			}
			if !tt.wantEvent && len(eventBus.events) != 0 {
				t.Errorf("expected 0 event bus events, got %d", len(eventBus.events))
			}

			if tt.wantVisible {
				listResult, listErr := entityRepo.ListEntities(ctx, ListEntitiesParams{
					SchemaID:       schemaID,
					IncludeDeleted: false,
				})
				if listErr != nil {
					t.Fatalf("ListEntities: %v", listErr)
				}
				found := false
				for _, e := range listResult.Entities {
					if e.ID == tt.entityID {
						found = true
						break
					}
				}
				if !found {
					t.Errorf("expected entity %q to be visible in standard list", tt.entityID)
				}
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Unit-level test: Entity.ApplyRestore
// ---------------------------------------------------------------------------

func TestGherkin_Restore_ApplyRestore_Unit(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	softDeletedAt := now.Add(-1 * time.Hour)

	t.Run("apply restore clears deleted_at and sets status to active", func(t *testing.T) {
		e := &Entity{
			ID:        "ent-001",
			Status:    EntityStatusDeleted,
			Version:   2,
			DeletedAt: &softDeletedAt,
		}

		e.ApplyRestore(now)

		if e.DeletedAt != nil {
			t.Error("expected deleted_at to be nil after ApplyRestore")
		}
		if e.Status != EntityStatusActive {
			t.Errorf("expected status 'active', got %q", e.Status)
		}
		if e.Version != 3 {
			t.Errorf("expected version 3, got %d", e.Version)
		}
		if !e.UpdatedAt.Equal(now) {
			t.Errorf("expected updated_at=%v, got %v", now, e.UpdatedAt)
		}
	})

	t.Run("is soft deleted returns false after apply restore", func(t *testing.T) {
		e := &Entity{
			ID:        "ent-003",
			Status:    EntityStatusDeleted,
			DeletedAt: &softDeletedAt,
		}

		e.ApplyRestore(now)

		if e.IsSoftDeleted() {
			t.Error("expected IsSoftDeleted to return false after ApplyRestore")
		}
	})

	t.Run("apply restore increments version correctly", func(t *testing.T) {
		e := &Entity{
			ID:        "ent-004",
			Status:    EntityStatusDeleted,
			Version:   5,
			DeletedAt: &softDeletedAt,
		}

		e.ApplyRestore(now)

		if e.Version != 6 {
			t.Errorf("expected version 6, got %d", e.Version)
		}
	})
}

// ---------------------------------------------------------------------------
// Edge case: Double restore
// ---------------------------------------------------------------------------

func TestGherkin_Restore_DoubleRestore_ReturnsErrNotDeleted(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	frozenNow := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)

	schemaRepo := newFakeRestoreSchemaRepo()
	entityRepo := newFakeRestoreEntityRepo().withClock(func() time.Time { return frozenNow })
	outboxRepo := newFakeRestoreOutboxRepo()
	idempotency := newFakeRestoreIdempotency()
	uow := newFakeRestoreUOW()
	eventBus := newFakeRestoreEventBus()

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

	softDeletedAt := frozenNow.Add(-2 * time.Hour)
	entity := &Entity{
		ID:        "ent-double-restore",
		SchemaID:  schemaID,
		Name:      "DoubleRestoreEntity",
		Type:      "customer",
		Region:    "eu-west-1",
		Status:    EntityStatusDeleted,
		Version:   2,
		DeletedAt: &softDeletedAt,
		CreatedAt: frozenNow.Add(-3 * time.Hour),
		UpdatedAt: softDeletedAt,
	}
	if err := entityRepo.Save(ctx, entity); err != nil {
		t.Fatalf("save entity: %v", err)
	}

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return frozenNow }),
		WithEvents(eventBus),
	)

	// First restore succeeds
	if err := svc.RestoreEntity(ctx, "ent-double-restore"); err != nil {
		t.Fatalf("first RestoreEntity failed: %v", err)
	}

	if len(outboxRepo.events) != 1 {
		t.Fatalf("expected 1 outbox event after first restore, got %d", len(outboxRepo.events))
	}

	// Second restore should fail
	err := svc.RestoreEntity(ctx, "ent-double-restore")
	if err == nil {
		t.Fatal("expected ErrNotDeleted for second restore, got nil")
	}
	if !errors.Is(err, ErrNotDeleted) {
		t.Errorf("expected ErrNotDeleted, got %v", err)
	}

	if len(outboxRepo.events) != 1 {
		t.Errorf("expected still 1 outbox event after failed second restore, got %d", len(outboxRepo.events))
	}
	if len(eventBus.events) != 1 {
		t.Errorf("expected 1 event bus event after first restore only, got %d", len(eventBus.events))
	}

	updated, _ := entityRepo.FindByID(ctx, "ent-double-restore")
	if updated.Status != EntityStatusActive {
		t.Errorf("expected status to remain 'active', got %q", updated.Status)
	}
	if updated.DeletedAt != nil {
		t.Errorf("expected deleted_at to remain nil, got %v", updated.DeletedAt)
	}
	if updated.Version != 3 {
		t.Errorf("expected version to remain 3, got %d", updated.Version)
	}
}

// ---------------------------------------------------------------------------
// Edge case: EventPublisher failure is non-fatal
// ---------------------------------------------------------------------------

func TestGherkin_Restore_EventPublisherFailureIsNonFatal(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	frozenNow := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)

	schemaRepo := newFakeRestoreSchemaRepo()
	entityRepo := newFakeRestoreEntityRepo().withClock(func() time.Time { return frozenNow })
	outboxRepo := newFakeRestoreOutboxRepo()
	idempotency := newFakeRestoreIdempotency()
	uow := newFakeRestoreUOW()

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

	softDeletedAt := frozenNow.Add(-2 * time.Hour)
	_ = entityRepo.Save(ctx, &Entity{
		ID:        "ent-event-fail",
		SchemaID:  schemaID,
		Name:      "EventFailEntity",
		Type:      "customer",
		Region:    "us-east-1",
		Status:    EntityStatusDeleted,
		Version:   2,
		DeletedAt: &softDeletedAt,
		CreatedAt: frozenNow.Add(-3 * time.Hour),
		UpdatedAt: softDeletedAt,
	})

	failingPub := &failingRestoreEventPublisher{}

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return frozenNow }),
		WithEvents(failingPub),
	)

	err := svc.RestoreEntity(ctx, "ent-event-fail")
	if err != nil {
		t.Fatalf("expected restore to succeed despite event publisher failure, got: %v", err)
	}

	updated, _ := entityRepo.FindByID(ctx, "ent-event-fail")
	if updated.DeletedAt != nil {
		t.Error("expected deleted_at to be cleared despite event publisher failure")
	}
	if updated.Status != EntityStatusActive {
		t.Errorf("expected status 'active', got %q", updated.Status)
	}

	if len(outboxRepo.events) != 1 {
		t.Errorf("expected 1 outbox event despite event publisher failure, got %d", len(outboxRepo.events))
	}
	if outboxRepo.events[0].EventType != (&EntityRestored{}).EventName() {
		t.Errorf("expected outbox event type %q, got %q",
			(&EntityRestored{}).EventName(), outboxRepo.events[0].EventType)
	}

	if !failingPub.called {
		t.Error("expected PublishEntityRestored to have been called")
	}
}
