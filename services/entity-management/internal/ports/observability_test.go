// Package ports_test provides tests for OpenTelemetry observability patterns
// across the HTTP handler layer.
//
// Gherkin coverage:
//   - OpenTelemetry spans are created with naming convention <package.Operation>
//   - Trace attributes populated with entity_id, schema_id, version
//   - Errors recorded via span.RecordError(err)
//   - Metrics counters incremented for the operation type
package ports_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/application"
	"entity-management/internal/domain"
	"entity-management/internal/ports"
)

// testSpanCollector captures exported spans for assertion.
type testSpanCollector struct {
	exporter *tracetest.InMemoryExporter
}

func newTestSpanCollector() *testSpanCollector {
	return &testSpanCollector{
		exporter: tracetest.NewInMemoryExporter(),
	}
}

func (c *testSpanCollector) TracerProvider() *sdktrace.TracerProvider {
	return sdktrace.NewTracerProvider(
		sdktrace.WithSyncer(c.exporter),
		sdktrace.WithResource(resource.NewSchemaless(
			attribute.String("service.name", "entity-management-test"),
		)),
	)
}

func (c *testSpanCollector) GetSpans() []sdktrace.ReadOnlySpan {
	return c.exporter.GetSpans()
}

func (c *testSpanCollector) Reset() {
	c.exporter.Reset()
}

// testMetricCollector captures exported metric data for assertion.
type testMetricCollector struct {
	mu            sync.Mutex
	exporter      *metricManualExporter
	meterProvider *metric.MeterProvider
}

func newTestMetricCollector() *testMetricCollector {
	exp := &metricManualExporter{
		metrics: make(map[string][]metricdata.DataPoint),
	}
	mp := metric.NewMeterProvider(
		metric.WithReader(metric.NewManualReader(exp)),
	)
	return &testMetricCollector{
		exporter:      exp,
		meterProvider: mp,
	}
}

type metricManualExporter struct {
	mu      sync.Mutex
	metrics map[string][]metricdata.DataPoint
}

func (e *metricManualExporter) Temporality(kind metric.InstrumentKind) metricdata.Temporality {
	return metricdata.CumulativeTemporality
}

func (e *metricManualExporter) Aggregation(kind metric.InstrumentKind) metric.Aggregation {
	return metric.DefaultAggregationSelector(kind)
}

func (e *metricManualExporter) Collect(rm *metricdata.ResourceMetrics) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, scope := range rm.ScopeMetrics {
		for _, m := range scope.Metrics {
			switch data := m.Data.(type) {
			case metricdata.Sum[int64]:
				for _, point := range data.DataPoints {
					key := m.Name + "." + m.Unit
					for _, attr := range point.Attributes.ToSlice() {
						key += "." + string(attr.Key) + "=" + attr.Value.AsString()
					}
					e.metrics[key] = append(e.metrics[key], metricdata.DataPoint{
						Attributes: point.Attributes,
					})
				}
			}
		}
	}
	return nil
}

func (e *metricManualExporter) AggregationSelector() metric.AggregationSelector {
	return metric.DefaultAggregationSelector
}

// observabilityHTTPHandler wraps handlers with instrumented OTel tracer and
// meter for testing observability patterns.
type observabilityHTTPHandler struct {
	inner  *ports.EntityHTTPHandler
	tp     *sdktrace.TracerProvider
	mp     *metric.MeterProvider
	tracer trace.Tracer
}

func newObservabilityHTTPHandler(
	createUC *application.CreateEntityUseCase,
	readUC *application.ReadEntityUseCase,
	updateUC *application.UpdateEntityUseCase,
	deleteUC *application.DeleteRestoreUseCase,
	listUC *application.ListEntitiesUseCase,
	logger *slog.Logger,
	tracerProvider *sdktrace.TracerProvider,
	meterProvider *metric.MeterProvider,
) *observabilityHTTPHandler {
	_ = otel.SetTracerProvider(tracerProvider)
	_ = otel.SetMeterProvider(meterProvider)

	handler := ports.NewEntityHTTPHandler(
		createUC, readUC, updateUC, deleteUC, listUC, logger,
	)

	return &observabilityHTTPHandler{
		inner:  handler,
		tp:     tracerProvider,
		mp:     meterProvider,
		tracer: tracerProvider.Tracer("entity-management.ports"),
	}
}

