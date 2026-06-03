package application

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"entity-management/internal/domain"
)

// ---------------------------------------------------------------------------
// Fake ports for in-memory testing (Hexagonal Architecture: fake adapters).
// ---------------------------------------------------------------------------

type fakeSchemaRepo struct {
	mu      sync.RWMutex
	schemas map[string]*domain.EntitySchema // keyed by ID
	byName  map[string]*domain.EntitySchema // latest by name
}

func newFakeSchemaRepo() *fakeSchemaRepo {
	return &fakeSchemaRepo{
		schemas: make(map[string]*domain.EntitySchema),
		byName:  make(map[string]*domain.EntitySchema),
	}
}

func (f *fakeSchemaRepo) Save(_ context.Context, schema *domain.EntitySchema) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	// Check duplicate name (Gherkin requirement: strict uniqueness).
	if _, ok := f.byName[schema.Name]; ok {
		return fmt.Errorf("save: %w", domain.ErrSchemaAlreadyExists)
	}

	f.schemas[schema.ID] = schema
	f.byName[schema.Name] = schema
	return nil
}

func (f *fakeSchemaRepo) FindByID(_ context.Context, id string) (*domain.EntitySchema, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()

	s, ok := f.schemas[id]
	if !ok {
		return nil, fmt.Errorf("find by id: %w", domain.ErrSchemaNotFound)
	}
	return s, nil
}

func (f *fakeSchemaRepo) FindByName(_ context.Context, name string) (*domain.EntitySchema, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()

	s, ok := f.byName[name]
	if !ok {
		return nil, fmt.Errorf("find by name: %w", domain.ErrSchemaNotFound)
	}
	return s, nil
}

func (f *fakeSchemaRepo) FindAll(_ context.Context) ([]*domain.EntitySchema, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()

	result := make([]*domain.EntitySchema, 0, len(f.byName))
	for _, s := range f.byName {
		result = append(result, s)
	}
	return result, nil
}

func (f *fakeSchemaRepo) Delete(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	s, ok := f.schemas[id]
	if !ok {
		return fmt.Errorf("delete: %w", domain.ErrSchemaNotFound)
	}
	delete(f.schemas, id)
	delete(f.byName, s.Name)
	return nil
}

type fakeOutboxRepo struct {
	mu     sync.Mutex
	events []*domain.OutboxEvent
}

func newFakeOutboxRepo() *fakeOutboxRepo {
	return &fakeOutboxRepo{events: make([]*domain.OutboxEvent, 0)}
}

func (f *fakeOutboxRepo) Save(_ context.Context, event *domain.OutboxEvent) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeOutboxRepo) MarkPublished(_ context.Context, _ string) error {
	return nil
}

func (f *fakeOutboxRepo) MarkFailed(_ context.Context, _ string, _ error) error {
	return nil
}

func (f *fakeOutboxRepo) FetchPending(_ context.Context, limit int) ([]*domain.OutboxEvent, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var pending []*domain.OutboxEvent
	for _, e := range f.events {
		if e.Status == domain.OutboxStatusPending {
			pending = append(pending, e)
		}
	}
	if len(pending) > limit {
		pending = pending[:limit]
	}
	return pending, nil
}

type fakeUnitOfWork struct{}

func newFakeUnitOfWork() *fakeUnitOfWork {
	return &fakeUnitOfWork{}
}

func (f *fakeUnitOfWork) Execute(_ context.Context, fn func(uowCtx context.Context) error) error {
	return fn(context.Background())
}

type fakeEventPublisher struct {
	mu     sync.Mutex
	events []domain.DomainEvent
}

func newFakeEventPublisher() *fakeEventPublisher {
	return &fakeEventPublisher{events: make([]domain.DomainEvent, 0)}
}

func (f *fakeEventPublisher) PublishSchemaDefined(_ context.Context, event *domain.EntitySchemaDefined) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishSchemaUpdated(_ context.Context, event *domain.EntitySchemaUpdated) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishEntityCreated(_ context.Context, _ *domain.EntityCreated) error {
	return nil
}

func (f *fakeEventPublisher) PublishEntityUpdated(_ context.Context, _ *domain.EntityUpdated) error {
	return nil
}

func (f *fakeEventPublisher) PublishEntityDeleted(_ context.Context, _ *domain.EntityDeleted) error {
	return nil
}

func (f *fakeEventPublisher) PublishEntityRead(_ context.Context, _ *domain.EntityRead) error {
	return nil
}

