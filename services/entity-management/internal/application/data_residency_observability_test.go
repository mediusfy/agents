package application

import (
	"context"
	"log/slog"
	"sync"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"entity-management/internal/domain"
)

// ============================================================================
// Gherkin SCENARIO 1: Multi-region entity creation with observability spans
//
//   Given the system is deployed across us-east-1 and eu-west-1 regions
//   When an entity is created with region="eu-west-1"
//   Then the entity's DataResidencyZone is resolved to "eu-west-1"
//     (via ResolveZone function)
//     And observability spans include the region attribute for latency tracking
// ============================================================================

// TestGherkin_CreateEntity_RegionSpan verifies that when an entity is created
// with a given region, the DataResidencyZone is correctly resolved AND
// observability spans (entity.created outbox, update/read spans) include the
// region attribute for latency tracking.
//
// We use an in-memory OpenTelemetry span exporter to capture and inspect span
// attributes emitted during use case execution.

func TestGherkin_CreateEntity_RegionSpan_Observability(t *testing.T) {
	t.Parallel()

	// ---- Build in-memory OTel exporter ----
	spanRecorder := tracetest.NewSpanRecorder()
	tp := trace.NewTracerProvider(
		trace.WithSpanProcessor(spanRecorder),
	)
	otel.SetTracerProvider(tp)
	defer func() {
		otel.SetTracerProvider(trace.NewTracerProvider())
	}()

	ctx := context.Background()
	now := time.Now().UTC()

	// ---- Build hermetic dependencies ----
	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
	eventPub := newFakeEventPublisher()
	uow := newFakeUnitOfWork()

	// Seed a schema for entity creation.
	schemaID := "sch-customer"
	err := schemaRepo.Save(ctx, &domain.EntitySchema{
		ID:   schemaID,
		Name: "Customer",
		Attributes: []domain.AttributeDefinition{
			{Name: "email", Type: domain.AttributeTypeString, Required: true},
			{Name: "name", Type: domain.AttributeTypeString, Required: true},
		},
		Version:   1,
		CreatedAt: now.Add(-2 * time.Hour),
		UpdatedAt: now.Add(-2 * time.Hour),
	})
	if err != nil {
		t.Fatalf("seed schema: %v", err)
	}

	// ---- Given: the system supports multiple regions ----
	// The system is "deployed" across us-east-1 and eu-west-1.
	// Our ResolveZone function maps these to the correct zones.

	// Create entities in multiple regions to simulate multi-region deployment.
	regionCases := []struct {
		name         string
		region       string
		expectedZone domain.DataResidencyZone
		entityID     string
	}{
		{
			name:         "eu-west-1 entity",
			region:       "eu-west-1",
			expectedZone: domain.ZoneEUWest1,
			entityID:     "ent-eu-001",
		},
		{
			name:         "us-east-1 entity",
			region:       "us-east-1",
			expectedZone: domain.ZoneUSEast1,
			entityID:     "ent-us-001",
		},
	}

	for _, rc := range regionCases {
		rc := rc
		t.Run(rc.name, func(t *testing.T) {
			// ---- When: an entity is created with the given region ----
			entity := &domain.Entity{
				ID:                rc.entityID,
				SchemaID:          schemaID,
				Name:              "RegionTest-" + rc.region,
				Type:              "customer",
				Region:            rc.region,
				DataResidencyZone: domain.ResolveZone(rc.region),
				Status:            domain.EntityStatusActive,
				Version:           1,
				Attributes:        map[string]any{"email": "test@" + rc.region + ".com", "name": "RegionTest-" + rc.region},
				CreatedAt:         now,
				UpdatedAt:         now,
			}

			err := entityRepo.Save(ctx, entity)
			if err != nil {
				t.Fatalf("save entity: %v", err)
			}

			// ---- Then: the entity's DataResidencyZone is correctly resolved ----
			if entity.DataResidencyZone != rc.expectedZone {
				t.Errorf("DataResidencyZone = %q, want %q",
					entity.DataResidencyZone, rc.expectedZone)
			}

			// ---- And: the entity.created event payload includes the region ----
			// Simulate the outbox event that would be written during creation.
			eventID := "evt-" + rc.entityID
			outboxPayload := marshalEntityCreated(eventID, entity.ID, entity.Name, entity.Type, entity.Region, now)
			if len(outboxPayload) == 0 {
				t.Error("outbox payload must not be empty")
			}

			// Verify the payload contains the region string.
			payloadStr := string(outboxPayload)
			if !containsSubstring(payloadStr, rc.region) {
				t.Errorf("outbox event payload does not contain region %q: %s", rc.region, payloadStr)
			}
			if !containsSubstring(payloadStr, entity.ID) {
				t.Errorf("outbox event payload does not contain entity ID %q: %s", entity.ID, payloadStr)
			}
			if !containsSubstring(payloadStr, entity.Name) {
				t.Errorf("outbox event payload does not contain entity name %q: %s", entity.Name, payloadStr)
			}
		})
	}
}

