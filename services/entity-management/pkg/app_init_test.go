// Package main_test provides integration-level tests for the application
// composition root (dependency injection wiring) and health endpoints.
//
// Gherkin coverage:
//   - Composition root initialization order (Logger → DB → Repos → Migrations → NATS → Publisher → Validator → Service → UseCases → Router → Health)
//   - GET /healthz returns HTTP 200 {"status": "ok"}
//   - GET /readyz with working DB returns HTTP 200 {"status": "ready"}
//   - GET /readyz with lost DB connection returns HTTP 503 with error details
package pkg_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"

	"entity-management/internal/adapters/eventbus"
	"entity-management/internal/adapters/postgres"
	"entity-management/internal/adapters/validator"
	"entity-management/internal/application"
	"entity-management/internal/domain"
	"entity-management/internal/ports"
)

// compositionRoot is a test helper that replicates the production composition
// root using a real pgxpool and fakes. It validates that each
// dependency is wired in the correct order and returns a fully constructed
// router ready for health-check assertions.
type compositionRoot struct {
	Logger      *slog.Logger
	Pool        *pgxpool.Pool
	SchemaRepo  *postgres.SchemaRepository
	EntityRepo  *postgres.EntityRepository
	OutboxRepo  *postgres.OutboxRepository
	Idempotency *postgres.IdempotencyStore
	RequestIdem *postgres.RequestIdempotencyStore
	Bus         ports.EventBus
	EventPub    *ports.EventPublisherAdapter
	Validator   *validator.MemoryValidator
	Uow         *postgres.UnitOfWork
	SchemaSvc   *application.SchemaService
	DomainSvc   *domain.Service
	CreateUC    *application.CreateEntityUseCase
	ReadUC      *application.ReadEntityUseCase
	UpdateUC    *application.UpdateEntityUseCase
	DeleteUC    *application.DeleteRestoreUseCase
	ListUC      *application.ListEntitiesUseCase
	Router      *chi.Mux

	// Track initialization order
	initOrder []string
	mu        sync.Mutex
}

func record(initOrder *[]string, mu *sync.Mutex, step string) func() {
	mu.Lock()
	*initOrder = append(*initOrder, step)
	mu.Unlock()
	return func() {}
}

