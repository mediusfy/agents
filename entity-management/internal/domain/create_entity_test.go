package domain

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Fake implementations (hermetic, in-memory, thread-safe)
// ---------------------------------------------------------------------------

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

// fakeRequestIdempotency simulates a TTL-aware idempotency store.
// Keys are considered present only if they exist AND the current clock time
// is before the stored expiry.
type fakeRequestIdempotency struct {
	mu     sync.RWMutex
	store  map[string]string // requestKey -> entityID
	expiry map[string]time.Time
	now    func() time.Time
}

func newFakeRequestIdempotency(nowFunc ...func() time.Time) *fakeRequestIdempotency {
	nf := time.Now
	if len(nowFunc) > 0 && nowFunc[0] != nil {
		nf = nowFunc[0]
	}
	return &fakeRequestIdempotency{
		store:  make(map[string]string),
		expiry: make(map[string]time.Time),
		now:    nf,
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
	if ok && s.now().After(expiry) {
		return "", nil // expired — treat as not found
	}
	return entityID, nil
}

func (s *fakeRequestIdempotency) Save(_ context.Context, requestKey, entityID string, ttl time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.store[requestKey] = entityID
	s.expiry[requestKey] = s.now().Add(ttl)
	return nil
}

type fakeUnitOfWork struct{}

func newFakeUnitOfWork() *fakeUnitOfWork { return &fakeUnitOfWork{} }

func (u *fakeUnitOfWork) Execute(_ context.Context, fn func(uowCtx context.Context) error) error {
	return fn(context.Background())
}

// ---------------------------------------------------------------------------
// Shared test constants and helpers
// ---------------------------------------------------------------------------

const customerSchemaID = "sch-customer"

func seedCustomerSchema(ctx context.Context, t *testing.T, schemaRepo *fakeSchemaRepo, now time.Time) {
	t.Helper()
	err := schemaRepo.Save(ctx, &EntitySchema{
		ID:   customerSchemaID,
		Name: "Customer",
		Attributes: []AttributeDefinition{
			{Name: "email", Type: AttributeTypeString, Required: true},
			{Name: "name", Type: AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
	})
	if err != nil {
		t.Fatalf("seedCustomerSchema: Save must succeed: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Table-driven tests for CreateEntity — mapped directly to Gherkin scenarios
// ---------------------------------------------------------------------------

func TestCreateEntity_GherkinScenarios(t *testing.T) {
	t.Parallel()

	// Fixed point-in-time for deterministic testing
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	type testCase struct {
		// Gherkin scenario name
		name string

		// ---- Setup ----------------------------------------------------------
		seedSchema bool

		// Optional pre-seeded entity (for idempotent replay)
		preSeedEntity   bool
		preSeedEntityID string

		// Optional idempotency store pre-seed
		preSeedIdempotencyKey   string
		preSeedIdempotencyValue string
		// If zero (default), expiry is set to "8 days ago" (expired).
		preSeedIdempotencyTTL time.Duration

		input CreateEntityInput

		// ---- Expectations ---------------------------------------------------
		wantErr     bool
		wantErrKind error // sentinel error expected in the chain

		wantCreated       bool
		wantStatus        EntityStatus
		wantVersion       int
		wantDataZone      DataResidencyZone
		wantOutboxCount   int  // expected number of outbox events after call
		wantOutboxType    string // expected event type of the last outbox event
		wantIdempotencyStored bool // after call, key should map to the new entity ID
	}

	tests := []testCase{
		// =====================================================================
		// GHERKIN SCENARIO 1: Happy path — create with idempotency key
		//
		//   Given a schema "Customer" exists with attributes email (string,
		//   required) and name (string, required)
		//   When a POST /api/v1/entities request is sent
		//     With Idempotency-Key: "create-customer-001"
		//     And body: {"schema_id": "sch-customer", "name": "Alice",
		//                "type": "customer", "region": "eu-west-1",
		//                "attributes": {"email": "alice@example.com", "name": "Alice"}}
		//   Then an entity is created with status "active" and version 1
		//     And the entity is tagged with DataResidencyZone="eu-west-1"
		//     And an entitymanagement.entity.created event is enqueued in the
		//         outbox within the same transaction
		//     And the idempotency key is stored with a 7-day TTL
		//     And HTTP 201 is returned with the entity ID and version
		// =====================================================================
		{
			name: "GHERKIN_SCENARIO_1: " +
				"Create entity with idempotency key — active, version 1, " +
				"DataResidencyZone=eu-west-1, entity.created outbox event, " +
				"idempotency key stored (7-day TTL), HTTP 201",
			seedSchema: true,
			input: CreateEntityInput{
				SchemaID:       customerSchemaID,
				Name:           "Alice",
				Type:           "customer",
				Region:         "eu-west-1",
				Attributes:     map[string]any{"email": "alice@example.com", "name": "Alice"},
				IdempotencyKey: "create-customer-001",
			},
			wantCreated:       true,
			wantStatus:        EntityStatusActive,
			wantVersion:       1,
			wantDataZone:      ZoneEUWest1,
			wantOutboxCount:   1,
			wantOutboxType:    (&EntityCreated{}).EventName(),
			wantIdempotencyStored: true,
		},

		// =====================================================================
		// GHERKIN SCENARIO 2: Idempotent replay
		//
		//   Given idempotency key "create-customer-001" was used in a previous
		//   successful create (entity "E1")
		//   When a POST /api/v1/entities is sent with the same
		//     Idempotency-Key: "create-customer-001"
		//   Then the existing entity "E1" is returned (HTTP 200)
		//     And no duplicate entity is created
		//     And no duplicate entity.created event is emitted
		// =====================================================================
		{
			name: "GHERKIN_SCENARIO_2: " +
				"Idempotent replay — existing entity returned (HTTP 200), " +
				"no duplicate entity, no duplicate event",
			seedSchema:       true,
			preSeedEntity:    true,
			preSeedEntityID:  "E1",
			preSeedIdempotencyKey:   "create-customer-001",
			preSeedIdempotencyValue: "E1",
			preSeedIdempotencyTTL:   7 * 24 * time.Hour, // still valid
			input: CreateEntityInput{
				SchemaID:       customerSchemaID,
				Name:           "Alice",
				Type:           "customer",
				Region:         "eu-west-1",
				Attributes:     map[string]any{"email": "alice@example.com", "name": "Alice"},
				IdempotencyKey: "create-customer-001",
			},
			wantCreated:       false, // idempotent hit → not created
			wantStatus:        EntityStatusActive,
			wantVersion:       1,
			wantDataZone:      ZoneEUWest1,
			wantOutboxCount:   0, // no new outbox events
			wantIdempotencyStored: false, // already stored
		},

		// =====================================================================
		// GHERKIN SCENARIO 3: Expired idempotency key
		//
		//   Given idempotency key "expired-key" was stored 8 days ago
		//   When a POST /api/v1/entities is sent with
		//     Idempotency-Key: "expired-key"
		//   Then the key is treated as expired (TTL exceeded)
		//     And a new entity is created
		// =====================================================================
		{
			name: "GHERKIN_SCENARIO_3: " +
				"Expired idempotency key (stored 8 days ago) — " +
				"treated as expired, new entity created",
			seedSchema:             true,
			preSeedIdempotencyKey:   "expired-key",
			preSeedIdempotencyValue: "old-entity-id",
			// preSeedIdempotencyTTL == 0 ⇒ expiry set to 8 days ago
			input: CreateEntityInput{
				SchemaID:       customerSchemaID,
				Name:           "Bob",
				Type:           "customer",
				Region:         "eu-west-1",
				Attributes:     map[string]any{"email": "bob@example.com", "name": "Bob"},
				IdempotencyKey: "expired-key",
			},
			wantCreated:       true,
			wantStatus:        EntityStatusActive,
			wantVersion:       1,
			wantDataZone:      ZoneEUWest1,
			wantOutboxCount:   1,
			wantOutboxType:    (&EntityCreated{}).EventName(),
			wantIdempotencyStored: true, // key updated with new entity ID
		},

		// =====================================================================
		// EDGE: Schema not found
		// =====================================================================
		{
			name:       "EDGE: Schema not found returns wrapped ErrSchemaNotFound",
			seedSchema: false,
			input: CreateEntityInput{
				SchemaID:   "nonexistent-schema",
				Name:       "NoSchema",
				Type:       "test",
				Region:     "us-east-1",
				Attributes: map[string]any{"email": "nobody@example.com", "name": "NoSchema"},
			},
			wantErr:     true,
			wantErrKind: ErrSchemaNotFound,
		},

		// =====================================================================
		// EDGE: Missing required attribute
		// =====================================================================
		{
			name:       "EDGE: Missing required attribute 'email' returns ErrValidationFailed",
			seedSchema: true,
			input: CreateEntityInput{
				SchemaID:   customerSchemaID,
				Name:       "NoEmail",
				Type:       "customer",
				Region:     "us-east-1",
				Attributes: map[string]any{"name": "NoEmail"}, // "email" missing
			},
			wantErr:     true,
			wantErrKind: ErrValidationFailed,
		},

		// =====================================================================
		// EDGE: Fresh idempotency key but schema doesn't exist
		// =====================================================================
		{
			name:       "EDGE: Fresh idempotency key with nonexistent schema returns ErrSchemaNotFound",
			seedSchema: false,
			input: CreateEntityInput{
				SchemaID:       "sch-nonexistent",
				Name:           "Ghost",
				Type:           "test",
				Region:         "us-east-1",
				Attributes:     map[string]any{"email": "ghost@example.com", "name": "Ghost"},
				IdempotencyKey: "fresh-key-no-schema",
			},
			wantErr:     true,
			wantErrKind: ErrSchemaNotFound,
		},

		// =====================================================================
		// EDGE: Create without idempotency key (succeeds but no key stored)
		// =====================================================================
		{
			name:       "EDGE: Create entity without idempotency key succeeds",
			seedSchema: true,
			input: CreateEntityInput{
				SchemaID:   customerSchemaID,
				Name:       "Charlie",
				Type:       "customer",
				Region:     "us-east-1",
				Attributes: map[string]any{"email": "charlie@example.com", "name": "Charlie"},
				// IdempotencyKey omitted (empty)
			},
			wantCreated:       true,
			wantStatus:        EntityStatusActive,
			wantVersion:       1,
			wantDataZone:      ZoneUSEast1, // resolves from us-east-1
			wantOutboxCount:   1,
			wantOutboxType:    (&EntityCreated{}).EventName(),
			wantIdempotencyStored: false, // no key → nothing stored
		},

		// =====================================================================
		// EDGE: Different region resolves to correct DataResidencyZone
		// =====================================================================
		{
			name:       "EDGE: us-west-2 region resolves to us-east-1 zone",
			seedSchema: true,
			input: CreateEntityInput{
				SchemaID:   customerSchemaID,
				Name:       "WestCoast",
				Type:       "customer",
				Region:     "us-west-2",
				Attributes: map[string]any{"email": "west@example.com", "name": "WestCoast"},
			},
			wantCreated: true,
			wantStatus:  EntityStatusActive,
			wantVersion: 1,
			wantDataZone: ZoneUSEast1,
			wantOutboxCount: 1,
			wantOutboxType: (&EntityCreated{}).EventName(),
		},
	}

	for _, tt := range tests {
		tt := tt // capture loop var
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			ctx := context.Background()

			// ---- Build hermetic dependencies ----
			schemaRepo := newFakeSchemaRepo()
			entityRepo := newFakeEntityRepo()
			outboxRepo := newFakeOutboxRepo()

			// Use a controllable clock so we can test TTL expiry.
			idempNow := now
			idempotency := newFakeRequestIdempotency(func() time.Time { return idempNow })

			uow := newFakeUnitOfWork()

			// ---- Pre-seed schema ----
			if tt.seedSchema {
				seedCustomerSchema(ctx, t, schemaRepo, now)
			}

			// ---- Pre-seed entity for idempotent replay ----
			if tt.preSeedEntity {
				e := &Entity{
					ID:                tt.preSeedEntityID,
					SchemaID:          customerSchemaID,
					Name:              "Alice",
					Type:              "customer",
					Region:            "eu-west-1",
					DataResidencyZone: ZoneEUWest1,
					Status:            EntityStatusActive,
					Version:           1,
					Attributes:        map[string]any{"email": "alice@example.com", "name": "Alice"},
					CreatedAt:         now,
					UpdatedAt:         now,
				}
				if err := entityRepo.Save(ctx, e); err != nil {
					t.Fatalf("pre-seed entity save: %v", err)
				}
			}

			// ---- Pre-seed idempotency key ----
			if tt.preSeedIdempotencyKey != "" {
				expiry := now.Add(-8 * 24 * time.Hour) // default: 8 days ago (expired)
				if tt.preSeedIdempotencyTTL > 0 {
					expiry = now.Add(tt.preSeedIdempotencyTTL) // still valid
				}
				idempotency.mu.Lock()
				idempotency.store[tt.preSeedIdempotencyKey] = tt.preSeedIdempotencyValue
				idempotency.expiry[tt.preSeedIdempotencyKey] = expiry
				idempotency.mu.Unlock()
			}

			// ---- Build the service under test ----
			svc := NewService(
				schemaRepo, entityRepo, outboxRepo, idempotency, uow,
				WithClock(func() time.Time { return now }),
				WithIdempotencyTTL(7*24*time.Hour),
			)

			// ---- Record outbox count before call ----
			preOutboxCount := len(outboxRepo.events)

			// ---- Execute ----
			result, err := svc.CreateEntity(ctx, tt.input)

			// ---- Assert error expectations ----
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected an error but got nil")
				}
				if tt.wantErrKind != nil && !errors.Is(err, tt.wantErrKind) {
					t.Errorf("expected error to wrap %v, got %v", tt.wantErrKind, err)
				}
				return // no further assertions on error cases
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if result == nil {
				t.Fatal("result must not be nil")
			}

			// ---- Assert Created flag ----
			if result.Created != tt.wantCreated {
				t.Errorf("Created = %v, want %v", result.Created, tt.wantCreated)
			}

			// ---- Assert entity fields ----
			e := result.Entity
			if e == nil {
				t.Fatal("Entity in result must not be nil")
			}
			if e.ID == "" {
				t.Error("Entity ID must not be empty")
			}
			if tt.wantStatus != "" && e.Status != tt.wantStatus {
				t.Errorf("Status = %q, want %q", e.Status, tt.wantStatus)
			}
			if tt.wantVersion > 0 && e.Version != tt.wantVersion {
				t.Errorf("Version = %d, want %d", e.Version, tt.wantVersion)
			}
			if tt.wantDataZone != "" && e.DataResidencyZone != tt.wantDataZone {
				t.Errorf("DataResidencyZone = %q, want %q",
					e.DataResidencyZone, tt.wantDataZone)
			}

			// Input fields should always be preserved
			if e.SchemaID != tt.input.SchemaID {
				t.Errorf("SchemaID = %q, want %q", e.SchemaID, tt.input.SchemaID)
			}
			if e.Name != tt.input.Name {
				t.Errorf("Name = %q, want %q", e.Name, tt.input.Name)
			}
			if e.Type != tt.input.Type {
				t.Errorf("Type = %q, want %q", e.Type, tt.input.Type)
			}
			if e.Region != tt.input.Region {
				t.Errorf("Region = %q, want %q", e.Region, tt.input.Region)
			}

			// ---- Assert outbox events ----
			postOutboxCount := len(outboxRepo.events)
			eventsDelta := postOutboxCount - preOutboxCount
			if eventsDelta != tt.wantOutboxCount {
				t.Errorf("outbox events added = %d, want %d", eventsDelta, tt.wantOutboxCount)
			}

			if tt.wantOutboxCount > 0 && tt.wantOutboxType != "" {
				lastEvent := outboxRepo.events[postOutboxCount-1]
				if lastEvent.EventType != tt.wantOutboxType {
					t.Errorf("outbox event type = %q, want %q",
						lastEvent.EventType, tt.wantOutboxType)
				}
				if lastEvent.AggregateID != e.ID {
					t.Errorf("outbox AggregateID = %q, want %q",
						lastEvent.AggregateID, e.ID)
				}
				if lastEvent.Status != OutboxStatusPending {
					t.Errorf("outbox event status = %q, want %q",
						lastEvent.Status, OutboxStatusPending)
				}
			}

			// ---- Assert idempotency store ----
			if tt.wantIdempotencyStored {
				if tt.input.IdempotencyKey == "" {
					t.Error("cannot assert idempotency stored when key is empty")
				} else {
					storedEntityID, err := idempotency.GetEntityID(ctx, tt.input.IdempotencyKey)
					if err != nil {
						t.Fatalf("GetEntityID failed: %v", err)
					}
					if storedEntityID != e.ID {
						t.Errorf("idempotency key -> %q, want %q",
							storedEntityID, e.ID)
					}
				}
			}

			// ---- For idempotent replay (Created==false), verify no duplicate ----
			if !tt.wantCreated && tt.preSeedIdempotencyKey != "" {
				if e.ID != tt.preSeedIdempotencyValue {
					t.Errorf("idempotent replay returned entity ID %q, want %q",
						e.ID, tt.preSeedIdempotencyValue)
				}
				all, err := entityRepo.FindBySchemaID(ctx, tt.input.SchemaID)
				if err != nil {
					t.Fatalf("FindBySchemaID failed: %v", err)
				}
				if len(all) != 1 {
					t.Errorf("expected exactly 1 entity (no duplicate), got %d", len(all))
				}
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Additional focused tests
// ---------------------------------------------------------------------------

func TestCreateEntity_NonExpiredIdempotencyKey_ReturnsExisting(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency(func() time.Time { return now })
	uow := newFakeUnitOfWork()

	seedCustomerSchema(ctx, t, schemaRepo, now)

	// Pre-seed entity and idempotency key (still valid — 7-day TTL)
	const entityID = "boundary-entity"
	err := entityRepo.Save(ctx, &Entity{
		ID:                entityID,
		SchemaID:          customerSchemaID,
		Name:              "Boundary",
		Type:              "customer",
		Region:            "eu-west-1",
		DataResidencyZone: ZoneEUWest1,
		Status:            EntityStatusActive,
		Version:           1,
		Attributes:        map[string]any{"email": "boundary@example.com", "name": "Boundary"},
		CreatedAt:         now,
		UpdatedAt:         now,
	})
	if err != nil {
		t.Fatalf("pre-seed entity save: %v", err)
	}

	idempotency.mu.Lock()
	idempotency.store["boundary-key"] = entityID
	idempotency.expiry["boundary-key"] = now.Add(7 * 24 * time.Hour) // still valid
	idempotency.mu.Unlock()

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
		WithIdempotencyTTL(7*24*time.Hour),
	)

	result, err := svc.CreateEntity(ctx, CreateEntityInput{
		SchemaID:       customerSchemaID,
		Name:           "Boundary",
		Type:           "customer",
		Region:         "eu-west-1",
		Attributes:     map[string]any{"email": "boundary@example.com", "name": "Boundary"},
		IdempotencyKey: "boundary-key",
	})
	if err != nil {
		t.Fatalf("CreateEntity failed: %v", err)
	}
	if result.Created {
		t.Error("expected Created=false for non-expired key")
	}
	if result.Entity.ID != entityID {
		t.Errorf("returned entity ID = %q, want %q", result.Entity.ID, entityID)
	}
}

func TestCreateEntity_EmptyIdempotencyKey(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	idempotency := newFakeRequestIdempotency()
	uow := newFakeUnitOfWork()

	seedCustomerSchema(ctx, t, schemaRepo, now)

	svc := NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		WithClock(func() time.Time { return now }),
	)

	result, err := svc.CreateEntity(ctx, CreateEntityInput{
		SchemaID:   customerSchemaID,
		Name:       "EmptyKey",
		Type:       "customer",
		Region:     "eu-west-1",
		Attributes: map[string]any{"email": "emptykey@example.com", "name": "EmptyKey"},
	})
	if err != nil {
		t.Fatalf("CreateEntity failed: %v", err)
	}
	if !result.Created {
		t.Error("expected Created=true for request without idempotency key")
	}
}

func TestCreateEntity_AllRegionsResolveCorrectly(t *testing.T) {
	t.Parallel()

	now := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)

	tests := []struct {
		region string
		want   DataResidencyZone
	}{
		{"us-east-1", ZoneUSEast1},
		{"us-west-2", ZoneUSEast1},
		{"eu-west-1", ZoneEUWest1},
		{"eu-central-1", ZoneEUWest1},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.region, func(t *testing.T) {
			t.Parallel()

			ctx := context.Background()
			schemaRepo := newFakeSchemaRepo()
			entityRepo := newFakeEntityRepo()
			outboxRepo := newFakeOutboxRepo()
			idempotency := newFakeRequestIdempotency()
			uow := newFakeUnitOfWork()

			seedCustomerSchema(ctx, t, schemaRepo, now)

			svc := NewService(
				schemaRepo, entityRepo, outboxRepo, idempotency, uow,
				WithClock(func() time.Time { return now }),
			)

			result, err := svc.CreateEntity(ctx, CreateEntityInput{
				SchemaID:   customerSchemaID,
				Name:       "RegionTest",
				Type:       "customer",
				Region:     tt.region,
				Attributes: map[string]any{"email": "region@example.com", "name": "RegionTest"},
			})
			if err != nil {
				t.Fatalf("CreateEntity failed for region %q: %v", tt.region, err)
			}
			if result.Entity.DataResidencyZone != tt.want {
				t.Errorf("DataResidencyZone = %q, want %q",
					result.Entity.DataResidencyZone, tt.want)
			}
		})
	}
}