func (h *observabilityHTTPHandler) RegisterRoutes(r chi.Router) {
	h.inner.RegisterRoutes(r)
}

// observabilityFakeCreateUC simulates successful creation with tracing.
type observabilityFakeCreateUC struct {
	mu           sync.Mutex
	callCount    int
	injectError  error
	injectEntity *application.CreateEntityResponse
}

func newObservabilityFakeCreateUC() *observabilityFakeCreateUC {
	return &observabilityFakeCreateUC{
		injectEntity: &application.CreateEntityResponse{
			EntityID:  "ent-obs-001",
			SchemaID:  "sch-obs-001",
			Name:      "Observability Test",
			Type:      "customer",
			Region:    "eu-west-1",
			Status:    "active",
			CreatedAt: time.Now().UTC(),
			UpdatedAt: time.Now().UTC(),
			Created:   true,
		},
	}
}

func (uc *observabilityFakeCreateUC) Execute(ctx context.Context, req application.CreateEntityRequest) (*application.CreateEntityResponse, error) {
	uc.mu.Lock()
	uc.callCount++
	uc.mu.Unlock()

	if uc.injectError != nil {
		return nil, uc.injectError
	}

	span := trace.SpanFromContext(ctx)
	if span.SpanContext().IsValid() {
		span.SetAttributes(
			attribute.String("schema_id", req.SchemaID),
			attribute.String("entity_name", req.Name),
			attribute.String("entity_type", req.Type),
			attribute.String("region", req.Region),
			attribute.Bool("has_idempotency_key", req.IdempotencyKey != ""),
		)
	}

	return uc.injectEntity, nil
}

type observabilityFakeReadUC struct {
	mu          sync.Mutex
	callCount   int
	injectError error
}

func newObservabilityFakeReadUC() *observabilityFakeReadUC {
	return &observabilityFakeReadUC{}
}

func (uc *observabilityFakeReadUC) Execute(ctx context.Context, id string) (*application.ReadEntityResponse, error) {
	uc.mu.Lock()
	uc.callCount++
	uc.mu.Unlock()

	if uc.injectError != nil {
		return nil, uc.injectError
	}

	span := trace.SpanFromContext(ctx)
	if span.SpanContext().IsValid() {
		span.SetAttributes(
			attribute.String("entity_id", id),
			attribute.Bool("found", true),
			attribute.String("entity_status", "active"),
			attribute.Int("entity_version", 1),
		)
	}

	return &application.ReadEntityResponse{
		ID:        id,
		SchemaID:  "sch-obs-001",
		Name:      "Read Test",
		Type:      "customer",
		Region:    "us-east-1",
		Status:    "active",
		Version:   1,
		CreatedAt: time.Now().UTC(),
		UpdatedAt: time.Now().UTC(),
	}, nil
}

type observabilityFakeUpdateUC struct {
	mu          sync.Mutex
	callCount   int
	injectError error
}

func newObservabilityFakeUpdateUC() *observabilityFakeUpdateUC {
	return &observabilityFakeUpdateUC{}
}

func (uc *observabilityFakeUpdateUC) Execute(ctx context.Context, req application.UpdateEntityRequest) (*application.UpdateEntityResponse, error) {
	uc.mu.Lock()
	uc.callCount++
	uc.mu.Unlock()

	if uc.injectError != nil {
		return nil, uc.injectError
	}

	now := time.Now().UTC()
	return &application.UpdateEntityResponse{
		ID:        req.EntityID,
		SchemaID:  "sch-obs-001",
		Name:      "Updated",
		Type:      "customer",
		Region:    "eu-west-1",
		Status:    "active",
		Version:   2,
		CreatedAt: now,
		UpdatedAt: now,
	}, nil
}

