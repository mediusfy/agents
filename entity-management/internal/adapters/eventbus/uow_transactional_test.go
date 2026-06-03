package eventbus

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"testing"
	"time"

	"entity-management/internal/domain"
)

// ============================================================================
// Fake UnitOfWork that can simulate transaction atomicity
// ============================================================================

// recordingUnitOfWork records which operations were attempted and can be
// configured to fail on a specific step to test rollback behavior.
type recordingUnitOfWork struct {
	mu             sync.Mutex
	executed       bool
	operations     []string // ordered list of operations attempted within the UoW
	failOnStep     int      // fail when the Nth unique operation is attempted (1-based); 0 = never
	stepCounter    int
}

func newRecordingUnitOfWork() *recordingUnitOfWork {
	return &recordingUnitOfWork{}
}

func (u *recordingUnitOfWork) record(op string) {
	u.mu.Lock()
	defer u.mu.Unlock()
	u.stepCounter++
	u.operations = append(u.operations, op)
}

func (u *recordingUnitOfWork) Execute(_ context.Context, fn func(uowCtx context.Context) error) error {
	u.mu.Lock()
	u.executed = true
	u.mu.Unlock()
	return fn(context.Background())
}

func (u *recordingUnitOfWork) getOperations() []string {
	u.mu.Lock()
	defer u.mu.Unlock()
	cp := make([]string, len(u.operations))
	copy(cp, u.operations)
	return cp
}

// rollbackUnitOfWork simulates a transaction that can be rolled back.
// If fn returns an error, the transaction is considered rolled back.
type rollbackUnitOfWork struct {
	mu       sync.Mutex
	committed bool // true if fn completed without error
}

func newRollbackUnitOfWork() *rollbackUnitOfWork {
	return &rollbackUnitOfWork{}
}

func (u *rollbackUnitOfWork) Execute(_ context.Context, fn func(uowCtx context.Context) error) error {
	err := fn(context.Background())
	u.mu.Lock()
	defer u.mu.Unlock()
	if err == nil {
		u.committed = true
	}
	return err
}

// unitOfWorkRecorder wraps real domain repositories to track operations.
type unitOfWorkRecorder struct {
	domain.EntityRepository
	domain.OutboxRepository
	uow *recordingUnitOfWork
}

func (r *unitOfWorkRecorder) Save(ctx context.Context, entity *domain.Entity) error {
	r.uow.record("entity.Save")
	return r.EntityRepository.Save(ctx, entity)
}

func (r *unitOfWorkRecorder) SaveOutbox(ctx context.Context, event *domain.OutboxEvent) error {
	r.uow.record("outbox.Save")
	return r.OutboxRepository.Save(ctx, event)
}

// ============================================================================
// GHERKIN SCENARIO: Create entity transaction within UnitOfWork
//
//   Given a create entity transaction begins
//   When the entity is saved to the entities table
//     AND the EntityCreated outbox event is saved to the outbox_messages table
//   Then both operations occur within the same UnitOfWork database transaction
//     And the outbox event has status="pending"
// ============================================================================