func (f *fakeEventPublisher) PublishEntitySoftDeleted(_ context.Context, _ *domain.EntitySoftDeleted) error {
	return nil
}

func (f *fakeEventPublisher) PublishEntityHardDeleted(_ context.Context, _ *domain.EntityHardDeleted) error {
	return nil
}

func (f *fakeEventPublisher) PublishEntityRestored(_ context.Context, _ *domain.EntityRestored) error {
	return nil
}

func (f *fakeEventPublisher) Events() []domain.DomainEvent {
	f.mu.Lock()
	defer f.mu.Unlock()
	result := make([]domain.DomainEvent, len(f.events))
	copy(result, f.events)
	return result
}

type fakeValidator struct{}

func newFakeValidator() *fakeValidator {
	return &fakeValidator{}
}

func (f *fakeValidator) Validate(_ context.Context, _ string, _ map[string]any) error {
	return nil
}

func (f *fakeValidator) CompileSchema(_ context.Context, _ *domain.EntitySchema) error {
	return nil
}

func (f *fakeValidator) Invalidate(_ context.Context, _ string) {}

// noopHandler implements slog.Handler by discarding all log records.
type noopHandler struct{}

func (noopHandler) Enabled(_ context.Context, _ slog.Level) bool  { return false }
func (noopHandler) Handle(_ context.Context, _ slog.Record) error { return nil }
func (h noopHandler) WithAttrs(_ []slog.Attr) slog.Handler        { return h }
func (h noopHandler) WithGroup(_ string) slog.Handler             { return h }

func testLogger() *slog.Logger {
	return slog.New(noopHandler{})
}

// ---------------------------------------------------------------------------
// Helper to build test attributes for the Customer schema from the Gherkin.
// ---------------------------------------------------------------------------

func customerSchemaInput() *domain.DefineSchemaInput {
	zero := 0
	oneFifty := 150
	return &domain.DefineSchemaInput{
		Name: "Customer",
		Attributes: []domain.AttributeDefinition{
			{
				Name:     "email",
				Type:     domain.AttributeTypeString,
				Required: true,
				Constraint: &domain.Constraint{
					Pattern: `^[^@]+@[^@]+$`,
				},
			},
			{
				Name:     "age",
				Type:     domain.AttributeTypeInt,
				Required: false,
				Constraint: &domain.Constraint{
					Min: &zero,
					Max: &oneFifty,
				},
			},
			{
				Name:     "isActive",
				Type:     domain.AttributeTypeBool,
				Required: false,
			},
			{
				Name:     "status",
				Type:     domain.AttributeTypeEnum,
				Required: true,
				Constraint: &domain.Constraint{
					Enum: []string{"active", "inactive"},
				},
			},
			{
				Name:     "metadata",
				Type:     domain.AttributeTypeMap,
				Required: false,
			},
			{
				Name:     "config",
				Type:     domain.AttributeTypeJSON,
				Required: false,
			},
		},
	}
}

func newSchemaService() *SchemaService {
	return NewSchemaService(
		newFakeSchemaRepo(),
		newFakeOutboxRepo(),
		newFakeUnitOfWork(),
		newFakeEventPublisher(),
		newFakeValidator(),
		testLogger(),
	)
}

// ---------------------------------------------------------------------------
// Gherkin: Scenario 1 — Define a new entity schema with all supported types.
// ---------------------------------------------------------------------------