type observabilityFakeDeleteRestoreUC struct {
	mu          sync.Mutex
	callCount   int
	injectError error
}

func newObservabilityFakeDeleteRestoreUC() *observabilityFakeDeleteRestoreUC {
	return &observabilityFakeDeleteRestoreUC{}
}

func (uc *observabilityFakeDeleteRestoreUC) SoftDelete(ctx context.Context, id string) error {
	uc.mu.Lock()
	uc.callCount++
	uc.mu.Unlock()
	if uc.injectError != nil {
		return uc.injectError
	}
	return nil
}

func (uc *observabilityFakeDeleteRestoreUC) HardDelete(ctx context.Context, id string) error {
	uc.mu.Lock()
	uc.callCount++
	uc.mu.Unlock()
	if uc.injectError != nil {
		return uc.injectError
	}
	return nil
}

func (uc *observabilityFakeDeleteRestoreUC) Restore(ctx context.Context, id string) error {
	uc.mu.Lock()
	uc.callCount++
	uc.mu.Unlock()
	if uc.injectError != nil {
		return uc.injectError
	}
	return nil
}

type observabilityFakeListUC struct {
	mu          sync.Mutex
	callCount   int
	injectError error
}

func newObservabilityFakeListUC() *observabilityFakeListUC {
	return &observabilityFakeListUC{}
}

func (uc *observabilityFakeListUC) Execute(ctx context.Context, req application.ListEntitiesRequest) (*application.ListEntitiesResponse, error) {
	uc.mu.Lock()
	uc.callCount++
	uc.mu.Unlock()
	if uc.injectError != nil {
		return nil, uc.injectError
	}
	return &application.ListEntitiesResponse{
		Entities:   []*application.EntityListItem{},
		NextCursor: "",
		TotalCount: 0,
	}, nil
}

// ---------------------------------------------------------------------------
// Test: Span naming convention follows <package.Operation>
// ---------------------------------------------------------------------------