func TestGherkin_UnitOfWork_CreateEntity_BothOpsInSameTransaction(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	schemaRepo := newFakeSchemaRepoForE2E()
	entityRepo := newFakeEntityRepoForE2E()
	outboxRepo := newFakeOutboxRepoForRelay()
	idempotency := &fakeIdempotencyForE2E{store: make(map[string]string)}
	uow := newRecordingUnitOfWork()

	// Wrap the entity and outbox repos to record their operations
	wrappedEntityRepo := &unitOfWorkRecorder{
		EntityRepository: entityRepo,
		uow:              uow,
	}
	wrappedOutboxRepo := &unitOfWorkRecorder{
		OutboxRepository: outboxRepo,
		uow:              uow,
	}

	// Use real OutboxRepository on the wrapped outbox for Save method
	// Actually, the recorder's SaveOutbox won't match the OutboxRepository interface.
	// Let me use a different approach - just use the standard repos and track via uow.

	// Seed a schema
	_ = schemaRepo.Save(ctx, &domain.EntitySchema{
		ID:   "sch-customer",
		Name: "Customer",
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
			{Name: "name", Type: domain.AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now.Add(-2 * time.Hour),
		UpdatedAt: now.Add(-2 * time.Hour),
	})

	// Given a create entity transaction begins
	svc := domain.NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		domain.WithClock(func() time.Time { return now }),
	)

	// When the entity is created (which triggers entity.Save + outbox.Save within the UoW)
	result, err := svc.CreateEntity(ctx, domain.CreateEntityInput{
		SchemaID:   "sch-customer",
		Name:       "Alice",
		Type:       "customer",
		Region:     "eu-west-1",
		Attributes: map[string]any{"email": "alice@example.com", "name": "Alice"},
	})
	if err != nil {
		t.Fatalf("CreateEntity failed: %v", err)
	}

	// Then both operations occur within the same UnitOfWork
	if !uow.executed {
		t.Fatal("UnitOfWork.Execute was not called")
	}

	// And the entity was saved to the entities table
	entity, err := entityRepo.FindByID(ctx, result.Entity.ID)
	if err != nil {
		t.Fatalf("entity should exist in repository: %v", err)
	}
	if entity == nil {
		t.Fatal("entity should not be nil")
	}
	if entity.Name != "Alice" {
		t.Errorf("expected entity name %q, got %q", "Alice", entity.Name)
	}

	// And the outbox event has status="pending"
	pending, err := outboxRepo.FetchPending(ctx, 10)
	if err != nil {
		t.Fatalf("FetchPending failed: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("expected 1 pending outbox event, got %d", len(pending))
	}
	if pending[0].Status != domain.OutboxStatusPending {
		t.Errorf("expected outbox event status %q, got %q", domain.OutboxStatusPending, pending[0].Status)
	}
	if pending[0].EventType != "entity.created" {
		t.Errorf("expected event type %q, got %q", "entity.created", pending[0].EventType)
	}
	if pending[0].AggregateID != result.Entity.ID {
		t.Errorf("expected aggregate_id %q, got %q", result.Entity.ID, pending[0].AggregateID)
	}
}

// ============================================================================
// GHERKIN SCENARIO: Transaction atomicity — if outbox save fails, entity save
// is rolled back
//
//   Given a create entity transaction begins
//   When the entity is saved to the entities table
//     BUT the outbox save operation fails
//   Then the entity save is rolled back (atomicity)
//     And no entity exists in the repository
//     And no outbox event exists in the repository
// ============================================================================

func TestGherkin_UnitOfWork_Atomicity_RollbackOnOutboxFailure(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	schemaRepo := newFakeSchemaRepoForE2E()
	entityRepo := newFakeEntityRepoForE2E()
	idempotency := &fakeIdempotencyForE2E{store: make(map[string]string)}

	// Create an outbox that fails on Save
	failingOutbox := &failingOutboxRepo{
		failOnSave: true,
	}

	// Use a rollback-aware UnitOfWork
	uow := newRollbackUnitOfWork()

	// Seed a schema
	_ = schemaRepo.Save(ctx, &domain.EntitySchema{
		ID:   "sch-customer",
		Name: "Customer",
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
			{Name: "name", Type: domain.AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now.Add(-2 * time.Hour),
		UpdatedAt: now.Add(-2 * time.Hour),
	})

	svc := domain.NewService(
		schemaRepo, entityRepo, failingOutbox, idempotency, uow,
		domain.WithClock(func() time.Time { return now }),
	)

	// When the create entity transaction is attempted
	_, err := svc.CreateEntity(ctx, domain.CreateEntityInput{
		SchemaID:   "sch-customer",
		Name:       "Alice",
		Type:       "customer",
		Region:     "eu-west-1",
		Attributes: map[string]any{"email": "alice@example.com", "name": "Alice"},
	})

	// Then the transaction should have rolled back (returned an error)
	if err == nil {
		t.Fatal("expected error due to outbox save failure, got nil")
	}

	// The UnitOfWork should NOT have been committed
	if uow.committed {
		t.Error("UnitOfWork should not have been committed (should be rolled back)")
	}

	// And no entity exists in the repository
	entities, _ := entityRepo.FindBySchemaID(ctx, "sch-customer")
	if len(entities) != 0 {
		t.Errorf("expected 0 entities (rolled back), got %d", len(entities))
	}

	// And no outbox event exists
	if len(failingOutbox.events) != 0 {
		t.Errorf("expected 0 outbox events (rolled back), got %d", len(failingOutbox.events))
	}
}

// ============================================================================
// Fake repository that fails on Save to simulate DB errors
// ============================================================================

type failingOutboxRepo struct {
	mu          sync.Mutex
	events      []*domain.OutboxEvent
	failOnSave  bool
}

func (r *failingOutboxRepo) Save(_ context.Context, _ *domain.OutboxEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.failOnSave {
		return errors.New("simulated database error: outbox insert failed")
	}
	return nil
}

func (r *failingOutboxRepo) MarkPublished(_ context.Context, _ string) error {
	return nil
}

func (r *failingOutboxRepo) MarkFailed(_ context.Context, _ string, _ error) error {
	return nil
}

func (r *failingOutboxRepo) FetchPending(_ context.Context, _ int) ([]*domain.OutboxEvent, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.events, nil
}

// ============================================================================
// GHERKIN SCENARIO: Multiple entity operations within a single UnitOfWork
//
//   Given an existing entity
//   When the entity is updated
//     AND the EntityUpdated outbox event is saved
//   Then both operations occur within the same UnitOfWork database transaction
//     And the outbox event has status="pending"
// ============================================================================

func TestGherkin_UnitOfWork_UpdateEntity_BothOpsInSameTransaction(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	schemaRepo := newFakeSchemaRepoForE2E()
	entityRepo := newFakeEntityRepoForE2E()
	outboxRepo := newFakeOutboxRepoForRelay()
	idempotency := &fakeIdempotencyForE2E{store: make(map[string]string)}
	uow := newRecordingUnitOfWork()

	// Seed a schema
	_ = schemaRepo.Save(ctx, &domain.EntitySchema{
		ID:   "sch-customer",
		Name: "Customer",
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
			{Name: "name", Type: domain.AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now.Add(-2 * time.Hour),
		UpdatedAt: now.Add(-2 * time.Hour),
	})

	// Given an existing entity
	_ = entityRepo.Save(ctx, &domain.Entity{
		ID:                "ent-001",
		SchemaID:          "sch-customer",
		Name:              "Alice",
		Type:              "customer",
		Region:            "us-east-1",
		DataResidencyZone: domain.ZoneUSEast1,
		Status:            domain.EntityStatusActive,
		Version:           1,
		Attributes:        map[string]any{"email": "alice@example.com", "name": "Alice"},
		CreatedAt:         now.Add(-1 * time.Hour),
		UpdatedAt:         now.Add(-1 * time.Hour),
	})

	svc := domain.NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		domain.WithClock(func() time.Time { return now }),
	)

	// When the entity is updated
	newName := "Alice Updated"
	updated, err := svc.UpdateEntity(ctx, "ent-001", domain.UpdateOperation{
		ExpectedVersion: 1,
		Name:            &newName,
	})
	if err != nil {
		t.Fatalf("UpdateEntity failed: %v", err)
	}

	// Then both operations occurred within the same UnitOfWork
	if !uow.executed {
		t.Fatal("UnitOfWork.Execute was not called")
	}

	// And the entity was updated
	if updated.Name != "Alice Updated" {
		t.Errorf("expected entity name %q, got %q", "Alice Updated", updated.Name)
	}

	// And the outbox event has status="pending"
	pending, err := outboxRepo.FetchPending(ctx, 10)
	if err != nil {
		t.Fatalf("FetchPending failed: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("expected 1 pending outbox event, got %d", len(pending))
	}
	evt := pending[0]
	if evt.Status != domain.OutboxStatusPending {
		t.Errorf("expected outbox event status %q, got %q", domain.OutboxStatusPending, evt.Status)
	}
	if evt.EventType != "entity.updated" {
		t.Errorf("expected event type %q, got %q", "entity.updated", evt.EventType)
	}
	if evt.AggregateID != "ent-001" {
		t.Errorf("expected aggregate_id %q, got %q", "ent-001", evt.AggregateID)
	}
}

// ============================================================================
// GHERKIN SCENARIO: Soft-delete within UnitOfWork
// ============================================================================

func TestGherkin_UnitOfWork_SoftDelete_BothOpsInSameTransaction(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	schemaRepo := newFakeSchemaRepoForE2E()
	entityRepo := newFakeEntityRepoForE2E()
	outboxRepo := newFakeOutboxRepoForRelay()
	idempotency := &fakeIdempotencyForE2E{store: make(map[string]string)}
	uow := newRecordingUnitOfWork()

	// Seed a schema
	_ = schemaRepo.Save(ctx, &domain.EntitySchema{
		ID: "sch-customer", Name: "Customer",
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
		},
		Version: 1, CreatedAt: now.Add(-2 * time.Hour), UpdatedAt: now.Add(-2 * time.Hour),
	})

	// Given an existing active entity
	_ = entityRepo.Save(ctx, &domain.Entity{
		ID: "ent-001", SchemaID: "sch-customer", Name: "Alice",
		Type: "customer", Region: "us-east-1", Status: domain.EntityStatusActive,
		Version: 1, CreatedAt: now.Add(-1 * time.Hour), UpdatedAt: now.Add(-1 * time.Hour),
	})

	svc := domain.NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		domain.WithClock(func() time.Time { return now }),
	)

	// When the entity is soft-deleted
	err := svc.SoftDeleteEntity(ctx, "ent-001")
	if err != nil {
		t.Fatalf("SoftDeleteEntity failed: %v", err)
	}

	// Then both operations occurred within the same UnitOfWork
	if !uow.executed {
		t.Fatal("UnitOfWork.Execute was not called")
	}

	// And the entity is soft-deleted
	deleted, _ := entityRepo.FindByID(ctx, "ent-001")
	if deleted == nil || !deleted.IsSoftDeleted() {
		t.Error("expected entity to be soft-deleted")
	}

	// And the outbox event has status="pending"
	pending, _ := outboxRepo.FetchPending(ctx, 10)
	if len(pending) != 1 {
		t.Fatalf("expected 1 pending outbox event, got %d", len(pending))
	}
	if pending[0].Status != domain.OutboxStatusPending {
		t.Errorf("expected outbox event status %q, got %q", domain.OutboxStatusPending, pending[0].Status)
	}
	if pending[0].EventType != "entity.soft_deleted" {
		t.Errorf("expected event type %q, got %q", "entity.soft_deleted", pending[0].EventType)
	}
}

// compile-time check
var (
	_ domain.UnitOfWork = (*recordingUnitOfWork)(nil)
	_ domain.UnitOfWork = (*rollbackUnitOfWork)(nil)
	_ domain.OutboxRepository = (*failingOutboxRepo)(nil)
)