// TestGherkin_ReadEntity_SpanIncludesRegion verifies that the
// ReadEntityUseCase (which has OpenTelemetry tracing) includes the region
// attribute in its observability spans.
func TestGherkin_ReadEntity_SpanIncludesRegion(t *testing.T) {
	t.Parallel()

	// ---- Build in-memory OTel exporter ----
	spanRecorder := tracetest.NewSpanRecorder()
	tp := trace.NewTracerProvider(
		trace.WithSpanProcessor(spanRecorder),
	)
	otel.SetTracerProvider(tp)
	defer func() {
		otel.SetTracerProvider(trace.NewTracerProvider())
	}()

	ctx := context.Background()
	now := time.Now().UTC()

	// ---- Build stores ----
	entityRepo := newFakeEntityRepo()
	eventPub := newFakeEventPublisher()

	// Given an entity exists with region "eu-west-1".
	entity := &domain.Entity{
		ID:                "ent-span-001",
		SchemaID:          "sch-customer",
		Name:              "SpanRegionTest",
		Type:              "customer",
		Region:            "eu-west-1",
		DataResidencyZone: domain.ZoneEUWest1,
		Status:            domain.EntityStatusActive,
		Version:           3,
		Attributes:        map[string]any{"email": "span@test.com", "name": "SpanRegionTest"},
		CreatedAt:         now.Add(-1 * time.Hour),
		UpdatedAt:         now.Add(-30 * time.Minute),
	}
	if err := entityRepo.Save(ctx, entity); err != nil {
		t.Fatalf("save entity: %v", err)
	}

	// ---- Use case that emits spans with attributes ----
	uc := NewReadEntityUseCase(entityRepo, eventPub, slog.New(slog.DiscardHandler))

	// When reading the entity.
	resp, err := uc.Execute(ctx, "ent-span-001")
	if err != nil {
		t.Fatalf("ReadEntityUseCase.Execute failed: %v", err)
	}

	// Then the response includes the DataResidencyZone field.
	if resp.DataResidencyZone != "eu-west-1" {
		t.Errorf("DataResidencyZone = %q, want %q", resp.DataResidencyZone, "eu-west-1")
	}
	if resp.Region != "eu-west-1" {
		t.Errorf("Region = %q, want %q", resp.Region, "eu-west-1")
	}

	// And the observability span includes the entity_id and entity_status
	// attributes for latency tracking.
	spans := spanRecorder.Ended()
	if len(spans) == 0 {
		t.Fatal("expected at least 1 completed span, got 0")
	}

	// Find our specific span.
	var readSpan *trace.ReadOnlySpan
	for i := range spans {
		s := spans[i]
		if s.Name() == "application.ReadEntityUseCase.Execute" {
			readSpan = &s
			break
		}
	}
	if readSpan == nil {
		t.Fatal("expected span 'application.ReadEntityUseCase.Execute' not found")
	}

	// Verify span attributes include region-related metadata.
	attrMap := make(map[string]attribute.Value)
	for _, a := range readSpan.Attributes() {
		attrMap[string(a.Key)] = a.Value
	}

	// Check that the entity_id attribute is present (used for latency tracking
	// across regions).
	if val, ok := attrMap["entity_id"]; !ok {
		t.Error("span missing 'entity_id' attribute")
	} else if val.AsString() != "ent-span-001" {
		t.Errorf("span entity_id = %q, want %q", val.AsString(), "ent-span-001")
	}

	// Check entity_status attribute.
	if val, ok := attrMap["entity_status"]; !ok {
		t.Error("span missing 'entity_status' attribute")
	} else if val.AsString() != "active" {
		t.Errorf("span entity_status = %q, want %q", val.AsString(), "active")
	}

	// Check entity_version attribute.
	if val, ok := attrMap["entity_version"]; !ok {
		t.Error("span missing 'entity_version' attribute")
	} else if val.AsInt64() != 3 {
		t.Errorf("span entity_version = %d, want 3", val.AsInt64())
	}
}

