package ports

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"entity-management/internal/application"
	"entity-management/internal/domain"
)

// ---------------------------------------------------------------------------
// Fake adapters for integration testing of EntityHTTPHandler.handleGetEntity.
// ---------------------------------------------------------------------------

// handlerFakeEntityRepo implements domain.EntityRepository in-memory for the
// read path only in HTTP handler integration tests.
type handlerFakeEntityRepo struct {
	mu       sync.RWMutex
	entities map[string]*domain.Entity
}

func newHandlerFakeEntityRepo() *handlerFakeEntityRepo {
	return &handlerFakeEntityRepo{entities: make(map[string]*domain.Entity)}
}

func (r *handlerFakeEntityRepo) Save(_ context.Context, entity *domain.Entity) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entities[entity.ID] = entity
	return nil
}

func (r *handlerFakeEntityRepo) FindByID(_ context.Context, id string) (*domain.Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entities[id]
	if !ok {
		return nil, domain.ErrEntityNotFound
	}
	return e, nil
}

func (r *handlerFakeEntityRepo) Update(_ context.Context, _ string, _ domain.UpdateOperation) (*domain.Entity, error) {
	panic("not implemented for handler read tests")
}
func (r *handlerFakeEntityRepo) UpdateStatus(_ context.Context, _ string, _ domain.EntityStatus) error {
	panic("not implemented for handler read tests")
}
func (r *handlerFakeEntityRepo) FindBySchemaID(_ context.Context, _ string) ([]*domain.Entity, error) {
	panic("not implemented for handler read tests")
}
func (r *handlerFakeEntityRepo) List(_ context.Context, _ domain.EntityFilter) ([]*domain.Entity, error) {
	panic("not implemented for handler read tests")
}
func (r *handlerFakeEntityRepo) SoftDelete(_ context.Context, _ string, _ time.Time) error {
	panic("not implemented for handler read tests")
}
func (r *handlerFakeEntityRepo) Restore(_ context.Context, _ string) error {
	panic("not implemented for handler read tests")
}
func (r *handlerFakeEntityRepo) HardDelete(_ context.Context, _ string) error {
	panic("not implemented for handler read tests")
}
func (r *handlerFakeEntityRepo) ListEntities(_ context.Context, _ domain.ListEntitiesParams) (*domain.PaginatedResult, error) {
	panic("not implemented for handler read tests")
}

// handlerFakeEventPublisher records published entity.read events.
type handlerFakeEventPublisher struct {
	mu     sync.Mutex
	events []*domain.EntityRead
}

func newHandlerFakeEventPublisher() *handlerFakeEventPublisher {
	return &handlerFakeEventPublisher{}
}

func (f *handlerFakeEventPublisher) PublishSchemaDefined(_ context.Context, _ *domain.EntitySchemaDefined) error {
	return nil
}
func (f *handlerFakeEventPublisher) PublishSchemaUpdated(_ context.Context, _ *domain.EntitySchemaUpdated) error {
	return nil
}
func (f *handlerFakeEventPublisher) PublishEntityCreated(_ context.Context, _ *domain.EntityCreated) error {
	return nil
}
func (f *handlerFakeEventPublisher) PublishEntityUpdated(_ context.Context, _ *domain.EntityUpdated) error {
	return nil
}
func (f *handlerFakeEventPublisher) PublishEntityDeleted(_ context.Context, _ *domain.EntityDeleted) error {
	return nil
}
func (f *handlerFakeEventPublisher) PublishEntityRead(_ context.Context, event *domain.EntityRead) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}
func (f *handlerFakeEventPublisher) PublishEntitySoftDeleted(_ context.Context, _ *domain.EntitySoftDeleted) error {
	return nil
}
func (f *handlerFakeEventPublisher) PublishEntityHardDeleted(_ context.Context, _ *domain.EntityHardDeleted) error {
	return nil
}
func (f *handlerFakeEventPublisher) PublishEntityRestored(_ context.Context, _ *domain.EntityRestored) error {
	return nil
}
func (f *handlerFakeEventPublisher) PublishEntitiesQueried(_ context.Context, _ *domain.EntitiesQueried) error {
	return nil
}
func (f *handlerFakeEventPublisher) PublishInvalidCursorProvided(_ context.Context, _ *domain.InvalidCursorProvided) error {
	return nil
}
func (f *handlerFakeEventPublisher) PublishAppStarted(_ context.Context, _ *domain.AppStarted) error {
	return nil
}
func (f *handlerFakeEventPublisher) PublishAppStartupFailed(_ context.Context, _ *domain.AppStartupFailed) error {
	return nil
}