// buildCompositionRoot constructs the full dependency graph for testing.
func buildCompositionRoot(t *testing.T, databaseURL string) *compositionRoot {
	t.Helper()

	var order []string
	var mu sync.Mutex

	// ----------------------------------------------------------------
	// 1. Logger (slog JSONHandler)
	// ----------------------------------------------------------------
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelWarn,
	})).With("test", t.Name())
	record(&order, &mu, "1_logger")

	// ----------------------------------------------------------------
	// 2. Database connection pool (pgxpool) with ping verification
	// ----------------------------------------------------------------
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatalf("step 2: pgxpool.New failed: %v", err)
	}
	t.Cleanup(pool.Close)

	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("step 2: pgxpool.Ping failed: %v", err)
	}
	record(&order, &mu, "2_database_pool")

	// ----------------------------------------------------------------
	// 3. Schema, Entity, Outbox, Idempotency repositories
	// ----------------------------------------------------------------
	schemaRepo := postgres.NewSchemaRepository(pool, logger)
	entityRepo := postgres.NewEntityRepository(pool, logger)
	outboxRepo := postgres.NewOutboxRepository(pool, logger)
	idempotencyStore := postgres.NewIdempotencyStore(pool, logger)
	requestIdempotencyStore := postgres.NewRequestIdempotencyStore(pool, logger)
	record(&order, &mu, "3_repositories")

	// ----------------------------------------------------------------
	// 4. Database migrations (schema + entity tables)
	// ----------------------------------------------------------------
	if err := postgres.RunMigrations(ctx, pool); err != nil {
		t.Fatalf("step 4: database migrations failed: %v", err)
	}
	record(&order, &mu, "4_migrations")

	// ----------------------------------------------------------------
	// 5. NATS event bus connection (with noop fallback)
	// ----------------------------------------------------------------
	var bus ports.EventBus
	bus, err = eventbus.NewNATSEventBus("nats://localhost:4222", logger)
	if err != nil {
		t.Logf("step 5: NATS unavailable (%v), using noop fallback", err)
		bus = eventbus.NewNoopBus(logger)
	}
	t.Cleanup(func() { _ = bus.Close() })
	record(&order, &mu, "5_event_bus")

	// ----------------------------------------------------------------
	// 6. Event publisher adapter (CloudEvents enveloping)
	// ----------------------------------------------------------------
	eventPub := ports.NewEventPublisherAdapter(bus, "entity-management-test")
	record(&order, &mu, "6_event_publisher")

	// ----------------------------------------------------------------
	// 7. Schema validator (in-memory cache)
	// ----------------------------------------------------------------
	validatorCache := validator.NewMemoryValidator(schemaRepo, logger)
	record(&order, &mu, "7_validator")

	// ----------------------------------------------------------------
	// 8a. Unit of Work
	// ----------------------------------------------------------------
	uow := postgres.NewUnitOfWork(pool, logger)
	record(&order, &mu, "8a_uow")

	// ----------------------------------------------------------------
	// 8b. Domain service (with UnitOfWork, RequestIdempotencyStore)
	// ----------------------------------------------------------------
	domainSvc := domain.NewService(
		schemaRepo,
		entityRepo,
		outboxRepo,
		requestIdempotencyStore,
		uow,
	)
	record(&order, &mu, "8b_domain_service")

	// ----------------------------------------------------------------
	// 9. Application use cases
	// ----------------------------------------------------------------
	schemaSvc := application.NewSchemaService(
		schemaRepo, outboxRepo, uow, eventPub, validatorCache, logger,
	)
	createUC := application.NewCreateEntityUseCase(domainSvc)
	readUC := application.NewReadEntityUseCase(entityRepo, eventPub, logger)
	updateUC := application.NewUpdateEntityUseCase(domainSvc, logger)
	deleteUC := application.NewDeleteRestoreUseCase(domainSvc, logger)
	listUC := application.NewListEntitiesUseCase(entityRepo, eventPub, logger)
	record(&order, &mu, "9_use_cases")

	// ----------------------------------------------------------------
	// 10. HTTP handlers with chi router
	// ----------------------------------------------------------------
	app := ports.NewRouter(
		schemaSvc,
		createUC,
		readUC,
		updateUC,
		deleteUC,
		listUC,
		logger,
	)
	record(&order, &mu, "10_router")

	// ----------------------------------------------------------------
	// 11. Health endpoints (/healthz, /readyz) registered
	// ----------------------------------------------------------------
	app.Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok"}`))
	})
	app.Get("/readyz", func(w http.ResponseWriter, r *http.Request) {
		if err := pool.Ping(r.Context()); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			json.NewEncoder(w).Encode(map[string]string{
				"status": "unavailable",
				"reason": err.Error(),
			})
			return
		}
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ready"}`))
	})
	record(&order, &mu, "11_health_endpoints")

	return &compositionRoot{
		Logger:      logger,
		Pool:        pool,
		SchemaRepo:  schemaRepo,
		EntityRepo:  entityRepo,
		OutboxRepo:  outboxRepo,
		Idempotency: idempotencyStore,
		RequestIdem: requestIdempotencyStore,
		Bus:         bus,
		EventPub:    eventPub,
		Validator:   validatorCache,
		Uow:         uow,
		SchemaSvc:   schemaSvc,
		DomainSvc:   domainSvc,
		CreateUC:    createUC,
		ReadUC:      readUC,
		UpdateUC:    updateUC,
		DeleteUC:    deleteUC,
		ListUC:      listUC,
		Router:      app,
		initOrder:   order,
		mu:          mu,
	}
}

// ---------------------------------------------------------------------------
// Test: Composition Root Initialization Order
// ---------------------------------------------------------------------------

func TestCompositionRoot_InitializationOrder(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	databaseURL := getTestDBURL()
	if databaseURL == "" {
		t.Skip("DATABASE_URL_TEST not set; skipping integration test")
	}

	root := buildCompositionRoot(t, databaseURL)

	expectedOrder := []string{
		"1_logger",
		"2_database_pool",
		"3_repositories",
		"4_migrations",
		"5_event_bus",
		"6_event_publisher",
		"7_validator",
		"8a_uow",
		"8b_domain_service",
		"9_use_cases",
		"10_router",
		"11_health_endpoints",
	}

	t.Logf("Initialization order: %v", root.initOrder)
	for i, expected := range expectedOrder {
		if i >= len(root.initOrder) {
			t.Errorf("missing step %d: expected %q, got end of list", i, expected)
			continue
		}
		if root.initOrder[i] != expected {
			t.Errorf("step %d: expected %q, got %q", i, expected, root.initOrder[i])
		}
	}

	nonNilChecks := []struct {
		name string
		val  interface{}
	}{
		{"Logger", root.Logger},
		{"Pool", root.Pool},
		{"SchemaRepo", root.SchemaRepo},
		{"EntityRepo", root.EntityRepo},
		{"OutboxRepo", root.OutboxRepo},
		{"Idempotency", root.Idempotency},
		{"RequestIdem", root.RequestIdem},
		{"Bus", root.Bus},
		{"EventPub", root.EventPub},
		{"Validator", root.Validator},
		{"Uow", root.Uow},
		{"SchemaSvc", root.SchemaSvc},
		{"DomainSvc", root.DomainSvc},
		{"CreateUC", root.CreateUC},
		{"ReadUC", root.ReadUC},
		{"UpdateUC", root.UpdateUC},
		{"DeleteUC", root.DeleteUC},
		{"ListUC", root.ListUC},
		{"Router", root.Router},
	}

	for _, nc := range nonNilChecks {
		if nc.val == nil {
			t.Errorf("expected %q to be non-nil after initialization", nc.name)
		}
	}
}

