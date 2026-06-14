package application

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"testing"
	"time"

	"entity-management/internal/domain"
)

// ---------------------------------------------------------------------------
// Fake adapters for DeleteRestoreUseCase testing.
// ---------------------------------------------------------------------------

// fakeHardDeleteService implements a controllable domain.Service-like stub
// for the HardDeleteEntity path. We define it as a minimal interface to
// decouple application-layer tests from the full domain.Service.
type hardDeleteService interface {
	HardDeleteEntity(ctx context.Context, id string) error
}

// fakeHardDeleteSvc is a controllable stub that lets us inject errors and
// verify it was called with the correct ID.
type fakeHardDeleteSvc struct {
	mu          sync.Mutex
	hardDeleted map[string]bool
	err         error // if set, all calls return this error
}

func newFakeHardDeleteSvc() *fakeHardDeleteSvc {
	return &fakeHardDeleteSvc{
		hardDeleted: make(map[string]bool),
	}
}

func (s *fakeHardDeleteSvc) HardDeleteEntity(ctx context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.err != nil {
		return s.err
	}
	s.hardDeleted[id] = true
	return nil
}

// hardDeleteTestLogger returns a discarding logger for tests.
func hardDeleteTestLogger(t *testing.T) *slog.Logger {
	t.Helper()
	return slog.New(slog.DiscardHandler)
}

// ---------------------------------------------------------------------------
// Gherkin SCENARIO 1:
//   Given entity "ent-001" is soft-deleted (deleted_at set, status="deleted")
//   When  a hard-delete is executed via the use case
//   Then  the domain service HardDeleteEntity is called with "ent-001"
//         And no error is returned
// ---------------------------------------------------------------------------

func TestUseCaseHardDelete_SoftDeletedEntity_Success(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	svc := newFakeHardDeleteSvc()
	uc := NewDeleteRestoreUseCase(&domainHardDeleteWrapper{svc: svc}, hardDeleteTestLogger(t))

	// Given a soft-deleted entity ID
	entityID := "ent-001"

	// When hard-delete is executed
	err := uc.HardDelete(ctx, entityID)

	// Then no error
	if err != nil {
		t.Fatalf("HardDelete failed: %v", err)
	}

	// And the service was called
	svc.mu.Lock()
	wasCalled := svc.hardDeleted[entityID]
	svc.mu.Unlock()
	if !wasCalled {
		t.Errorf("expected HardDeleteEntity to be called for %q", entityID)
	}
}

// domainHardDeleteWrapper adapts fakeHardDeleteSvc to match the
// *domain.Service type expected by NewDeleteRestoreUseCase.
type domainHardDeleteWrapper struct {
	svc *fakeHardDeleteSvc
}

func (w *domainHardDeleteWrapper) HardDeleteEntity(ctx context.Context, id string) error {
	return w.svc.HardDeleteEntity(ctx, id)
}

func (w *domainHardDeleteWrapper) SoftDeleteEntity(ctx context.Context, id string) error {
	// Not needed for hard-delete tests, but required by the interface.
	return nil
}

func (w *domainHardDeleteWrapper) RestoreEntity(ctx context.Context, id string) error {
	return nil
}

func (w *domainHardDeleteWrapper) PermanentDeleteEntity(ctx context.Context, id string) error {
	return nil
}

// ---------------------------------------------------------------------------
// Full integration-style: Application use case backed by real domain service
// and fakes, covering all three Gherkin scenarios end-to-end.
// ---------------------------------------------------------------------------

// hardDeleteUseCaseTestHarness holds all the fake dependencies for a single
// integration-level test of the DeleteRestoreUseCase.
type hardDeleteUseCaseTestHarness struct {
	ctx         context.Context
	schemaRepo  *fakeHardDeleteSchemaRepo
	entityRepo  *hardDeleteFakeEntityRepo
	outboxRepo  *hardDeleteFakeOutboxRepo
	idempotency *hardDeleteFakeIdempotency
	uow         *hardDeleteFakeUnitOfWork
	svc         *domain.Service
	uc          *DeleteRestoreUseCase
	now         time.Time
}

