package application

import (
	"context"
	"errors"
	"strings"
	"testing"

	"entity-management/internal/domain"
)

// ---------------------------------------------------------------------------
// Table-driven tests for the DefineSchema use case, mapping directly to
// the Gherkin acceptance criteria.
//
// Uses standard library testing patterns consistent with the existing
// schema_service_test.go — no external assertion library required.
// ---------------------------------------------------------------------------

func TestDefineSchema_GherkinScenarios(t *testing.T) {
	t.Parallel()

	// ─── Shared test input matching the Gherkin data table ────────────────
	zero := 0
	oneFifty := 150

	type gherkinAttr struct {
		name       string
		attrType   domain.AttributeType
		required   bool
		constraint *domain.Constraint
	}

	customerAttrs := []gherkinAttr{
		{name: "email", attrType: domain.AttributeTypeString, required: true,
			constraint: &domain.Constraint{Pattern: `^[^@]+@[^@]+$`}},
		{name: "age", attrType: domain.AttributeTypeInt, required: false,
			constraint: &domain.Constraint{Min: &zero, Max: &oneFifty}},
		{name: "isActive", attrType: domain.AttributeTypeBool, required: false},
		{name: "status", attrType: domain.AttributeTypeEnum, required: true,
			constraint: &domain.Constraint{Enum: []string{"active", "inactive"}}},
		{name: "metadata", attrType: domain.AttributeTypeMap, required: false},
		{name: "config", attrType: domain.AttributeTypeJSON, required: false},
	}

	toInput := func(attrs []gherkinAttr) *domain.DefineSchemaInput {
		defs := make([]domain.AttributeDefinition, len(attrs))
		for i, a := range attrs {
			defs[i] = domain.AttributeDefinition{
				Name:       a.name,
				Type:       a.attrType,
				Required:   a.required,
				Constraint: a.constraint,
			}
		}
		return &domain.DefineSchemaInput{
			Name:       "Customer",
			Attributes: defs,
		}
	}

	// ─── Test cases ───────────────────────────────────────────────────────
	tests := []struct {
		name          string
		setup         func(svc *SchemaService) error // optional pre-condition
		input         *domain.DefineSchemaInput      // the payload
		wantErr       error                          // expected sentinel error (nil = success)
		wantVersion   int                            // expected schema version on success
		wantAttrCount int                            // expected number of attributes
		wantEventType string                         // expected CloudEvent type
		wantNoOutbox  bool                           // true = no outbox event should exist
	}{
		{
			name:          "GHERKIN_SCENARIO_1: Define Customer schema with all supported types",
			setup:         nil, // empty registry
			input:         toInput(customerAttrs),
			wantErr:       nil,
			wantVersion:   1,
			wantAttrCount: 6,
			wantEventType: "entity.schema.defined",
			wantNoOutbox:  false,
		},
		{
			name: "GHERKIN_SCENARIO_2: Duplicate schema name fails with ErrSchemaAlreadyExists",
			setup: func(svc *SchemaService) error {
				_, err := svc.DefineSchema(context.Background(), toInput(customerAttrs))
				return err
			},
			input:        toInput(customerAttrs),
			wantErr:      domain.ErrSchemaAlreadyExists,
			wantNoOutbox: true, // no outbox event on failure
		},
		{
			name: "Schema with empty name is rejected",
			input: &domain.DefineSchemaInput{
				Name:       "",
				Attributes: []domain.AttributeDefinition{{Name: "a", Type: domain.AttributeTypeString}},
			},
			wantErr:      domain.ErrInvalidSchema,
			wantNoOutbox: true,
		},
		{
			name: "Schema with no attributes is rejected",
			input: &domain.DefineSchemaInput{
				Name:       "Empty",
				Attributes: nil,
			},
			wantErr:      domain.ErrInvalidSchema,
			wantNoOutbox: true,
		},
		{
			name: "Schema with unsupported attribute type is rejected",
			input: &domain.DefineSchemaInput{
				Name: "BadType",
				Attributes: []domain.AttributeDefinition{
					{Name: "x", Type: domain.AttributeType("float")},
				},
			},
			wantErr:      domain.ErrUnsupportedFieldType,
			wantNoOutbox: true,
		},
		{
			name: "Schema with valid single attribute succeeds",
			input: &domain.DefineSchemaInput{
				Name: "Simple",
				Attributes: []domain.AttributeDefinition{
					{Name: "a", Type: domain.AttributeTypeString, Required: true},
				},
			},
			wantErr:       nil,
			wantVersion:   1,
			wantAttrCount: 1,
			wantEventType: "entity.schema.defined",
			wantNoOutbox:  false,
		},
	}

	for _, tt := range tests {
		tt := tt // capture range variable
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			// ── Fresh service for each test case ──
			schemaRepo := newFakeSchemaRepo()
			outboxRepo := newFakeOutboxRepo()
			eventPub := newFakeEventPublisher()

			svc := NewSchemaService(
				schemaRepo,
				outboxRepo,
				newFakeUnitOfWork(),
				eventPub,
				newFakeValidator(),
				noopTestLogger(),
			)

			ctx := context.Background()

			// ── Setup precondition (e.g., create existing schema) ──
			if tt.setup != nil {
				err := tt.setup(svc)
				if err != nil {
					t.Fatalf("setup precondition failed: %v", err)
				}
			}

			// ── Act ──
			result, err := svc.DefineSchema(ctx, tt.input)

			// ── Assert error ──
			if tt.wantErr != nil {
				if err == nil {
					t.Fatalf("expected error wrapping %v, got nil", tt.wantErr)
				}
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("expected error to wrap %v, got: %v (type: %T)", tt.wantErr, err, err)
				}
				if result != nil {
					t.Fatal("expected nil result on error")
				}
				return
			}

			// ── Assert success ──
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if result == nil {
				t.Fatal("expected non-nil result")
			}

			// Schema identity
			if result.Schema.ID == "" {
				t.Fatal("schema ID must be non-empty")
			}
			if result.Schema.Name != tt.input.Name {
				t.Errorf("schema name mismatch: got %q, want %q", result.Schema.Name, tt.input.Name)
			}
			if result.Schema.Version != tt.wantVersion {
				t.Errorf("schema version mismatch: got %d, want %d", result.Schema.Version, tt.wantVersion)
			}

			// Attribute count
			if tt.wantAttrCount > 0 && len(result.Schema.Attributes) != tt.wantAttrCount {
				t.Errorf("attribute count mismatch: got %d, want %d", len(result.Schema.Attributes), tt.wantAttrCount)
			}

			// Timestamps
			if result.Schema.CreatedAt.IsZero() {
				t.Error("CreatedAt must be set")
			}
			if result.Schema.UpdatedAt.IsZero() {
				t.Error("UpdatedAt must be set")
			}

			// ── Then: Event is emitted ──
			if result.Event == nil {
				t.Fatal("expected a schema.defined event to be emitted")
			}
			if result.Event.SchemaID != result.Schema.ID {
				t.Errorf("event schema ID mismatch: got %q, want %q", result.Event.SchemaID, result.Schema.ID)
			}
			if result.Event.SchemaName != result.Schema.Name {
				t.Errorf("event schema name mismatch: got %q, want %q", result.Event.SchemaName, result.Schema.Name)
			}
			if result.Event.Version != tt.wantVersion {
				t.Errorf("event version mismatch: got %d, want %d", result.Event.Version, tt.wantVersion)
			}
			if result.Event.EventID == "" {
				t.Error("event ID must be non-empty")
			}
			if result.Event.OccurredAt.IsZero() {
				t.Error("event occurred_at must be set")
			}

			// ── Then: The event is published via EventPublisher ──
			publishedEvents := eventPub.Events()
			if len(publishedEvents) != 1 {
				t.Fatalf("expected exactly 1 published event, got %d", len(publishedEvents))
			}

			evt, ok := publishedEvents[0].(*domain.EntitySchemaDefined)
			if !ok {
				t.Fatalf("expected event type *domain.EntitySchemaDefined, got %T", publishedEvents[0])
			}
			if evt.SchemaID != result.Schema.ID {
				t.Errorf("published event schema ID mismatch: %q vs %q", evt.SchemaID, result.Schema.ID)
			}
			if evt.SchemaName != result.Schema.Name {
				t.Errorf("published event schema name mismatch: %q vs %q", evt.SchemaName, result.Schema.Name)
			}
			if evt.Version != tt.wantVersion {
				t.Errorf("published event version mismatch: %d vs %d", evt.Version, tt.wantVersion)
			}

			// ── Then: Outbox event is written ──
			if !tt.wantNoOutbox {
				pending, err := outboxRepo.FetchPending(ctx, 10)
				if err != nil {
					t.Fatalf("fetch pending outbox events: %v", err)
				}
				if len(pending) != 1 {
					t.Fatalf("expected exactly 1 pending outbox event, got %d", len(pending))
				}

				oe := pending[0]
				if oe.EventType != "entity.schema.defined" {
					t.Errorf("outbox event type mismatch: got %q, want %q", oe.EventType, "entity.schema.defined")
				}
				if oe.AggregateID != result.Schema.ID {
					t.Errorf("outbox aggregate ID mismatch: got %q, want %q", oe.AggregateID, result.Schema.ID)
				}
				if oe.AggregateType != "entity_schema" {
					t.Errorf("outbox aggregate type mismatch: got %q, want %q", oe.AggregateType, "entity_schema")
				}
				if oe.Status != domain.OutboxStatusPending {
					t.Errorf("outbox status should be pending, got %q", oe.Status)
				}
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Gherkin-specific: Verify all attribute types and constraints are persisted
// exactly as defined in the data table.
// ---------------------------------------------------------------------------

func TestDefineSchema_GherkinCustomerAttributes(t *testing.T) {
	t.Parallel()

	svc := newSchemaService()
	ctx := context.Background()

	// Build the Customer schema with the Gherkin data table
	zero := 0
	oneFifty := 150

	input := &domain.DefineSchemaInput{
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

	// When an admin defines the schema
	result, err := svc.DefineSchema(ctx, input)
	if err != nil {
		t.Fatalf("define schema: %v", err)
	}
	if result.Schema == nil {
		t.Fatal("expected schema to be returned")
	}

	schema := result.Schema

	// Then the schema is stored with a unique schema ID
	if schema.ID == "" {
		t.Fatal("schema ID must not be empty")
	}

	// And version 1
	if schema.Version != 1 {
		t.Fatalf("expected version 1, got %d", schema.Version)
	}

	// And name is "Customer"
	if schema.Name != "Customer" {
		t.Fatalf("expected name 'Customer', got %q", schema.Name)
	}

	// Build a map for easier assertion
	attrMap := make(map[string]domain.AttributeDefinition)
	for _, a := range schema.Attributes {
		attrMap[a.Name] = a
	}

	if len(attrMap) != 6 {
		t.Fatalf("expected 6 attributes, got %d", len(attrMap))
	}

	// ── Assert each attribute from the Gherkin data table ──

	// email: string, required, pattern constraint
	email, ok := attrMap["email"]
	if !ok {
		t.Fatal("email attribute must exist")
	}
	if email.Type != domain.AttributeTypeString {
		t.Errorf("email type: got %q, want %q", email.Type, domain.AttributeTypeString)
	}
	if !email.Required {
		t.Error("email should be required")
	}
	if email.Constraint == nil {
		t.Fatal("email must have a constraint")
	}
	if email.Constraint.Pattern != `^[^@]+@[^@]+$` {
		t.Errorf("email pattern: got %q, want %q", email.Constraint.Pattern, `^[^@]+@[^@]+$`)
	}

	// age: int, optional, min=0 max=150
	age, ok := attrMap["age"]
	if !ok {
		t.Fatal("age attribute must exist")
	}
	if age.Type != domain.AttributeTypeInt {
		t.Errorf("age type: got %q, want %q", age.Type, domain.AttributeTypeInt)
	}
	if age.Required {
		t.Error("age should not be required")
	}
	if age.Constraint == nil {
		t.Fatal("age must have a constraint")
	}
	if age.Constraint.Min == nil || *age.Constraint.Min != 0 {
		t.Errorf("age min: got %v, want 0", age.Constraint.Min)
	}
	if age.Constraint.Max == nil || *age.Constraint.Max != 150 {
		t.Errorf("age max: got %v, want 150", age.Constraint.Max)
	}

	// isActive: bool, optional
	isActive, ok := attrMap["isActive"]
	if !ok {
		t.Fatal("isActive attribute must exist")
	}
	if isActive.Type != domain.AttributeTypeBool {
		t.Errorf("isActive type: got %q, want %q", isActive.Type, domain.AttributeTypeBool)
	}
	if isActive.Required {
		t.Error("isActive should not be required")
	}

	// status: enum, required, enum=[active,inactive]
	status, ok := attrMap["status"]
	if !ok {
		t.Fatal("status attribute must exist")
	}
	if status.Type != domain.AttributeTypeEnum {
		t.Errorf("status type: got %q, want %q", status.Type, domain.AttributeTypeEnum)
	}
	if !status.Required {
		t.Error("status should be required")
	}
	if status.Constraint == nil {
		t.Fatal("status must have a constraint")
	}
	if len(status.Constraint.Enum) != 2 {
		t.Fatalf("expected 2 enum values, got %d", len(status.Constraint.Enum))
	}
	if status.Constraint.Enum[0] != "active" || status.Constraint.Enum[1] != "inactive" {
		t.Errorf("status enum values: got %v, want [active inactive]", status.Constraint.Enum)
	}

	// metadata: map, optional
	metadata, ok := attrMap["metadata"]
	if !ok {
		t.Fatal("metadata attribute must exist")
	}
	if metadata.Type != domain.AttributeTypeMap {
		t.Errorf("metadata type: got %q, want %q", metadata.Type, domain.AttributeTypeMap)
	}
	if metadata.Required {
		t.Error("metadata should not be required")
	}

	// config: json, optional
	config, ok := attrMap["config"]
	if !ok {
		t.Fatal("config attribute must exist")
	}
	if config.Type != domain.AttributeTypeJSON {
		t.Errorf("config type: got %q, want %q", config.Type, domain.AttributeTypeJSON)
	}
	if config.Required {
		t.Error("config should not be required")
	}

	// ── Verify the CloudEvent was emitted ──
	if result.Event == nil {
		t.Fatal("EntitySchemaDefined event must be emitted")
	}
	if result.Event.SchemaID != schema.ID {
		t.Errorf("event schema ID mismatch: got %q, want %q", result.Event.SchemaID, schema.ID)
	}
	if result.Event.SchemaName != "Customer" {
		t.Errorf("event schema name mismatch: got %q, want %q", result.Event.SchemaName, "Customer")
	}
	if result.Event.Version != 1 {
		t.Errorf("event version mismatch: got %d, want 1", result.Event.Version)
	}
	if result.Event.EventName() != "entity.schema.defined" {
		t.Errorf("event name mismatch: got %q, want %q", result.Event.EventName(), "entity.schema.defined")
	}
}

// ---------------------------------------------------------------------------
// Gherkin: Duplicate schema name → ErrSchemaAlreadyExists, no event emitted
// ---------------------------------------------------------------------------

func TestDefineSchema_DuplicateName_NoEventEmitted(t *testing.T) {
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
		noopTestLogger(),
	)

	ctx := context.Background()

	// Given: a schema named "Customer" already exists
	input := customerSchemaInput()
	firstResult, err := svc.DefineSchema(ctx, input)
	if err != nil {
		t.Fatalf("first define: %v", err)
	}
	if firstResult.Schema == nil {
		t.Fatal("expected schema from first define")
	}

	// Given: pre-assert that an event was emitted for the first definition
	if len(eventPub.Events()) != 1 {
		t.Fatalf("expected 1 event after first define, got %d", len(eventPub.Events()))
	}

	// When: an admin attempts to define another schema with the same name
	secondResult, err := svc.DefineSchema(ctx, input)

	// Then: the operation fails with ErrSchemaAlreadyExists
	if err == nil {
		t.Fatal("expected error for duplicate schema name, got nil")
	}
	if !errors.Is(err, domain.ErrSchemaAlreadyExists) {
		t.Fatalf("expected ErrSchemaAlreadyExists, got: %v (type: %T)", err, err)
	}
	if secondResult != nil {
		t.Fatal("expected nil result on duplicate")
	}

	// And: no additional schema.defined event is emitted
	events := eventPub.Events()
	if len(events) != 1 {
		t.Errorf("expected only 1 event (from the first define), got %d", len(events))
	}

	// And: only one outbox event (from the first success)
	pending, err := outboxRepo.FetchPending(ctx, 10)
	if err != nil {
		t.Fatalf("fetch pending: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("expected only 1 pending outbox event, got %d", len(pending))
	}

	// Verify the single event is from the first successful definition
	evt, ok := events[0].(*domain.EntitySchemaDefined)
	if !ok {
		t.Fatalf("expected *domain.EntitySchemaDefined, got %T", events[0])
	}
	if evt.SchemaID != firstResult.Schema.ID {
		t.Errorf("event schema ID mismatch: got %q, want %q", evt.SchemaID, firstResult.Schema.ID)
	}
	if evt.Version != 1 {
		t.Errorf("event version mismatch: got %d, want 1", evt.Version)
	}
}

// ---------------------------------------------------------------------------
// Gherkin: Verify the schema is persisted and retrievable
// ---------------------------------------------------------------------------

func TestDefineSchema_VerifyPersistence(t *testing.T) {
	t.Parallel()

	svc := newSchemaService()
	ctx := context.Background()

	input := customerSchemaInput()

	// Define the schema
	result, err := svc.DefineSchema(ctx, input)
	if err != nil {
		t.Fatalf("define schema: %v", err)
	}
	schemaID := result.Schema.ID

	// Retrieve by ID
	retrieved, err := svc.GetSchema(ctx, schemaID)
	if err != nil {
		t.Fatalf("get schema: %v", err)
	}
	if retrieved.Name != "Customer" {
		t.Errorf("retrieved name: got %q, want %q", retrieved.Name, "Customer")
	}
	if retrieved.Version != 1 {
		t.Errorf("retrieved version: got %d, want 1", retrieved.Version)
	}
	if len(retrieved.Attributes) != 6 {
		t.Errorf("retrieved attribute count: got %d, want 6", len(retrieved.Attributes))
	}

	// Retrieve by name
	_, err = svc.schemas.FindByName(ctx, "Customer")
	if err != nil {
		t.Fatalf("find by name: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Gherkin: The transactional outbox contains the correct CloudEvent payload
// ---------------------------------------------------------------------------

func TestDefineSchema_OutboxContainsCloudEvent(t *testing.T) {
	t.Parallel()

	outboxRepo := newFakeOutboxRepo()
	svc := NewSchemaService(
		newFakeSchemaRepo(),
		outboxRepo,
		newFakeUnitOfWork(),
		newFakeEventPublisher(),
		newFakeValidator(),
		noopTestLogger(),
	)

	ctx := context.Background()
	input := customerSchemaInput()

	result, err := svc.DefineSchema(ctx, input)
	if err != nil {
		t.Fatalf("define schema: %v", err)
	}

	// Fetch pending outbox events
	pending, err := outboxRepo.FetchPending(ctx, 10)
	if err != nil {
		t.Fatalf("fetch pending: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("expected 1 pending outbox event, got %d", len(pending))
	}

	oe := pending[0]
	if oe.EventType != "entity.schema.defined" {
		t.Errorf("event type: got %q, want %q", oe.EventType, "entity.schema.defined")
	}
	if oe.AggregateID != result.Schema.ID {
		t.Errorf("aggregate ID mismatch: got %q, want %q", oe.AggregateID, result.Schema.ID)
	}
	if oe.AggregateType != "entity_schema" {
		t.Errorf("aggregate type: got %q, want %q", oe.AggregateType, "entity_schema")
	}
	if oe.Status != domain.OutboxStatusPending {
		t.Errorf("outbox status: got %q, want %q", oe.Status, domain.OutboxStatusPending)
	}

	// Verify payload contains expected fields
	payloadStr := string(oe.Payload)
	if !strings.Contains(payloadStr, result.Schema.ID) {
		t.Error("payload should contain schema ID")
	}
	if !strings.Contains(payloadStr, "Customer") {
		t.Error("payload should contain schema name 'Customer'")
	}
	if !strings.Contains(payloadStr, `"version":1`) {
		t.Error("payload should contain version 1")
	}
	if !strings.Contains(payloadStr, `"event_id"`) {
		t.Error("payload should contain event_id")
	}
	if !strings.Contains(payloadStr, `"occurred_at"`) {
		t.Error("payload should contain occurred_at")
	}
}