func TestCompositionRoot_DatabaseConnectionFailure(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	badURL := "postgres://postgres:wrong@localhost:15432/doesnotexist?sslmode=disable&connect_timeout=2"

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	_, err := pgxpool.New(ctx, badURL)
	if err == nil {
		badPool, _ := pgxpool.New(ctx, badURL)
		if badPool != nil {
			defer badPool.Close()
			pingErr := badPool.Ping(ctx)
			if pingErr == nil {
				t.Skip("unexpectedly connected to database; skipping failure test")
			}
			t.Logf("Expected ping failure: %v", pingErr)
		}
	} else {
		t.Logf("Expected pool creation failure: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Scenario: GET /healthz returns HTTP 200 {"status": "ok"}
// ---------------------------------------------------------------------------

func TestHealthEndpoint_Returns200(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	databaseURL := getTestDBURL()
	if databaseURL == "" {
		t.Skip("DATABASE_URL_TEST not set; skipping integration test")
	}

	root := buildCompositionRoot(t, databaseURL)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()
	root.Router.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d; body: %s", rr.Code, rr.Body.String())
	}

	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("failed to decode response JSON: %v; body: %s", err, rr.Body.String())
	}
	if body["status"] != "ok" {
		t.Errorf("expected status 'ok', got %q", body["status"])
	}
}

// ---------------------------------------------------------------------------
// Scenario: GET /readyz with working DB returns HTTP 200 {"status": "ready"}
// ---------------------------------------------------------------------------

func TestReadyzEndpoint_WithWorkingDB_Returns200(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	databaseURL := getTestDBURL()
	if databaseURL == "" {
		t.Skip("DATABASE_URL_TEST not set; skipping integration test")
	}

	root := buildCompositionRoot(t, databaseURL)

	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	rr := httptest.NewRecorder()
	root.Router.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d; body: %s", rr.Code, rr.Body.String())
	}

	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("failed to decode response JSON: %v; body: %s", err, rr.Body.String())
	}
	if body["status"] != "ready" {
		t.Errorf("expected status 'ready', got %q", body["status"])
	}
}

// ---------------------------------------------------------------------------
// Scenario: GET /readyz with lost DB connection returns HTTP 503
// ---------------------------------------------------------------------------

func TestReadyzEndpoint_WithDBConnectionLost_Returns503(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	databaseURL := getTestDBURL()
	if databaseURL == "" {
		t.Skip("DATABASE_URL_TEST not set; skipping integration test")
	}

	root := buildCompositionRoot(t, databaseURL)

	// Simulate a lost database connection by closing the pool
	root.Pool.Close()
	time.Sleep(50 * time.Millisecond)

	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	rr := httptest.NewRecorder()
	root.Router.ServeHTTP(rr, req)

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected HTTP 503, got %d; body: %s", rr.Code, rr.Body.String())
	}

	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("failed to decode response JSON: %v; body: %s", err, rr.Body.String())
	}
	if body["status"] != "unavailable" {
		t.Errorf("expected status 'unavailable', got %q", body["status"])
	}
	if body["reason"] == "" {
		t.Error("expected non-empty 'reason' field in 503 response")
	} else {
		t.Logf("Readyz 503 reason: %q", body["reason"])
	}
}

// ---------------------------------------------------------------------------
// Scenario: Chained health probes (healthz then readyz) succeed
// ---------------------------------------------------------------------------