func (f *handlerFakeEventPublisher) ReadEvents() []*domain.EntityRead {
	f.mu.Lock()
	defer f.mu.Unlock()
	result := make([]*domain.EntityRead, len(f.events))
	copy(result, f.events)
	return result
}

func handlerTestLogger(t *testing.T) *slog.Logger {
	t.Helper()
	return slog.New(slog.DiscardHandler)
}

// ---------------------------------------------------------------------------
// No-op stubs for other use cases required by EntityHTTPHandler constructor.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Gherkin Scenario 1: Successful GET /api/v1/entities/ent-abc-123
//
// Given an entity with ID "ent-abc-123" exists
// When  a GET /api/v1/entities/ent-abc-123 request is made
// Then  HTTP 200 is returned with the full entity payload
//   Including all attributes, schema_id, region, status, version,
//   created_at, updated_at
//   And an entitymanagement.entity.read domain event is published
// ---------------------------------------------------------------------------

func TestHandleGetEntity_Success(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()
	entityID := "ent-abc-123"

	// Given an entity with ID "ent-abc-123" exists
	repo := newHandlerFakeEntityRepo()
	if err := repo.Save(ctx, &domain.Entity{
		ID:                entityID,
		SchemaID:          "sch-customer-v2",
		Name:              "Alice Wonderland",
		Type:              "customer",
		Region:            "eu-west-1",
		DataResidencyZone: domain.ZoneEUWest1,
		Status:            domain.EntityStatusActive,
		Version:           3,
		Attributes: map[string]any{
			"email":  "alice@example.com",
			"age":    float64(42),
			"status": "active",
		},
		Metadata: map[string]any{
			"source": "import-csv-2024",
		},
		CreatedAt: now.Add(-72 * time.Hour),
		UpdatedAt: now.Add(-1 * time.Hour),
	}); err != nil {
		t.Fatalf("save entity: %v", err)
	}

	eventPub := newHandlerFakeEventPublisher()
	readUC := application.NewReadEntityUseCase(repo, eventPub, handlerTestLogger(t))

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		readUC,
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		&handlerNoopListUC{},
		handlerTestLogger(t),
	)

	// Build a chi router with standard /api/v1 prefix
	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// When a GET request is made
	req := httptest.NewRequest(http.MethodGet, "/api/v1/entities/"+entityID, nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 200 is returned
	if rr.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d; body: %s", rr.Code, rr.Body.String())
	}

	// And the body is valid JSON with full entity payload
	var resp application.ReadEntityResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode response JSON: %v; body: %s", err, rr.Body.String())
	}

	// Including all fields
	if resp.ID != entityID {
		t.Errorf("expected ID %q, got %q", entityID, resp.ID)
	}
	if resp.SchemaID != "sch-customer-v2" {
		t.Errorf("expected SchemaID %q, got %q", "sch-customer-v2", resp.SchemaID)
	}
	if resp.Name != "Alice Wonderland" {
		t.Errorf("expected Name %q, got %q", "Alice Wonderland", resp.Name)
	}
	if resp.Type != "customer" {
		t.Errorf("expected Type %q, got %q", "customer", resp.Type)
	}
	if resp.Region != "eu-west-1" {
		t.Errorf("expected Region %q, got %q", "eu-west-1", resp.Region)
	}
	if resp.Status != string(domain.EntityStatusActive) {
		t.Errorf("expected Status %q, got %q", string(domain.EntityStatusActive), resp.Status)
	}
	if resp.Version != 3 {
		t.Errorf("expected Version 3, got %d", resp.Version)
	}
	if !resp.CreatedAt.Equal(now.Add(-72 * time.Hour)) {
		t.Errorf("CreatedAt mismatch")
	}
	if !resp.UpdatedAt.Equal(now.Add(-1 * time.Hour)) {
		t.Errorf("UpdatedAt mismatch")
	}
	if resp.Attributes == nil || resp.Attributes["email"] != "alice@example.com" {
		t.Error("Attributes missing or incorrect")
	}
	if resp.Metadata == nil || resp.Metadata["source"] != "import-csv-2024" {
		t.Error("Metadata missing or incorrect")
	}

	// Content-Type is application/json
	ct := rr.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("expected Content-Type application/json, got %q", ct)
	}

	// An entitymanagement.entity.read domain event is published
	events := eventPub.ReadEvents()
	if len(events) != 1 {
		t.Fatalf("expected 1 entity.read event published, got %d", len(events))
	}
	if events[0].EntityID != entityID {
		t.Errorf("expected event EntityID %q, got %q", entityID, events[0].EntityID)
	}
	if events[0].EntityName != "Alice Wonderland" {
		t.Errorf("expected event EntityName %q, got %q", "Alice Wonderland", events[0].EntityName)
	}
	if events[0].Region != "eu-west-1" {
		t.Errorf("expected event Region %q, got %q", "eu-west-1", events[0].Region)
	}
	if events[0].EventID == "" {
		t.Error("expected event EventID to be non-empty")
	}
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 2: Entity not found
//
// Given an entity with ID "ent-nonexistent" does not exist
// When  a GET /api/v1/entities/ent-nonexistent request is made
// Then  HTTP 404 is returned with ErrorResponse
//   {code: "NOT_FOUND", message: "entity not found"}
//   And no entity.read event is published
// ---------------------------------------------------------------------------