func newHardDeleteUseCaseTestHarness(t *testing.T, now time.Time) *hardDeleteUseCaseTestHarness {
	t.Helper()
	ctx := context.Background()

	schemaRepo := newFakeHardDeleteSchemaRepo()
	entityRepo := newHardDeleteFakeEntityRepo()
	outboxRepo := newHardDeleteFakeOutboxRepo()
	idempotency := newHardDeleteFakeIdempotency()
	uow := newHardDeleteFakeUnitOfWork()

	svc := domain.NewService(
		schemaRepo,
		entityRepo,
		outboxRepo,
		idempotency,
		uow,
		domain.WithClock(func() time.Time { return now }),
	)

	uc := NewDeleteRestoreUseCase(svc, hardDeleteTestLogger(t))

	return &hardDeleteUseCaseTestHarness{
		ctx:         ctx,
		schemaRepo:  schemaRepo,
		entityRepo:  entityRepo,
		outboxRepo:  outboxRepo,
		idempotency: idempotency,
		uow:         uow,
		svc:         svc,
		uc:          uc,
		now:         now,
	}
}

func (h *hardDeleteUseCaseTestHarness) seedSchema(t *testing.T, id, name string) {
	t.Helper()
	err := h.schemaRepo.Save(h.ctx, &domain.EntitySchema{
		ID:   id,
		Name: name,
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: h.now.Add(-24 * time.Hour),
		UpdatedAt: h.now.Add(-24 * time.Hour),
	})
	if err != nil {
		t.Fatalf("seed schema: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Gherkin SCENARIO 1 (Full Integration):
//   Given entity "ent-001" is soft-deleted (deleted_at set, status="deleted")
//   When  a hard-delete is executed
//   Then  the entity record is permanently removed from the database
//         And an entitymanagement.entity.hard_deleted event is written
//           to the outbox
// ---------------------------------------------------------------------------

func TestUseCaseHardDelete_SoftDeletedEntity_FullIntegration(t *testing.T) {
	t.Parallel()

	now := time.Date(2025, 6, 15, 12, 0, 0, 0, time.UTC)
	h := newHardDeleteUseCaseTestHarness(t, now)
	h.seedSchema(t, "sch-test", "TestSchema")

	// Given entity "ent-001" is soft-deleted (deleted_at set, status="deleted")
	softDeletedAt := now.Add(-1 * time.Hour)
	err := h.entityRepo.Save(h.ctx, &domain.Entity{
		ID:        "ent-001",
		SchemaID:  "sch-test",
		Name:      "DeletedEntity",
		Type:      "customer",
		Region:    "us-east-1",
		Status:    domain.EntityStatusDeleted,
		Version:   2,
		DeletedAt: &softDeletedAt,
		CreatedAt: now.Add(-2 * time.Hour),
		UpdatedAt: softDeletedAt,
	})
	if err != nil {
		t.Fatalf("seed entity: %v", err)
	}

	// When hard-delete is executed
	err = h.uc.HardDelete(h.ctx, "ent-001")
	if err != nil {
		t.Fatalf("HardDelete failed: %v", err)
	}

	// Then the entity record is permanently removed from the database
	_, err = h.entityRepo.FindByID(h.ctx, "ent-001")
	if !errors.Is(err, domain.ErrEntityNotFound) {
		t.Errorf("expected entity to be permanently removed, got %v", err)
	}

	// And an entitymanagement.entity.hard_deleted event is written to outbox
	if len(h.outboxRepo.events) != 1 {
		t.Fatalf("expected 1 outbox event, got %d", len(h.outboxRepo.events))
	}
	hardDeletedEvent := (&domain.EntityHardDeleted{}).EventName()
	if h.outboxRepo.events[0].EventType != hardDeletedEvent {
		t.Errorf("expected event type %q, got %q", hardDeletedEvent, h.outboxRepo.events[0].EventType)
	}
	if h.outboxRepo.events[0].AggregateID != "ent-001" {
		t.Errorf("expected aggregate_id 'ent-001', got %q", h.outboxRepo.events[0].AggregateID)
	}
	if h.outboxRepo.events[0].Status != domain.OutboxStatusPending {
		t.Errorf("expected outbox status 'pending', got %q", h.outboxRepo.events[0].Status)
	}
}

// ---------------------------------------------------------------------------
// Gherkin SCENARIO 2 (Full Integration):
//   Given entity "ent-002" is active (deleted_at is NULL)
//   When  a hard-delete is attempted on entity "ent-002"
//   Then  ErrNotDeleted is returned
//         And message: "entity is not soft-deleted"
//         And no data is modified
// ---------------------------------------------------------------------------

func TestUseCaseHardDelete_ActiveEntity_FailsWithErrNotDeleted(t *testing.T) {
	t.Parallel()

	now := time.Date(2025, 6, 15, 12, 0, 0, 0, time.UTC)
	h := newHardDeleteUseCaseTestHarness(t, now)
	h.seedSchema(t, "sch-test", "TestSchema")

	// Given entity "ent-002" is active (deleted_at is NULL)
	err := h.entityRepo.Save(h.ctx, &domain.Entity{
		ID:        "ent-002",
		SchemaID:  "sch-test",
		Name:      "ActiveEntity",
		Type:      "customer",
		Region:    "us-east-1",
		Status:    domain.EntityStatusActive,
		Version:   1,
		DeletedAt: nil,
		CreatedAt: now.Add(-2 * time.Hour),
		UpdatedAt: now.Add(-1 * time.Hour),
	})
	if err != nil {
		t.Fatalf("seed entity: %v", err)
	}

	// When hard-delete is attempted
	err = h.uc.HardDelete(h.ctx, "ent-002")

	// Then ErrNotDeleted is returned
	if err == nil {
		t.Fatal("expected ErrNotDeleted, got nil")
	}
	if !errors.Is(err, domain.ErrNotDeleted) {
		t.Errorf("expected ErrNotDeleted, got %v", err)
	}

	// And message: "entity is not soft-deleted"
	if err.Error() != "hard delete: entity is not soft-deleted" {
		t.Errorf("expected error message 'hard delete: entity is not soft-deleted', got %q", err.Error())
	}

	// And no data is modified — entity still exists with same state
	saved, lookupErr := h.entityRepo.FindByID(h.ctx, "ent-002")
	if lookupErr != nil {
		t.Fatalf("FindByID failed: %v", lookupErr)
	}
	if saved.Status != domain.EntityStatusActive {
		t.Errorf("expected status to remain 'active', got %q", saved.Status)
	}
	if saved.DeletedAt != nil {
		t.Errorf("expected deleted_at to remain nil, got %v", saved.DeletedAt)
	}
	if saved.Version != 1 {
		t.Errorf("expected version to remain 1, got %d", saved.Version)
	}

	// No outbox events were written
	if len(h.outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events, got %d", len(h.outboxRepo.events))
	}
}

// ---------------------------------------------------------------------------
// Gherkin SCENARIO 3 (Full Integration):
//   Given entity "ent-999" does not exist
//   When  a hard-delete is attempted
//   Then  HTTP 404 Not Found is returned (ErrEntityNotFound)
// ---------------------------------------------------------------------------

func TestUseCaseHardDelete_NonExistentEntity_FailsWithNotFound(t *testing.T) {
	t.Parallel()

	now := time.Date(2025, 6, 15, 12, 0, 0, 0, time.UTC)
	h := newHardDeleteUseCaseTestHarness(t, now)

	// Given no entity exists (empty repo)
	// When hard-delete is attempted on "ent-999"
	err := h.uc.HardDelete(h.ctx, "ent-999")

	// Then ErrEntityNotFound is returned
	if err == nil {
		t.Fatal("expected ErrEntityNotFound, got nil")
	}
	if !errors.Is(err, domain.ErrEntityNotFound) {
		t.Errorf("expected ErrEntityNotFound, got %v", err)
	}

	// No outbox events were written
	if len(h.outboxRepo.events) != 0 {
		t.Errorf("expected 0 outbox events for non-existent entity, got %d", len(h.outboxRepo.events))
	}
}

// ---------------------------------------------------------------------------
// Table-driven: Application-layer Hard-Delete Boundary Conditions
// ---------------------------------------------------------------------------

func TestUseCaseHardDelete_TableDriven(t *testing.T) {
	t.Parallel()

	frozenNow := time.Date(2025, 6, 15, 12, 0, 0, 0, time.UTC)

	type entitySeed struct {
		id        string
		status    domain.EntityStatus
		deletedAt *time.Time
		version   int
	}

	tests := []struct {
		name        string
		seed        *entitySeed
		wantErr     error
		wantErrMsg  string
		wantEvent   bool
		wantRemoved bool // entity should be gone from repo
	}{
		{
			name: "soft-deleted entity hard-delete succeeds",
			seed: &entitySeed{
				id:        "ent-sd-001",
				status:    domain.EntityStatusDeleted,
				deletedAt: timePtr(frozenNow.Add(-1 * time.Hour)),
				version:   2,
			},
			wantErr:     nil,
			wantEvent:   true,
			wantRemoved: true,
		},
		{
			name: "active entity hard-delete fails with ErrNotDeleted",
			seed: &entitySeed{
				id:        "ent-active-002",
				status:    domain.EntityStatusActive,
				deletedAt: nil,
				version:   1,
			},
			wantErr:     domain.ErrNotDeleted,
			wantErrMsg:  "entity is not soft-deleted",
			wantEvent:   false,
			wantRemoved: false,
		},
		{
			name: "inactive entity hard-delete fails with ErrNotDeleted",
			seed: &entitySeed{
				id:        "ent-inactive-003",
				status:    domain.EntityStatusInactive,
				deletedAt: nil,
				version:   1,
			},
			wantErr:     domain.ErrNotDeleted,
			wantErrMsg:  "entity is not soft-deleted",
			wantEvent:   false,
			wantRemoved: false,
		},
		{
			name:        "non-existent entity hard-delete fails with ErrEntityNotFound",
			seed:        nil, // no seed
			wantErr:     domain.ErrEntityNotFound,
			wantEvent:   false,
			wantRemoved: false,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			h := newHardDeleteUseCaseTestHarness(t, frozenNow)
			h.seedSchema(t, "sch-test", "TestSchema")

			entityID := "ent-nonexistent"
			if tt.seed != nil {
				entityID = tt.seed.id
				err := h.entityRepo.Save(h.ctx, &domain.Entity{
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

			err := h.uc.HardDelete(h.ctx, entityID)

			if tt.wantErr != nil {
				if err == nil {
					t.Fatalf("expected error %v, got nil", tt.wantErr)
				}
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("expected error %v, got %v", tt.wantErr, err)
				}
				if tt.wantErrMsg != "" {
					if err.Error() != "hard delete: "+tt.wantErrMsg {
						t.Errorf("expected error message to contain %q, got %q", tt.wantErrMsg, err.Error())
					}
				}
			} else if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			// Check if entity was removed
			if tt.seed != nil && tt.wantRemoved {
				_, lookupErr := h.entityRepo.FindByID(h.ctx, tt.seed.id)
				if !errors.Is(lookupErr, domain.ErrEntityNotFound) {
					t.Errorf("expected entity to be removed, got %v", lookupErr)
				}
			}

			// Check if entity was NOT removed
			if tt.seed != nil && !tt.wantRemoved {
				saved, lookupErr := h.entityRepo.FindByID(h.ctx, tt.seed.id)
				if lookupErr != nil {
					t.Fatalf("FindByID failed: %v", lookupErr)
				}
				if saved.Status != tt.seed.status {
					t.Errorf("expected status to remain %q, got %q", tt.seed.status, saved.Status)
				}
				if saved.Version != tt.seed.version {
					t.Errorf("expected version to remain %d, got %d", tt.seed.version, saved.Version)
				}
			}

			// Check outbox events
			if tt.wantEvent && len(h.outboxRepo.events) != 1 {
				t.Errorf("expected 1 outbox event, got %d", len(h.outboxRepo.events))
			}
			if !tt.wantEvent && len(h.outboxRepo.events) != 0 {
				t.Errorf("expected 0 outbox events, got %d", len(h.outboxRepo.events))
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Fake implementations for application-layer hard-delete tests.
// ---------------------------------------------------------------------------

type fakeHardDeleteSchemaRepo struct {
	mu      sync.RWMutex
	schemas map[string]*domain.EntitySchema
}

func newFakeHardDeleteSchemaRepo() *fakeHardDeleteSchemaRepo {
	return &fakeHardDeleteSchemaRepo{schemas: make(map[string]*domain.EntitySchema)}
}

func (r *fakeHardDeleteSchemaRepo) Save(_ context.Context, schema *domain.EntitySchema) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.schemas[schema.ID] = schema
	return nil
}

func (r *fakeHardDeleteSchemaRepo) FindByID(_ context.Context, id string) (*domain.EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	s, ok := r.schemas[id]
	if !ok {
		return nil, domain.ErrSchemaNotFound
	}
	return s, nil
}

func (r *fakeHardDeleteSchemaRepo) FindByName(_ context.Context, name string) (*domain.EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, s := range r.schemas {
		if s.Name == name {
			return s, nil
		}
	}
	return nil, domain.ErrSchemaNotFound
}

func (r *fakeHardDeleteSchemaRepo) FindAll(_ context.Context) ([]*domain.EntitySchema, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*domain.EntitySchema
	for _, s := range r.schemas {
		result = append(result, s)
	}
	return result, nil
}

func (r *fakeHardDeleteSchemaRepo) Delete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.schemas, id)
	return nil
}

type hardDeleteFakeEntityRepo struct {
	mu       sync.RWMutex
	entities map[string]*domain.Entity
}

func newHardDeleteFakeEntityRepo() *hardDeleteFakeEntityRepo {
	return &hardDeleteFakeEntityRepo{entities: make(map[string]*domain.Entity)}
}

func (r *hardDeleteFakeEntityRepo) Save(_ context.Context, entity *domain.Entity) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entities[entity.ID] = entity
	return nil
}

func (r *hardDeleteFakeEntityRepo) FindByID(_ context.Context, id string) (*domain.Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, domain.ErrEntityNotFound
	}
	return e, nil
}

func (r *hardDeleteFakeEntityRepo) Update(_ context.Context, id string, op domain.UpdateOperation) (*domain.Entity, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, domain.ErrEntityNotFound
	}
	if err := e.ApplyUpdate(op); err != nil {
		return nil, err
	}
	return e, nil
}

func (r *hardDeleteFakeEntityRepo) UpdateStatus(_ context.Context, id string, status domain.EntityStatus) error {
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

func (r *hardDeleteFakeEntityRepo) FindBySchemaID(_ context.Context, schemaID string) ([]*domain.Entity, error) {
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

func (r *hardDeleteFakeEntityRepo) List(_ context.Context, filter domain.EntityFilter) ([]*domain.Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*domain.Entity
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

func (r *hardDeleteFakeEntityRepo) SoftDelete(_ context.Context, id string, deletedAt time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return domain.ErrEntityNotFound
	}
	if e.DeletedAt != nil {
		return domain.ErrAlreadyDeleted
	}
	e.DeletedAt = &deletedAt
	e.Status = domain.EntityStatusDeleted
	e.Version++
	e.UpdatedAt = deletedAt
	return nil
}

func (r *hardDeleteFakeEntityRepo) Restore(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entities[id]
	if !ok {
		return domain.ErrEntityNotFound
	}
	if e.DeletedAt == nil {
		return domain.ErrNotDeleted
	}
	e.DeletedAt = nil
	e.Status = domain.EntityStatusActive
	e.Version++
	e.UpdatedAt = time.Now()
	return nil
}

func (r *hardDeleteFakeEntityRepo) HardDelete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.entities[id]; !ok {
		return domain.ErrEntityNotFound
	}
	delete(r.entities, id)
	return nil
}

func (r *hardDeleteFakeEntityRepo) ListEntities(_ context.Context, params domain.ListEntitiesParams) (*domain.PaginatedResult, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var filtered []*domain.Entity
	for _, e := range r.entities {
		if e.SchemaID != params.SchemaID {
			continue
		}
		if !params.IncludeDeleted && e.DeletedAt != nil {
			continue
		}
		filtered = append(filtered, e)
	}
	return &domain.PaginatedResult{
		Entities:   filtered,
		TotalCount: len(filtered),
	}, nil
}

type hardDeleteFakeOutboxRepo struct {
	mu     sync.Mutex
	events []*domain.OutboxEvent
}

func newHardDeleteFakeOutboxRepo() *hardDeleteFakeOutboxRepo {
	return &hardDeleteFakeOutboxRepo{}
}

func (r *hardDeleteFakeOutboxRepo) Save(_ context.Context, event *domain.OutboxEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
	return nil
}

func (r *hardDeleteFakeOutboxRepo) MarkPublished(_ context.Context, _ string) error       { return nil }
func (r *hardDeleteFakeOutboxRepo) MarkFailed(_ context.Context, _ string, _ error) error { return nil }
func (r *hardDeleteFakeOutboxRepo) FetchPending(_ context.Context, limit int) ([]*domain.OutboxEvent, error) {
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

type hardDeleteFakeIdempotency struct {
	mu     sync.RWMutex
	store  map[string]string
	expiry map[string]time.Time
}

func newHardDeleteFakeIdempotency() *hardDeleteFakeIdempotency {
	return &hardDeleteFakeIdempotency{
		store:  make(map[string]string),
		expiry: make(map[string]time.Time),
	}
}

func (s *hardDeleteFakeIdempotency) GetEntityID(_ context.Context, requestKey string) (string, error) {
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

func (s *hardDeleteFakeIdempotency) Save(_ context.Context, requestKey, entityID string, ttl time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.store[requestKey] = entityID
	s.expiry[requestKey] = time.Now().Add(ttl)
	return nil
}

type hardDeleteFakeUnitOfWork struct{}

func newHardDeleteFakeUnitOfWork() *hardDeleteFakeUnitOfWork { return &hardDeleteFakeUnitOfWork{} }

func (u *hardDeleteFakeUnitOfWork) Execute(_ context.Context, fn func(uowCtx context.Context) error) error {
	return fn(context.Background())
}

// timePtr returns a pointer to the given time.
func timePtr(t time.Time) *time.Time {
	return &t
}