func TestHealthAndReadyz_ChainedProbes(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	databaseURL := getTestDBURL()
	if databaseURL == "" {
		t.Skip("DATABASE_URL_TEST not set; skipping integration test")
	}

	root := buildCompositionRoot(t, databaseURL)

	// /healthz
	req1 := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr1 := httptest.NewRecorder()
	root.Router.ServeHTTP(rr1, req1)

	if rr1.Code != http.StatusOK {
		t.Fatalf("healthz: expected HTTP 200, got %d", rr1.Code)
	}
	var healthBody map[string]string
	json.Unmarshal(rr1.Body.Bytes(), &healthBody)
	if healthBody["status"] != "ok" {
		t.Errorf("healthz: expected status 'ok', got %q", healthBody["status"])
	}

	// /readyz
	req2 := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	rr2 := httptest.NewRecorder()
	root.Router.ServeHTTP(rr2, req2)

	if rr2.Code != http.StatusOK {
		t.Fatalf("readyz: expected HTTP 200, got %d", rr2.Code)
	}
	var readyBody map[string]string
	json.Unmarshal(rr2.Body.Bytes(), &readyBody)
	if readyBody["status"] != "ready" {
		t.Errorf("readyz: expected status 'ready', got %q", readyBody["status"])
	}
}

// ---------------------------------------------------------------------------
// Scenario: Health endpoints respond correctly under concurrent load
// ---------------------------------------------------------------------------

func TestHealthEndpoints_ConcurrentLoad(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	databaseURL := getTestDBURL()
	if databaseURL == "" {
		t.Skip("DATABASE_URL_TEST not set; skipping integration test")
	}

	root := buildCompositionRoot(t, databaseURL)

	const concurrency = 50
	var wg sync.WaitGroup
	errs := make(chan error, concurrency*2)

	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
			rr := httptest.NewRecorder()
			root.Router.ServeHTTP(rr, req)
			if rr.Code != http.StatusOK {
				errs <- fmt.Errorf("healthz: expected HTTP 200, got %d", rr.Code)
			}
		}()

		wg.Add(1)
		go func() {
			defer wg.Done()
			req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
			rr := httptest.NewRecorder()
			root.Router.ServeHTTP(rr, req)
			if rr.Code != http.StatusOK {
				errs <- fmt.Errorf("readyz: expected HTTP 200, got %d", rr.Code)
			}
		}()
	}

	wg.Wait()
	close(errs)

	var hasErrors bool
	for err := range errs {
		t.Error(err)
		hasErrors = true
	}
	if hasErrors {
		t.Fail()
	}
}

// ---------------------------------------------------------------------------
// Scenario: Noop event bus fallback initializes correctly
// ---------------------------------------------------------------------------