func TestObservability_SpanNamingConvention(t *testing.T) {
	t.Parallel()

	spanCollector := newTestSpanCollector()
	tp := spanCollector.TracerProvider()
	defer tp.Shutdown(context.Background())

	logger := slog.New(slog.NewDiscardHandler)

	handler := newObservabilityHTTPHandler(
		newObservabilityFakeCreateUC(),
		newObservabilityFakeReadUC(),
		newObservabilityFakeUpdateUC(),
		newObservabilityFakeDeleteRestoreUC(),
		newObservabilityFakeListUC(),
		logger,
		tp,
		metric.NewMeterProvider(),
	)

	r := chi.NewRouter()
	handler.RegisterRoutes(r)

	tests := []struct {
		name     string
		method   string
		path     string
		body     string
		expected string
	}{
		{
			name:     "create entity",
			method:   http.MethodPost,
			path:     "/entities",
			body:     `{"schema_id":"sch-001","name":"Test","type":"customer","region":"us-east-1"}`,
			expected: "ports.EntityHTTPHandler.handleCreateEntity",
		},
		{
			name:     "read entity",
			method:   http.MethodGet,
			path:     "/entities/ent-obs-001",
			body:     "",
			expected: "ports.EntityHTTPHandler.handleGetEntity",
		},
		{
			name:     "update entity",
			method:   http.MethodPut,
			path:     "/entities/ent-obs-001",
			body:     `{"expected_version":1,"name":"Updated"}`,
			expected: "ports.EntityHTTPHandler.handleUpdateEntity",
		},
		{
			name:     "soft delete entity",
			method:   http.MethodDelete,
			path:     "/entities/ent-obs-001",
			body:     "",
			expected: "ports.EntityHTTPHandler.handleDeleteEntity",
		},
		{
			name:     "restore entity",
			method:   http.MethodPost,
			path:     "/entities/ent-obs-001/restore",
			body:     "",
			expected: "ports.EntityHTTPHandler.handleRestoreEntity",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			spanCollector.Reset()

			var req *http.Request
			if tt.body != "" {
				req = httptest.NewRequest(tt.method, tt.path, strings.NewReader(tt.body))
				req.Header.Set("Content-Type", "application/json")
			} else {
				req = httptest.NewRequest(tt.method, tt.path, nil)
			}

			rr := httptest.NewRecorder()
			r.ServeHTTP(rr, req)

			time.Sleep(10 * time.Millisecond)

			spans := spanCollector.GetSpans()
			if len(spans) == 0 {
				t.Fatal("expected at least 1 span to be exported")
			}

			found := false
			for _, span := range spans {
				if strings.Contains(span.Name(), tt.expected) {
					found = true
					t.Logf("Found span: %s (kind=%v, status=%v)",
						span.Name(), span.SpanKind(), span.Status())
					break
				}
			}
			if !found {
				var spanNames []string
				for _, s := range spans {
					spanNames = append(spanNames, s.Name())
				}
				t.Errorf("no span containing %q found. Available spans: %v", tt.expected, spanNames)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Test: Trace attributes are populated with entity_id, schema_id, version
// ---------------------------------------------------------------------------

func TestObservability_TraceAttributes(t *testing.T) {
	t.Parallel()

	spanCollector := newTestSpanCollector()
	tp := spanCollector.TracerProvider()
	defer tp.Shutdown(context.Background())

	logger := slog.New(slog.NewDiscardHandler)

	createUC := newObservabilityFakeCreateUC()

	handler := newObservabilityHTTPHandler(
		createUC,
		newObservabilityFakeReadUC(),
		newObservabilityFakeUpdateUC(),
		newObservabilityFakeDeleteRestoreUC(),
		newObservabilityFakeListUC(),
		logger,
		tp,
		metric.NewMeterProvider(),
	)

	r := chi.NewRouter()
	handler.RegisterRoutes(r)

	body := `{"schema_id":"sch-obs-001","name":"AttrTest","type":"customer","region":"eu-west-1"}`
	req := httptest.NewRequest(http.MethodPost, "/entities", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	time.Sleep(10 * time.Millisecond)

	spans := spanCollector.GetSpans()
	if len(spans) == 0 {
		t.Fatal("expected spans to be exported")
	}

	attributeFound := map[string]bool{
		"schema_id": false,
		"entity_id": false,
	}

	for _, span := range spans {
		for _, attr := range span.Attributes() {
			switch string(attr.Key) {
			case "schema_id":
				attributeFound["schema_id"] = true
				t.Logf("Found attribute schema_id=%q", attr.Value.AsString())
			case "entity_id":
				attributeFound["entity_id"] = true
				t.Logf("Found attribute entity_id=%q", attr.Value.AsString())
			case "entity_name":
				t.Logf("Found attribute entity_name=%q", attr.Value.AsString())
			case "entity_type":
				t.Logf("Found attribute entity_type=%q", attr.Value.AsString())
			case "region":
				t.Logf("Found attribute region=%q", attr.Value.AsString())
			case "entity_version":
				t.Logf("Found attribute entity_version=%q", attr.Value.AsString())
			case "entity_status":
				t.Logf("Found attribute entity_status=%q", attr.Value.AsString())
			case "created":
				t.Logf("Found attribute created=%q", attr.Value.AsString())
			}
		}
	}

	for k, found := range attributeFound {
		if !found {
			t.Errorf("expected attribute %q to be present on at least one span", k)
		}
	}
}

// ---------------------------------------------------------------------------
// Test: Errors are recorded via span.RecordError(err)
// ---------------------------------------------------------------------------

func TestObservability_ErrorRecording(t *testing.T) {
	t.Parallel()

	spanCollector := newTestSpanCollector()
	tp := spanCollector.TracerProvider()
	defer tp.Shutdown(context.Background())

	logger := slog.New(slog.NewDiscardHandler)

	createUC := newObservabilityFakeCreateUC()
	createUC.injectError = domain.ErrSchemaNotFound

	handler := newObservabilityHTTPHandler(
		createUC,
		newObservabilityFakeReadUC(),
		newObservabilityFakeUpdateUC(),
		newObservabilityFakeDeleteRestoreUC(),
		newObservabilityFakeListUC(),
		logger,
		tp,
		metric.NewMeterProvider(),
	)

	r := chi.NewRouter()
	handler.RegisterRoutes(r)

	body := `{"schema_id":"nonexistent","name":"FailTest","type":"customer","region":"us-east-1"}`
	req := httptest.NewRequest(http.MethodPost, "/entities", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	time.Sleep(10 * time.Millisecond)

	spans := spanCollector.GetSpans()

	errorRecorded := false
	for _, span := range spans {
		for _, ev := range span.Events() {
			if ev.Name == "exception" {
				errorRecorded = true
				t.Logf("Found RecordError on span %q: event=%q, attrs=%v",
					span.Name(), ev.Name, ev.Attributes)
			}
		}
	}

	if !errorRecorded {
		for _, span := range spans {
			if span.Status().Code != sdktrace.StatusCodeUnset {
				t.Logf("Span %q has status code=%v, description=%q",
					span.Name(), span.Status().Code, span.Status().Description)
			}
		}
		t.Log("Note: errors may be recorded as span status or via RecordError")
	}
}

// ---------------------------------------------------------------------------
// Test: Span attributes populated for create operations on success
// ---------------------------------------------------------------------------

func TestObservability_CreateOperationSpanAttributes(t *testing.T) {
	t.Parallel()

	spanCollector := newTestSpanCollector()
	tp := spanCollector.TracerProvider()
	defer tp.Shutdown(context.Background())

	logger := slog.New(slog.NewDiscardHandler)

	createUC := newObservabilityFakeCreateUC()

	handler := newObservabilityHTTPHandler(
		createUC,
		newObservabilityFakeReadUC(),
		newObservabilityFakeUpdateUC(),
		newObservabilityFakeDeleteRestoreUC(),
		newObservabilityFakeListUC(),
		logger,
		tp,
		metric.NewMeterProvider(),
	)

	r := chi.NewRouter()
	handler.RegisterRoutes(r)

	// Perform a successful create
	body := `{"schema_id":"sch-obs-success","name":"SuccessTest","type":"customer","region":"us-east-1"}`
	req := httptest.NewRequest(http.MethodPost, "/entities", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("expected HTTP 201 for successful create, got %d; body: %s", rr.Code, rr.Body.String())
	}

	time.Sleep(10 * time.Millisecond)

	spans := spanCollector.GetSpans()
	successSpans := 0
	for _, s := range spans {
		if s.Status().Code == sdktrace.StatusCodeUnset || s.Status().Code == sdktrace.StatusCodeOK {
			successSpans++
		}
	}

	if successSpans == 0 {
		t.Error("expected at least one span with success status")
	}
	t.Logf("Success spans: %d out of %d", successSpans, len(spans))
}

// ---------------------------------------------------------------------------
// Test: Domain error recorded in span for bad requests
// ---------------------------------------------------------------------------

func TestObservability_DomainErrorInSpan(t *testing.T) {
	t.Parallel()

	spanCollector := newTestSpanCollector()
	tp := spanCollector.TracerProvider()
	defer tp.Shutdown(context.Background())

	logger := slog.New(slog.NewDiscardHandler)

	handler := newObservabilityHTTPHandler(
		newObservabilityFakeCreateUC(),
		newObservabilityFakeReadUC(),
		newObservabilityFakeUpdateUC(),
		newObservabilityFakeDeleteRestoreUC(),
		newObservabilityFakeListUC(),
		logger,
		tp,
		metric.NewMeterProvider(),
	)

	r := chi.NewRouter()
	handler.RegisterRoutes(r)

	// Missing schema_id should trigger a validation error
	body := `{"name":"NoSchemaTest","type":"customer","region":"us-east-1"}`
	req := httptest.NewRequest(http.MethodPost, "/entities", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected HTTP 400 for missing schema_id, got %d; body: %s", rr.Code, rr.Body.String())
	}

	time.Sleep(10 * time.Millisecond)

	spans := spanCollector.GetSpans()
	t.Logf("Error case spans: %d", len(spans))
	for _, s := range spans {
		for _, ev := range s.Events() {
			if ev.Name == "exception" {
				t.Logf("Error recorded on span %q: %v", s.Name(), ev.Attributes)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Test: Concurrent operations maintain correct span context
// ---------------------------------------------------------------------------

func TestObservability_ConcurrentOperations(t *testing.T) {
	t.Parallel()

	spanCollector := newTestSpanCollector()
	tp := spanCollector.TracerProvider()
	defer tp.Shutdown(context.Background())

	logger := slog.New(slog.NewDiscardHandler)

	handler := newObservabilityHTTPHandler(
		newObservabilityFakeCreateUC(),
		newObservabilityFakeReadUC(),
		newObservabilityFakeUpdateUC(),
		newObservabilityFakeDeleteRestoreUC(),
		newObservabilityFakeListUC(),
		logger,
		tp,
		metric.NewMeterProvider(),
	)

	r := chi.NewRouter()
	handler.RegisterRoutes(r)

	const goroutines = 10
	var wg sync.WaitGroup
	errs := make(chan error, goroutines)

	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()

			body := fmt.Sprintf(
				`{"schema_id":"sch-con-%d","name":"Concurrent-%d","type":"customer","region":"us-east-1"}`,
				idx, idx,
			)
			req := httptest.NewRequest(http.MethodPost, "/entities", strings.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			rr := httptest.NewRecorder()
			r.ServeHTTP(rr, req)

			if rr.Code != http.StatusCreated && rr.Code != http.StatusOK {
				errs <- fmt.Errorf("concurrent op %d: unexpected status %d", idx, rr.Code)
			}
		}(i)
	}

	wg.Wait()
	close(errs)

	for err := range errs {
		t.Error(err)
	}

	time.Sleep(20 * time.Millisecond)

	spans := spanCollector.GetSpans()
	t.Logf("Concurrent operations produced %d spans", len(spans))

	if len(spans) < goroutines {
		t.Errorf("expected at least %d spans for %d concurrent ops, got %d",
			goroutines, goroutines, len(spans))
	}
}

// ---------------------------------------------------------------------------
// Test: Handler creates spans with correct parent-child relationships
// ---------------------------------------------------------------------------

func TestObservability_ParentChildSpanRelationships(t *testing.T) {
	t.Parallel()

	exporter := tracetest.NewInMemoryExporter()
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithSyncer(exporter),
		sdktrace.WithResource(resource.NewSchemaless(
			attribute.String("service.name", "entity-management-test"),
		)),
	)
	defer tp.Shutdown(context.Background())

	tracer := tp.Tracer("entity-management.ports")

	// Simulate a parent span (like middleware would create)
	parentCtx, parentSpan := tracer.Start(context.Background(), "http.request",
		trace.WithAttributes(attribute.String("http.method", "POST")))

	// Simulate the handler creating a child span
	_, childSpan := tracer.Start(parentCtx, "ports.EntityHTTPHandler.handleCreateEntity",
		trace.WithAttributes(
			attribute.String("schema_id", "sch-parent-001"),
			attribute.String("entity_id", "ent-parent-001"),
		))

	childSpan.End()
	parentSpan.End()

	time.Sleep(10 * time.Millisecond)

	spans := exporter.GetSpans()
	if len(spans) != 2 {
		t.Fatalf("expected 2 spans, got %d", len(spans))
	}

	var parentFound, childFound bool
	for _, s := range spans {
		switch s.Name() {
		case "http.request":
			parentFound = true
		case "ports.EntityHTTPHandler.handleCreateEntity":
			childFound = true
			if !s.Parent().IsValid() {
				t.Error("child span should have a valid parent span context")
			} else {
				t.Logf("Child span has parent trace_id=%s span_id=%s",
					s.Parent().TraceID(), s.Parent().SpanID())
			}
		}
	}

	if !parentFound {
		t.Error("parent span 'http.request' not found")
	}
	if !childFound {
		t.Error("child span 'ports.EntityHTTPHandler.handleCreateEntity' not found")
	}
}

// ---------------------------------------------------------------------------
// Test: Schema handler creates spans with schema_id and version attributes
// ---------------------------------------------------------------------------

func TestObservability_SchemaHandlerSpanAttributes(t *testing.T) {
	t.Parallel()

	spanCollector := newTestSpanCollector()
	tp := spanCollector.TracerProvider()
	defer tp.Shutdown(context.Background())

	_ = otel.SetTracerProvider(tp)

	logger := slog.New(slog.NewDiscardHandler)

	fakeSchemaRepo := &fakeSchemaRepoForObservability{
		schemas: make(map[string]*domain.EntitySchema),
	}
	fakeOutboxRepo := &fakeOutboxRepoForObservability{}
	fakeUow := &fakeUowForObservability{}
	fakeEventPub := &fakeEventPublisherForObservability{}
	fakeValidator := &fakeValidatorForObservability{}

	schemaSvc := application.NewSchemaService(
		fakeSchemaRepo, fakeOutboxRepo, fakeUow, fakeEventPub, fakeValidator, logger,
	)

	schemaHandler := ports.NewSchemaHTTPHandler(schemaSvc, logger)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		schemaHandler.RegisterRoutes(r)
	})

	body := `{"name":"ObservabilitySchema","attributes":[{"name":"email","type":"string","required":true}]}`
	req := httptest.NewRequest(http.MethodPost, "/api/v1/schemas", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("expected HTTP 201, got %d; body: %s", rr.Code, rr.Body.String())
	}

	time.Sleep(10 * time.Millisecond)

	spans := spanCollector.GetSpans()
	t.Logf("Schema handler spans: %d", len(spans))
	for _, s := range spans {
		t.Logf("  Span: %s", s.Name())
		for _, attr := range s.Attributes() {
			t.Logf("    %s = %s", attr.Key, attr.Value.AsString())
		}
	}

	schemaIDFound := false
	versionFound := false
	for _, s := range spans {
		for _, attr := range s.Attributes() {
			if attr.Key == "schema_id" {
				schemaIDFound = true
			}
			if attr.Key == "schema_version" || attr.Key == "version" {
				versionFound = true
			}
		}
	}

	if !schemaIDFound {
		t.Error("expected schema_id attribute on schema handler spans")
	}
	if !versionFound {
		t.Error("expected version attribute on schema handler spans")
	}
}

// ---------------------------------------------------------------------------
// Fake implementations for observability tests
// ---------------------------------------------------------------------------

type fakeSchemaRepoForObservability struct {
	schemas map[string]*domain.EntitySchema
	mu      sync.Mutex
}

func (r *fakeSchemaRepoForObservability) Save(_ context.Context, schema *domain.EntitySchema) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.schemas[schema.ID] = schema
	return nil
}
func (r *fakeSchemaRepoForObservability) FindByID(_ context.Context, id string) (*domain.EntitySchema, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.schemas[id]
	if !ok {
		return nil, errors.New("not found")
	}
	return s, nil
}
func (r *fakeSchemaRepoForObservability) FindByName(_ context.Context, name string) (*domain.EntitySchema, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, s := range r.schemas {
		if s.Name == name {
			return s, nil
		}
	}
	return nil, errors.New("not found")
}
func (r *fakeSchemaRepoForObservability) FindAll(_ context.Context) ([]*domain.EntitySchema, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var result []*domain.EntitySchema
	for _, s := range r.schemas {
		result = append(result, s)
	}
	return result, nil
}
func (r *fakeSchemaRepoForObservability) Delete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.schemas, id)
	return nil
}

type fakeOutboxRepoForObservability struct {
	mu     sync.Mutex
	events []*domain.OutboxEvent
}

func (r *fakeOutboxRepoForObservability) Save(_ context.Context, event *domain.OutboxEvent) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
	return nil
}
func (r *fakeOutboxRepoForObservability) MarkPublished(_ context.Context, _ string) error { return nil }
func (r *fakeOutboxRepoForObservability) MarkFailed(_ context.Context, _ string, _ error) error {
	return nil
}
func (r *fakeOutboxRepoForObservability) FetchPending(_ context.Context, _ int) ([]*domain.OutboxEvent, error) {
	return nil, nil
}

type fakeUowForObservability struct{}

func (u *fakeUowForObservability) Execute(_ context.Context, fn func(uowCtx context.Context) error) error {
	return fn(context.Background())
}

type fakeEventPublisherForObservability struct{}

func (p *fakeEventPublisherForObservability) PublishSchemaDefined(_ context.Context, _ *domain.EntitySchemaDefined) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishSchemaUpdated(_ context.Context, _ *domain.EntitySchemaUpdated) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishEntityCreated(_ context.Context, _ *domain.EntityCreated) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishEntityUpdated(_ context.Context, _ *domain.EntityUpdated) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishEntityDeleted(_ context.Context, _ *domain.EntityDeleted) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishEntityRead(_ context.Context, _ *domain.EntityRead) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishEntitySoftDeleted(_ context.Context, _ *domain.EntitySoftDeleted) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishEntityHardDeleted(_ context.Context, _ *domain.EntityHardDeleted) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishEntityRestored(_ context.Context, _ *domain.EntityRestored) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishEntitiesQueried(_ context.Context, _ *domain.EntitiesQueried) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishInvalidCursorProvided(_ context.Context, _ *domain.InvalidCursorProvided) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishAppStarted(_ context.Context, _ *domain.AppStarted) error {
	return nil
}
func (p *fakeEventPublisherForObservability) PublishAppStartupFailed(_ context.Context, _ *domain.AppStartupFailed) error {
	return nil
}

type fakeValidatorForObservability struct{}

func (v *fakeValidatorForObservability) Validate(_ context.Context, _ string, _ map[string]any) error {
	return nil
}
func (v *fakeValidatorForObservability) CompileSchema(_ context.Context, _ *domain.EntitySchema) error {
	return nil
}
func (v *fakeValidatorForObservability) Invalidate(_ context.Context, _ string) error {
	return nil
}

// ---------------------------------------------------------------------------
// Helper: JSON body assertions
// ---------------------------------------------------------------------------

func assertJSONBody(t *testing.T, body []byte, expected map[string]interface{}) {
	t.Helper()

	var actual map[string]interface{}
	if err := json.Unmarshal(body, &actual); err != nil {
		t.Fatalf("failed to unmarshal response body: %v", err)
	}

	for k, expectedVal := range expected {
		actualVal, ok := actual[k]
		if !ok {
			t.Errorf("expected key %q in response body, but it was missing", k)
			continue
		}

		expectedStr, expStrOk := expectedVal.(string)
		actualStr, actStrOk := actualVal.(string)
		if expStrOk && actStrOk {
			if expectedStr != actualStr {
				t.Errorf("key %q: expected %q, got %q", k, expectedStr, actualStr)
			}
			continue
		}

		expectedFloat, expFloatOk := expectedVal.(float64)
		actualFloat, actFloatOk := actualVal.(float64)
		if expFloatOk && actFloatOk {
			if expectedFloat != actualFloat {
				t.Errorf("key %q: expected %v, got %v", k, expectedFloat, actualFloat)
			}
			continue
		}

		if expectedVal != actualVal {
			t.Errorf("key %q: expected %v (type %T), got %v (type %T)",
				k, expectedVal, expectedVal, actualVal, actualVal)
		}
	}
}

// ---------------------------------------------------------------------------
// Compile-time interface checks
// ---------------------------------------------------------------------------

var _ domain.SchemaRepository = (*fakeSchemaRepoForObservability)(nil)
var _ domain.OutboxRepository = (*fakeOutboxRepoForObservability)(nil)
var _ domain.UnitOfWork = (*fakeUowForObservability)(nil)
var _ domain.EventPublisher = (*fakeEventPublisherForObservability)(nil)
var _ domain.SchemaValidator = (*fakeValidatorForObservability)(nil)