func TestDefineSchema_Success_AllTypes(t *testing.T) {
	t.Parallel()

	svc := newSchemaService()
	ctx := context.Background()
	input := customerSchemaInput()

	// When an admin defines an entity schema named "Customer"
	result, err := svc.DefineSchema(ctx, input)
	if err != nil {
		t.Fatalf("expected no error, got: %v", err)
	}

	// Then the schema is stored with a unique schema ID and version 1
	if result.Schema == nil {
		t.Fatal("expected a schema to be returned")
	}
	if result.Schema.ID == "" {
		t.Fatal("expected schema ID to be non-empty")
	}
	if _, err := uuid.Parse(result.Schema.ID); err != nil {
		t.Fatalf("expected valid UUID as schema ID, got %q: %v", result.Schema.ID, err)
	}
	if result.Schema.Version != 1 {
		t.Fatalf("expected version 1, got %d", result.Schema.Version)
	}
	if result.Schema.Name != "Customer" {
		t.Fatalf("expected name 'Customer', got %q", result.Schema.Name)
	}

	// Verify all attributes are stored
	if len(result.Schema.Attributes) != 6 {
		t.Fatalf("expected 6 attributes, got %d", len(result.Schema.Attributes))
	}

	// Check specific attribute constraints
	attrMap := make(map[string]domain.AttributeDefinition)
	for _, a := range result.Schema.Attributes {
		attrMap[a.Name] = a
	}

	tests := []struct {
		name     string
		typ      domain.AttributeType
		required bool
	}{
		{"email", domain.AttributeTypeString, true},
		{"age", domain.AttributeTypeInt, false},
		{"isActive", domain.AttributeTypeBool, false},
		{"status", domain.AttributeTypeEnum, true},
		{"metadata", domain.AttributeTypeMap, false},
		{"config", domain.AttributeTypeJSON, false},
	}
	for _, tt := range tests {
		attr, ok := attrMap[tt.name]
		if !ok {
			t.Fatalf("expected attribute %q to be present", tt.name)
		}
		if attr.Type != tt.typ {
			t.Errorf("attribute %q: expected type %q, got %q", tt.name, tt.typ, attr.Type)
		}
		if attr.Required != tt.required {
			t.Errorf("attribute %q: expected required=%v, got %v", tt.name, tt.required, attr.Required)
		}
	}

	// Verify email constraint: pattern
	emailAttr := attrMap["email"]
	if emailAttr.Constraint == nil || emailAttr.Constraint.Pattern != `^[^@]+@[^@]+$` {
		t.Error("expected email attribute to have pattern constraint `^[^@]+@[^@]+$`")
	}

	// Verify age constraint: min=0, max=150
	ageAttr := attrMap["age"]
	if ageAttr.Constraint == nil {
		t.Error("expected age attribute to have constraint")
	} else {
		if ageAttr.Constraint.Min == nil || *ageAttr.Constraint.Min != 0 {
			t.Errorf("expected age min=0, got %v", ageAttr.Constraint.Min)
		}
		if ageAttr.Constraint.Max == nil || *ageAttr.Constraint.Max != 150 {
			t.Errorf("expected age max=150, got %v", ageAttr.Constraint.Max)
		}
	}

	// Verify status constraint: enum=[active,inactive]
	statusAttr := attrMap["status"]
	if statusAttr.Constraint == nil || len(statusAttr.Constraint.Enum) != 2 {
		t.Error("expected status attribute to have enum constraint")
	} else {
		expected := []string{"active", "inactive"}
		for i, v := range expected {
			if statusAttr.Constraint.Enum[i] != v {
				t.Errorf("expected enum[%d]=%q, got %q", i, v, statusAttr.Constraint.Enum[i])
			}
		}
	}

	// And an entitymanagement.schema.defined CloudEvent is written to the outbox
	// (verified via the event publisher adapter)
	if result.Event == nil {
		t.Fatal("expected a schema.defined event to be emitted")
	}
	if result.Event.SchemaID != result.Schema.ID {
		t.Errorf("event schema ID mismatch: %q vs %q", result.Event.SchemaID, result.Schema.ID)
	}
	if result.Event.Version != 1 {
		t.Errorf("event version mismatch: got %d, want 1", result.Event.Version)
	}
	if result.Event.EventID == "" {
		t.Error("expected event ID to be non-empty")
	}
	if result.Event.OccurredAt.IsZero() {
		t.Error("expected event occurred_at to be set")
	}
}

// ---------------------------------------------------------------------------
// Gherkin: Scenario 2 — Attempt to define a duplicate schema.
// ---------------------------------------------------------------------------

func TestDefineSchema_DuplicateName_ReturnsErrSchemaAlreadyExists(t *testing.T) {
	t.Parallel()

	svc := newSchemaService()
	ctx := context.Background()

	// Given a schema named "Customer" already exists
	input := customerSchemaInput()
	firstResult, err := svc.DefineSchema(ctx, input)
	if err != nil {
		t.Fatalf("expected first definition to succeed, got: %v", err)
	}
	if firstResult.Schema == nil {
		t.Fatal("expected schema from first definition")
	}

	// When an admin attempts to define another schema with the same name
	secondInput := customerSchemaInput()
	secondResult, err := svc.DefineSchema(ctx, secondInput)

	// Then the operation fails with ErrSchemaAlreadyExists
	if err == nil {
		t.Fatal("expected error for duplicate schema name, got nil")
	}
	if !errors.Is(err, domain.ErrSchemaAlreadyExists) {
		t.Fatalf("expected ErrSchemaAlreadyExists, got: %v (type: %T)", err, err)
	}
	if secondResult != nil {
		t.Fatal("expected nil result on error")
	}
}