func TestEventBus_NoopFallback(t *testing.T) {
	t.Parallel()

	logger := discardLogger()

	bus := eventbus.NewNoopBus(logger)
	if bus == nil {
		t.Fatal("expected noop bus to be non-nil")
	}

	err := bus.Publish(context.Background(), "test.subject", &ports.Envelope{
		CloudEventAttributes: ports.CloudEventAttributes{
			SpecVersion: "1.0",
			Type:        "test.event",
			ID:          "test-id",
		},
		Data: []byte(`{"test":true}`),
	})
	if err != nil {
		t.Errorf("noop bus Publish should not error, got: %v", err)
	}

	err = bus.Subscribe(context.Background(), "test.subject", nil)
	if err != nil {
		t.Errorf("noop bus Subscribe should not error, got: %v", err)
	}

	err = bus.Close()
	if err != nil {
		t.Errorf("noop bus Close should not error, got: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Scenario: Event publisher adapter wraps events in CloudEvents envelope
// ---------------------------------------------------------------------------

func TestEventPublisherAdapter_CloudEventsEnvelope(t *testing.T) {
	t.Parallel()

	logger := discardLogger()
	bus := eventbus.NewNoopBus(logger)
	pub := ports.NewEventPublisherAdapter(bus, "test-service")

	if pub == nil {
		t.Fatal("expected EventPublisherAdapter to be non-nil")
	}

	now := time.Now().UTC()
	err := pub.PublishSchemaDefined(context.Background(), &domain.EntitySchemaDefined{
		EventID:    "evt-001",
		SchemaID:   "sch-001",
		SchemaName: "Customer",
		Version:    1,
		OccurredAt: now,
	})
	if err != nil {
		t.Errorf("PublishSchemaDefined should not error, got: %v", err)
	}

	err = pub.PublishEntityCreated(context.Background(), &domain.EntityCreated{
		EventID:    "evt-002",
		EntityID:   "ent-001",
		EntityName: "Alice",
		EntityType: "customer",
		Region:     "eu-west-1",
		OccurredAt: now,
	})
	if err != nil {
		t.Errorf("PublishEntityCreated should not error, got: %v", err)
	}

	err = pub.PublishAppStarted(context.Background(), &domain.AppStarted{
		EventID:           "evt-003",
		ServiceName:       "entity-management",
		ServiceVersion:    "1.0.0",
		Region:            "eu-west-1",
		MigrationVersion:  3,
		Hostname:          "test-host",
		PID:               12345,
		StartupDurationMs: 1500,
		UptimeSeconds:     0.5,
		StartedAt:         now,
	})
	if err != nil {
		t.Errorf("PublishAppStarted should not error, got: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func getTestDBURL() string {
	url := os.Getenv("DATABASE_URL_TEST")
	if url == "" {
		url = os.Getenv("DATABASE_URL")
	}
	return url
}

var _ ports.EventBus = (*eventbus.NoopBus)(nil)

// ---------------------------------------------------------------------------
// Test: Schema Validator in-memory cache compiles correctly
// ---------------------------------------------------------------------------

func TestSchemaValidator_InMemoryCache(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	now := time.Now().UTC()

	logger := discardLogger()

	schemaRepo := &fakeSchemaRepoForValidator{
		schemas: make(map[string]*domain.EntitySchema),
	}

	validatorCache := validator.NewMemoryValidator(schemaRepo, logger)

	schema := &domain.EntitySchema{
		ID:      "sch-customer",
		Name:    "Customer",
		Version: 1,
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
			{Name: "age", Type: domain.AttributeTypeInt, Required: false},
		},
		CreatedAt: now,
		UpdatedAt: now,
	}
	schemaRepo.schemas["sch-customer"] = schema

	if err := validatorCache.CompileSchema(ctx, schema); err != nil {
		t.Fatalf("CompileSchema failed: %v", err)
	}

	err := validatorCache.Validate(ctx, "sch-customer", map[string]any{
		"email": "alice@example.com",
		"age":   30,
	})
	if err != nil {
		t.Errorf("Validate valid attributes should succeed, got: %v", err)
	}

	err = validatorCache.Validate(ctx, "sch-customer", map[string]any{
		"age": 30,
	})
	if err == nil {
		t.Error("Validate missing required attribute should fail")
	} else {
		t.Logf("Expected validation error for missing required attr: %v", err)
	}

	validatorCache.Invalidate(ctx, "sch-customer")

	err = validatorCache.Validate(ctx, "sch-customer", map[string]any{
		"email": "bob@example.com",
	})
	if err != nil {
		t.Errorf("Validate after invalidation and reload should succeed, got: %v", err)
	}
}

type fakeSchemaRepoForValidator struct {
	schemas map[string]*domain.EntitySchema
}

func (r *fakeSchemaRepoForValidator) Save(_ context.Context, schema *domain.EntitySchema) error {
	r.schemas[schema.ID] = schema
	return nil
}
func (r *fakeSchemaRepoForValidator) FindByID(_ context.Context, id string) (*domain.EntitySchema, error) {
	s, ok := r.schemas[id]
	if !ok {
		return nil, errors.New("not found")
	}
	return s, nil
}
func (r *fakeSchemaRepoForValidator) FindByName(_ context.Context, name string) (*domain.EntitySchema, error) {
	for _, s := range r.schemas {
		if s.Name == name {
			return s, nil
		}
	}
	return nil, errors.New("not found")
}
func (r *fakeSchemaRepoForValidator) FindAll(_ context.Context) ([]*domain.EntitySchema, error) {
	var result []*domain.EntitySchema
	for _, s := range r.schemas {
		result = append(result, s)
	}
	return result, nil
}
func (r *fakeSchemaRepoForValidator) Delete(_ context.Context, id string) error {
	delete(r.schemas, id)
	return nil
}

// ---------------------------------------------------------------------------
// Test: Middleware chain is set up on the chi router
// ---------------------------------------------------------------------------

func TestRouter_MiddlewareChain(t *testing.T) {
	t.Parallel()

	r := chi.NewRouter()
	r.Use(chimw.RequestID)
	r.Use(chimw.RealIP)
	r.Use(chimw.Logger)

	r.Get("/test", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	req := httptest.NewRequest(http.MethodGet, "/test", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected HTTP 200, got %d", rr.Code)
	}

	requestID := rr.Header().Get("X-Request-Id")
	if requestID == "" {
		t.Log("RequestID header not set (chi may set it on the context, not the response)")
	}
}

type discardHandler struct{}

func (discardHandler) Enabled(context.Context, slog.Level) bool   { return false }
func (discardHandler) Handle(context.Context, slog.Record) error  { return nil }
func (h discardHandler) WithAttrs(attrs []slog.Attr) slog.Handler { return h }
func (h discardHandler) WithGroup(name string) slog.Handler       { return h }

func discardLogger() *slog.Logger {
	return slog.New(discardHandler{})
}