func TestHandleGetEntity_NotFound(t *testing.T) {
	t.Parallel()

	// Given an empty repository (entity "ent-nonexistent" does not exist)
	repo := newHandlerFakeEntityRepo()
	eventPub := newHandlerFakeEventPublisher()
	readUC := application.NewReadEntityUseCase(repo, eventPub, handlerTestLogger(t))

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		readUC,
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		&handlerNoopListUC{},
		handlerTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// When a GET request is made for a nonexistent entity
	req := httptest.NewRequest(http.MethodGet, "/api/v1/entities/ent-nonexistent", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 404 is returned
	if rr.Code != http.StatusNotFound {
		t.Fatalf("expected HTTP 404, got %d; body: %s", rr.Code, rr.Body.String())
	}

	// And the body is a valid ErrorResponse
	var errResp ErrorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("failed to decode error response JSON: %v; body: %s", err, rr.Body.String())
	}

	// With code "NOT_FOUND"
	if errResp.Code != "NOT_FOUND" {
		t.Errorf("expected error code %q, got %q", "NOT_FOUND", errResp.Code)
	}

	// With message "entity not found"
	if errResp.Message != "entity not found" {
		t.Errorf("expected error message %q, got %q", "entity not found", errResp.Message)
	}

	// Content-Type is application/json
	ct := rr.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("expected Content-Type application/json, got %q", ct)
	}

	// And no entity.read event is published
	events := eventPub.ReadEvents()
	if len(events) != 0 {
		t.Errorf("expected 0 entity.read events for nonexistent entity, got %d", len(events))
	}
}

// ---------------------------------------------------------------------------
// Edge case: Empty ID in URL path returns HTTP 400
// ---------------------------------------------------------------------------