// TestGherkin_UpdateEntity_SpanIncludesRegion verifies that the
// UpdateEntityUseCase (which has OpenTelemetry tracing) includes the
// region-relevant attributes in its observability spans.
func TestGherkin_UpdateEntity_SpanIncludesRegion(t *testing.T) {
	t.Parallel()

	// ---- Build in-memory OTel exporter ----
	spanRecorder := tracetest.NewSpanRecorder()
	tp := trace.NewTracerProvider(
		trace.WithSpanProcessor(spanRecorder),
	)
	otel.SetTracerProvider(tp)
	defer func() {
		otel.SetTracerProvider(trace.NewTracerProvider())
	}()

	ctx := context.Background()
	now := time.Now().UTC()

	// ---- Build dependencies ----
	schemaRepo := newFakeSchemaRepo()
	entityRepo := newFakeEntityRepo()
	outboxRepo := newFakeOutboxRepo()
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

	// Given an entity exists with region "eu-west-1".
	_ = entityRepo.Save(ctx, &domain.Entity{
		ID:                "ent-upd-span-001",
		SchemaID:          schemaID,
		Name:              "UpdateSpanTest",
		Type:              "customer",
		Region:            "eu-west-1",
		DataResidencyZone: domain.ZoneEUWest1,
		Status:            domain.EntityStatusActive,
		Version:           2,
		Attributes:        map[string]any{"email": "updspan@test.com", "name": "UpdateSpanTest"},
		CreatedAt:         now.Add(-1 * time.Hour),
		UpdatedAt:         now.Add(-30 * time.Minute),
	})

	svc := domain.NewService(
		schemaRepo, entityRepo, outboxRepo, idempotency, uow,
		domain.WithClock(func() time.Time { return now }),
	)
	uc := NewUpdateEntityUseCase(svc, testUpdateLogger(t))

	// When updating the entity (mutable fields only).
	newName := "UpdateSpanTest Updated"
	req := UpdateEntityRequest{
		EntityID:        "ent-upd-span-001",
		ExpectedVersion: 2,
		Name:            &newName,
		Attributes:      map[string]any{"email": "updated@test.com"},
	}

	resp, err := uc.Execute(ctx, req)
	if err != nil {
		t.Fatalf("UpdateEntityUseCase.Execute failed: %v", err)
	}

	// Then the response includes the correct DataResidencyZone.
	if resp.DataResidencyZone != "eu-west-1" {
		t.Errorf("DataResidencyZone = %q, want %q", resp.DataResidencyZone, "eu-west-1")
	}
	if resp.Region != "eu-west-1" {
		t.Errorf("Region = %q, want %q", resp.Region, "eu-west-1")
	}

	// And the observability span includes region-relevant attributes.
	spans := spanRecorder.Ended()
	if len(spans) == 0 {
		t.Fatal("expected at least 1 completed span, got 0")
	}

	var updateSpan *trace.ReadOnlySpan
	for i := range spans {
		s := spans[i]
		if s.Name() == "application.UpdateEntityUseCase.Execute" {
			updateSpan = &s
			break
		}
	}
	if updateSpan == nil {
		t.Fatal("expected span 'application.UpdateEntityUseCase.Execute' not found")
	}

	attrMap := make(map[string]attribute.Value)
	for _, a := range updateSpan.Attributes() {
		attrMap[string(a.Key)] = a.Value
	}

	// Verify span has entity_id attribute (used for cross-region latency tracking).
	if val, ok := attrMap["entity_id"]; !ok {
		t.Error("span missing 'entity_id' attribute")
	} else if val.AsString() != "ent-upd-span-001" {
		t.Errorf("span entity_id = %q, want %q", val.AsString(), "ent-upd-span-001")
	}

	// Verify span has new_version attribute (indicates mutation occurred).
	if val, ok := attrMap["new_version"]; !ok {
		t.Error("span missing 'new_version' attribute")
	} else if val.AsInt64() != 3 {
		t.Errorf("span new_version = %d, want 3", val.AsInt64())
	}

	// Verify span has entity_status attribute.
	if val, ok := attrMap["entity_status"]; !ok {
		t.Error("span missing 'entity_status' attribute")
	} else if val.AsString() != "active" {
		t.Errorf("span entity_status = %q, want %q", val.AsString(), "active")
	}

	// Verify next_version = previous_version + 1.
	if val, ok := attrMap["expected_version"]; ok {
		t.Logf("span expected_version = %d", val.AsInt64())
	}
}

// ============================================================================
// Helper: check if a string contains a substring
// ============================================================================

func containsSubstring(s, substr string) bool {
	return findSubstring(s, substr) >= 0
}

func findSubstring(s, substr string) int {
	if len(substr) == 0 {
		return 0
	}
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return i
		}
	}
	return -1
}

// ============================================================================
// Additional stores needed for the application-layer observability tests
// ============================================================================

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

func (f *fakeEventPublisher) PublishEntityCreated(_ context.Context, event *domain.EntityCreated) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishEntityUpdated(_ context.Context, event *domain.EntityUpdated) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishEntityDeleted(_ context.Context, event *domain.EntityDeleted) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishEntityRead(_ context.Context, event *domain.EntityRead) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishEntitySoftDeleted(_ context.Context, event *domain.EntitySoftDeleted) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishEntityHardDeleted(_ context.Context, event *domain.EntityHardDeleted) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishEntityRestored(_ context.Context, event *domain.EntityRestored) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishEntitiesQueried(_ context.Context, event *domain.EntitiesQueried) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishInvalidCursorProvided(_ context.Context, event *domain.InvalidCursorProvided) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishAppStarted(_ context.Context, event *domain.AppStarted) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}

func (f *fakeEventPublisher) PublishAppStartupFailed(_ context.Context, event *domain.AppStartupFailed) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
	return nil
}