// ---------------------------------------------------------------------------
// Verify the schema is retrievable after definition.
// ---------------------------------------------------------------------------

func TestDefineSchema_GetAfterDefinition(t *testing.T) {
	t.Parallel()

	svc := newSchemaService()
	ctx := context.Background()
	input := customerSchemaInput()

	result, err := svc.DefineSchema(ctx, input)
	if err != nil {
		t.Fatalf("define schema: %v", err)
	}

	// Retrieve by ID
	got, err := svc.GetSchema(ctx, result.Schema.ID)
	if err != nil {
		t.Fatalf("get schema: %v", err)
	}
	if got.ID != result.Schema.ID {
		t.Errorf("schema ID mismatch: %q vs %q", got.ID, result.Schema.ID)
	}
	if got.Name != "Customer" {
		t.Errorf("schema name mismatch: %q vs %q", got.Name, "Customer")
	}
	if got.Version != 1 {
		t.Errorf("schema version mismatch: %d vs 1", got.Version)
	}
}

// ---------------------------------------------------------------------------
// Verify the schema appears in ListSchemas.
// ---------------------------------------------------------------------------

func TestDefineSchema_ListSchemas(t *testing.T) {
	t.Parallel()

	svc := newSchemaService()
	ctx := context.Background()

	// Define two different schemas
	_, err := svc.DefineSchema(ctx, &domain.DefineSchemaInput{
		Name: "Customer",
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
		},
	})
	if err != nil {
		t.Fatalf("define Customer: %v", err)
	}

	_, err = svc.DefineSchema(ctx, &domain.DefineSchemaInput{
		Name: "Product",
		Attributes: []domain.AttributeDefinition{
			{Name: "sku", Type: domain.AttributeTypeString, Required: true},
		},
	})
	if err != nil {
		t.Fatalf("define Product: %v", err)
	}

	schemas, err := svc.ListSchemas(ctx)
	if err != nil {
		t.Fatalf("list schemas: %v", err)
	}
	if len(schemas) != 2 {
		t.Fatalf("expected 2 schemas, got %d", len(schemas))
	}
}

// ---------------------------------------------------------------------------
// Verify invalid input is rejected before any persistence.
// ---------------------------------------------------------------------------

func TestDefineSchema_InvalidInput_EmptyName(t *testing.T) {
	t.Parallel()

	svc := newSchemaService()
	ctx := context.Background()

	_, err := svc.DefineSchema(ctx, &domain.DefineSchemaInput{
		Name:       "",
		Attributes: []domain.AttributeDefinition{{Name: "a", Type: domain.AttributeTypeString}},
	})
	if err == nil {
		t.Fatal("expected error for empty schema name")
	}
	if !errors.Is(err, domain.ErrInvalidSchema) {
		t.Errorf("expected ErrInvalidSchema, got: %v", err)
	}
}

func TestDefineSchema_InvalidInput_NoAttributes(t *testing.T) {
	t.Parallel()

	svc := newSchemaService()
	ctx := context.Background()

	_, err := svc.DefineSchema(ctx, &domain.DefineSchemaInput{
		Name:       "Empty",
		Attributes: []domain.AttributeDefinition{},
	})
	if err == nil {
		t.Fatal("expected error for empty attributes")
	}
	if !errors.Is(err, domain.ErrInvalidSchema) {
		t.Errorf("expected ErrInvalidSchema, got: %v", err)
	}
}