func TestHandleGetEntity_EmptyID(t *testing.T) {
	t.Parallel()

	repo := newHandlerFakeEntityRepo()
	eventPub := newHandlerFakeEventPublisher()
	readUC := application.NewReadEntityUseCase(repo, eventPub, handlerTestLogger(t))

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		readUC,
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		&handlerNoopListUC{},
		handlerTestLogger(t),
	)

	// When a GET request is made with an empty ID
	req := httptest.NewRequest(http.MethodGet, "/entities/", nil)
	rr := httptest.NewRecorder()

	// Inject chi route context with empty "id" param
	chiCtx := chi.NewRouteContext()
	chiCtx.URLParams.Add("id", "")
	req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, chiCtx))

	handler.handleGetEntity(rr, req)

	// Then HTTP 400 is returned
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected HTTP 400 for empty ID, got %d; body: %s", rr.Code, rr.Body.String())
	}

	var errResp ErrorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("failed to decode error response: %v; body: %s", err, rr.Body.String())
	}
	if errResp.Code != "MISSING_ID" {
		t.Errorf("expected code %q, got %q", "MISSING_ID", errResp.Code)
	}
	if errResp.Message == "" {
		t.Error("expected non-empty error message")
	}

	// No events published for bad request
	if len(eventPub.ReadEvents()) != 0 {
		t.Error("expected no events published for empty ID request")
	}
}

// ---------------------------------------------------------------------------
// Edge case: Unexpected repository error results in HTTP 500
// ---------------------------------------------------------------------------

func TestHandleGetEntity_InternalServerError(t *testing.T) {
	t.Parallel()

	// Given a read use case backed by a repo that returns a non-ErrEntityNotFound error
	repo := &failingHandlerRepo{}
	eventPub := newHandlerFakeEventPublisher()
	readUC := application.NewReadEntityUseCase(repo, eventPub, handlerTestLogger(t))

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		readUC,
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		&handlerNoopListUC{},
		handlerTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/entities/ent-db-fail", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 500 is returned
	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("expected HTTP 500 for repo error, got %d; body: %s", rr.Code, rr.Body.String())
	}

	// Response is valid ErrorResponse
	var errResp ErrorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("failed to decode error response: %v", err)
	}
	if errResp.Code == "" {
		t.Error("expected non-empty error code")
	}
	if errResp.Message == "" {
		t.Error("expected non-empty error message")
	}
}

// failingHandlerRepo returns a generic non-ErrEntityNotFound error.
type failingHandlerRepo struct{}

func (f *failingHandlerRepo) Save(_ context.Context, _ *domain.Entity) error {
	return nil
}
func (f *failingHandlerRepo) FindByID(_ context.Context, _ string) (*domain.Entity, error) {
	return nil, domain.ErrConcurrentModification
}
func (f *failingHandlerRepo) Update(_ context.Context, _ string, _ domain.UpdateOperation) (*domain.Entity, error) {
	return nil, domain.ErrConcurrentModification
}
func (f *failingHandlerRepo) UpdateStatus(_ context.Context, _ string, _ domain.EntityStatus) error {
	return domain.ErrConcurrentModification
}
func (f *failingHandlerRepo) FindBySchemaID(_ context.Context, _ string) ([]*domain.Entity, error) {
	return nil, domain.ErrConcurrentModification
}
func (f *failingHandlerRepo) List(_ context.Context, _ domain.EntityFilter) ([]*domain.Entity, error) {
	return nil, domain.ErrConcurrentModification
}
func (f *failingHandlerRepo) SoftDelete(_ context.Context, _ string, _ time.Time) error {
	return domain.ErrConcurrentModification
}
func (f *failingHandlerRepo) Restore(_ context.Context, _ string) error {
	return domain.ErrConcurrentModification
}
func (f *failingHandlerRepo) HardDelete(_ context.Context, _ string) error {
	return domain.ErrConcurrentModification
}
func (f *failingHandlerRepo) ListEntities(_ context.Context, _ domain.ListEntitiesParams) (*domain.PaginatedResult, error) {
	return nil, domain.ErrConcurrentModification
}