func TestDefineSchema_InvalidInput_UnknownType(t *testing.T) {
	t.Parallel()

	svc := newSchemaService()
	ctx := context.Background()

	_, err := svc.DefineSchema(ctx, &domain.DefineSchemaInput{
		Name: "BadType",
		Attributes: []domain.AttributeDefinition{
			{Name: "weird", Type: domain.AttributeType("float")},
		},
	})
	if err == nil {
		t.Fatal("expected error for unknown attribute type")
	}
	if !errors.Is(err, domain.ErrUnsupportedFieldType) {
		t.Errorf("expected ErrUnsupportedFieldType, got: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Verify the transactional outbox pattern: schema save and outbox event are
// written atomically (in the fake, both succeed or both fail).
// ---------------------------------------------------------------------------

func TestDefineSchema_OutboxEventWritten(t *testing.T) {
	t.Parallel()

	schemaRepo := newFakeSchemaRepo()
	outboxRepo := newFakeOutboxRepo()
	eventPub := newFakeEventPublisher()

	svc := NewSchemaService(
		schemaRepo,
		outboxRepo,
		newFakeUnitOfWork(),
		eventPub,
		newFakeValidator(),
		testLogger(),
	)

	ctx := context.Background()
	input := customerSchemaInput()

	result, err := svc.DefineSchema(ctx, input)
	if err != nil {
		t.Fatalf("define schema: %v", err)
	}

	// Verify outbox has exactly one pending event with the correct type.
	pending, err := outboxRepo.FetchPending(ctx, 10)
	if err != nil {
		t.Fatalf("fetch pending outbox events: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("expected 1 pending outbox event, got %d", len(pending))
	}

	event := pending[0]
	if event.EventType != "entity.schema.defined" {
		t.Errorf("expected event type 'entity.schema.defined', got %q", event.EventType)
	}
	if event.AggregateID != result.Schema.ID {
		t.Errorf("expected aggregate ID %q, got %q", result.Schema.ID, event.AggregateID)
	}
	if event.AggregateType != "entity_schema" {
		t.Errorf("expected aggregate type 'entity_schema', got %q", event.AggregateType)
	}
	if event.Status != domain.OutboxStatusPending {
		t.Errorf("expected status 'pending', got %q", event.Status)
	}
}

// ---------------------------------------------------------------------------
// Verify no outbox event is written when schema creation fails.
// ---------------------------------------------------------------------------

func TestDefineSchema_Duplicate_NoOutboxEvent(t *testing.T) {
	t.Parallel()

	schemaRepo := newFakeSchemaRepo()
	outboxRepo := newFakeOutboxRepo()
	eventPub := newFakeEventPublisher()

	svc := NewSchemaService(
		schemaRepo,
		outboxRepo,
		newFakeUnitOfWork(),
		eventPub,
		newFakeValidator(),
		testLogger(),
	)

	ctx := context.Background()
	input := customerSchemaInput()

	// First definition succeeds.
	_, err := svc.DefineSchema(ctx, input)
	if err != nil {
		t.Fatalf("first define: %v", err)
	}

	// Second definition should fail.
	_, err = svc.DefineSchema(ctx, input)
	if err == nil {
		t.Fatal("expected error for duplicate schema name")
	}
	if !errors.Is(err, domain.ErrSchemaAlreadyExists) {
		t.Fatalf("expected ErrSchemaAlreadyExists, got: %v", err)
	}

	// Only one outbox event (from the first success).
	pending, err := outboxRepo.FetchPending(ctx, 10)
	if err != nil {
		t.Fatalf("fetch pending: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("expected exactly 1 pending outbox event after duplicate rejection, got %d", len(pending))
	}
}

// ---------------------------------------------------------------------------
// Verify the schema defined event is published via EventPublisher.
// ---------------------------------------------------------------------------

func TestDefineSchema_EventPublished(t *testing.T) {
	t.Parallel()

	eventPub := newFakeEventPublisher()
	svc := NewSchemaService(
		newFakeSchemaRepo(),
		newFakeOutboxRepo(),
		newFakeUnitOfWork(),
		eventPub,
		newFakeValidator(),
		testLogger(),
	)

	ctx := context.Background()
	input := customerSchemaInput()

	result, err := svc.DefineSchema(ctx, input)
	if err != nil {
		t.Fatalf("define schema: %v", err)
	}

	// Check event was published via EventPublisher.
	events := eventPub.Events()
	if len(events) != 1 {
		t.Fatalf("expected 1 event published, got %d", len(events))
	}

	evt, ok := events[0].(*domain.EntitySchemaDefined)
	if !ok {
		t.Fatalf("expected *domain.EntitySchemaDefined, got %T", events[0])
	}
	if evt.SchemaID != result.Schema.ID {
		t.Errorf("event schema ID mismatch: %q vs %q", evt.SchemaID, result.Schema.ID)
	}
	if evt.SchemaName != "Customer" {
		t.Errorf("event schema name mismatch: %q vs %q", evt.SchemaName, "Customer")
	}
	if evt.Version != 1 {
		t.Errorf("event version mismatch: %d vs 1", evt.Version)
	}
}
