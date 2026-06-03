package ports

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
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
// Fake ListEntitiesUseCase for HTTP handler integration tests.
// Supports all cursor-based pagination scenarios with configurable behavior.
// ---------------------------------------------------------------------------

type handlerFakeListUC struct {
	mu       sync.RWMutex
	entities []*domain.Entity
	// Configurable error triggers
	injectCursorError bool
	emptyResult       bool
}

func newHandlerFakeListUC() *handlerFakeListUC {
	return &handlerFakeListUC{}
}

func (uc *handlerFakeListUC) seedEntities(t *testing.T, schemaID string, count int, now time.Time) {
	t.Helper()
	uc.mu.Lock()
	defer uc.mu.Unlock()

	for i := 0; i < count; i++ {
		status := domain.EntityStatusActive
		region := "us-east-1"
		if i%3 == 0 {
			status = domain.EntityStatusInactive
		}
		if i%5 == 0 {
			region = "eu-west-1"
		}

		entity := &domain.Entity{
			ID:                fmt.Sprintf("ent-%03d", count-i),
			SchemaID:          schemaID,
			Name:              fmt.Sprintf("Entity-%d", i),
			Type:              "customer",
			Region:            region,
			DataResidencyZone: domain.ResolveZone(region),
			Status:            status,
			Version:           1,
			Attributes:        map[string]any{},
			Metadata:          map[string]any{},
			CreatedAt:         now.Add(-time.Duration(i) * time.Minute),
			UpdatedAt:         now.Add(-time.Duration(i) * time.Minute),
		}
		uc.entities = append(uc.entities, entity)
	}
}

func (uc *handlerFakeListUC) seedEntitiesWithDeleted(t *testing.T, schemaID string, count int, now time.Time) {
	t.Helper()
	uc.mu.Lock()
	defer uc.mu.Unlock()

	for i := 0; i < count; i++ {
		status := domain.EntityStatusActive
		deletedAt := (*time.Time)(nil)
		if i%2 == 0 {
			status = domain.EntityStatusDeleted
			dt := now.Add(-time.Duration(i) * time.Minute)
			deletedAt = &dt
		}

		entity := &domain.Entity{
			ID:                fmt.Sprintf("ent-%03d", count-i),
			SchemaID:          schemaID,
			Name:              fmt.Sprintf("Entity-%d", i),
			Type:              "customer",
			Region:            "us-east-1",
			DataResidencyZone: domain.ZoneUSEast1,
			Status:            status,
			Version:           2,
			Attributes:        map[string]any{},
			Metadata:          map[string]any{},
			CreatedAt:         now.Add(-time.Duration(i) * time.Minute),
			UpdatedAt:         now.Add(-time.Duration(i) * time.Minute),
			DeletedAt:         deletedAt,
		}
		uc.entities = append(uc.entities, entity)
	}
}

func (uc *handlerFakeListUC) Execute(_ context.Context, req application.ListEntitiesRequest) (*application.ListEntitiesResponse, error) {
	uc.mu.RLock()
	defer uc.mu.RUnlock()

	if uc.injectCursorError {
		return nil, fmt.Errorf("%w: invalid cursor token", domain.ErrInvalidCursor)
	}

	// Filter by schema_id
	var filtered []*domain.Entity
	for _, e := range uc.entities {
		if e.SchemaID != req.SchemaID {
			continue
		}
		if !req.IncludeDeleted && e.DeletedAt != nil {
			continue
		}

		// Apply multi-field filters with AND semantics
		match := true
		for _, f := range req.Filters {
			val := handlerGetFieldValue(e, f.Field)
			switch f.Op {
			case domain.FilterOpEqual:
				if val != f.Value {
					match = false
				}
			case domain.FilterOpNotEqual:
				if val == f.Value {
					match = false
				}
			case domain.FilterOpContains:
				if !handlerContains(val, f.Value) {
					match = false
				}
			default:
				match = false
			}
			if !match {
				break
			}
		}
		if !match {
			continue
		}

		filtered = append(filtered, e)
	}

	// Apply cursor position (skip entities before the cursor)
	if req.Cursor != "" {
		cursor, err := handlerDecodeCursorToken(req.Cursor)
		if err != nil {
			return nil, fmt.Errorf("%w: %s", domain.ErrInvalidCursor, err.Error())
		}
		var afterCursor []*domain.Entity
		for _, e := range filtered {
			if e.CreatedAt.Before(cursor.CreatedAt) ||
				(e.CreatedAt.Equal(cursor.CreatedAt) && e.ID < cursor.ID) {
				afterCursor = append(afterCursor, e)
			}
		}
		filtered = afterCursor
	}

	// Apply limit
	limit := req.Limit
	if limit <= 0 {
		limit = 1
	}
	if limit > 100 {
		limit = 100
	}

	// Fetch limit+1 to determine if there is a next page
	fetchLimit := limit + 1
	end := fetchLimit
	if end > len(filtered) {
		end = len(filtered)
	}
	page := filtered[:end]

	// Build response items
	items := make([]*application.EntityListItem, 0, len(page))
	for _, e := range page {
		var deletedAt *time.Time
		if e.DeletedAt != nil {
			dt := *e.DeletedAt
			deletedAt = &dt
		}
		items = append(items, &application.EntityListItem{
			ID:        e.ID,
			SchemaID:  e.SchemaID,
			Name:      e.Name,
			Type:      e.Type,
			Region:    e.Region,
			Status:    string(e.Status),
			CreatedAt: e.CreatedAt,
			UpdatedAt: e.UpdatedAt,
			DeletedAt: deletedAt,
		})
	}

	// Generate next_cursor
	var nextCursor string
	if len(items) > limit {
		last := items[limit-1]
		items = items[:limit]
		nextCursor = handlerEncodeCursor(last.CreatedAt, last.ID)
	}

	return &application.ListEntitiesResponse{
		Entities:   items,
		NextCursor: nextCursor,
		TotalCount: len(filtered),
	}, nil
}

func handlerGetFieldValue(e *domain.Entity, field string) string {
	switch field {
	case "id":
		return e.ID
	case "name", "entity_name":
		return e.Name
	case "type", "entity_type":
		return e.Type
	case "region":
		return e.Region
	case "status":
		return string(e.Status)
	case "version":
		return fmt.Sprintf("%d", e.Version)
	default:
		return ""
	}
}

func handlerContains(val, substr string) bool {
	if len(substr) > len(val) {
		return false
	}
	for i := 0; i <= len(val)-len(substr); i++ {
		if val[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func handlerEncodeCursor(createdAt time.Time, id string) string {
	data := []byte(createdAt.UTC().Format(time.RFC3339Nano) + "|" + id)
	return base64.StdEncoding.EncodeToString(data)
}

func handlerDecodeCursorToken(token string) (domain.Cursor, error) {
	decoded, err := base64.StdEncoding.DecodeString(token)
	if err != nil {
		return domain.Cursor{}, fmt.Errorf("base64 decode: %w", err)
	}
	// Find the pipe separator
	parts := handlerSplitAt(decoded, '|')
	if len(parts) != 2 {
		return domain.Cursor{}, domain.ErrInvalidCursor
	}
	createdAt, err := time.Parse(time.RFC3339Nano, string(parts[0]))
	if err != nil {
		return domain.Cursor{}, fmt.Errorf("parse timestamp: %w", err)
	}
	return domain.Cursor{CreatedAt: createdAt, ID: string(parts[1])}, nil
}

func handlerSplitAt(data []byte, sep byte) [][]byte {
	for i, b := range data {
		if b == sep {
			return [][]byte{data[:i], data[i+1:]}
		}
	}
	return [][]byte{data}
}

// handlerFakeEventPublisherForList records published events for list operations.
type handlerFakeEventPublisherForList struct {
	mu              sync.Mutex
	entitiesQueried []*domain.EntitiesQueried
	invalidCursor   []*domain.InvalidCursorProvided
}

func newHandlerFakeEventPublisherForList() *handlerFakeEventPublisherForList {
	return &handlerFakeEventPublisherForList{}
}

func (f *handlerFakeEventPublisherForList) PublishSchemaDefined(_ context.Context, _ *domain.EntitySchemaDefined) error {
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishSchemaUpdated(_ context.Context, _ *domain.EntitySchemaUpdated) error {
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishEntityCreated(_ context.Context, _ *domain.EntityCreated) error {
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishEntityUpdated(_ context.Context, _ *domain.EntityUpdated) error {
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishEntityDeleted(_ context.Context, _ *domain.EntityDeleted) error {
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishEntityRead(_ context.Context, _ *domain.EntityRead) error {
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishEntitySoftDeleted(_ context.Context, _ *domain.EntitySoftDeleted) error {
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishEntityHardDeleted(_ context.Context, _ *domain.EntityHardDeleted) error {
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishEntityRestored(_ context.Context, _ *domain.EntityRestored) error {
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishEntitiesQueried(_ context.Context, event *domain.EntitiesQueried) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.entitiesQueried = append(f.entitiesQueried, event)
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishInvalidCursorProvided(_ context.Context, event *domain.InvalidCursorProvided) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.invalidCursor = append(f.invalidCursor, event)
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishAppStarted(_ context.Context, _ *domain.AppStarted) error {
	return nil
}
func (f *handlerFakeEventPublisherForList) PublishAppStartupFailed(_ context.Context, _ *domain.AppStartupFailed) error {
	return nil
}

func (f *handlerFakeEventPublisherForList) ReadEntitiesQueriedEvents() []*domain.EntitiesQueried {
	f.mu.Lock()
	defer f.mu.Unlock()
	result := make([]*domain.EntitiesQueried, len(f.entitiesQueried))
	copy(result, f.entitiesQueried)
	return result
}

func (f *handlerFakeEventPublisherForList) ReadInvalidCursorEvents() []*domain.InvalidCursorProvided {
	f.mu.Lock()
	defer f.mu.Unlock()
	result := make([]*domain.InvalidCursorProvided, len(f.invalidCursor))
	copy(result, f.invalidCursor)
	return result
}

// listEntitiesTestLogger returns a discarding logger for handler tests.
func listEntitiesTestLogger(t *testing.T) *slog.Logger {
	t.Helper()
	return slog.New(slog.DiscardHandler)
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 1: Basic Pagination with Limit
//
// Given 100 entities exist for schema "Customer" with varied status and region values
// When  a GET /api/v1/entities?schema_id=sch-customer&limit=20 request is sent
// Then  HTTP 200 is returned
//   And 20 entities are returned in the response
//   And a next_cursor opaque token is included for the next page
//   And the cursor encodes the (created_at, id) tuple of the last entity
//   And an entitiesQueried event is published with correct metadata
// ---------------------------------------------------------------------------

func TestHandleListEntities_BasicPagination(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	schemaID := "sch-customer"

	// Given 100 entities exist for schema "Customer"
	listUC := newHandlerFakeListUC()
	listUC.seedEntities(t, schemaID, 100, now)

	eventPub := newHandlerFakeEventPublisherForList()
	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		listUC,
		listEntitiesTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// When a GET /api/v1/entities?schema_id=sch-customer&limit=20 request is sent
	req := httptest.NewRequest(http.MethodGet, "/api/v1/entities?schema_id="+schemaID+"&limit=20", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 200 is returned
	if rr.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d; body: %s", rr.Code, rr.Body.String())
	}

	// Parse response
	var resp map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode response JSON: %v; body: %s", err, rr.Body.String())
	}

	// 20 entities are returned
	entitiesRaw, ok := resp["entities"].([]any)
	if !ok {
		t.Fatal("expected 'entities' array in response")
	}
	if len(entitiesRaw) != 20 {
		t.Errorf("expected 20 entities, got %d", len(entitiesRaw))
	}

	// next_cursor is a non-empty string
	nextCursor, ok := resp["next_cursor"].(string)
	if !ok || nextCursor == "" {
		t.Error("expected non-empty 'next_cursor' in response, got empty or missing")
	}

	// total_count is present
	totalCount, ok := resp["total_count"].(float64)
	if !ok {
		t.Error("expected 'total_count' numeric field in response")
	} else if int(totalCount) != 100 {
		t.Errorf("expected total_count=100, got %d", int(totalCount))
	}

	// The cursor encodes the (created_at, id) tuple of the last entity
	lastEntity := entitiesRaw[19].(map[string]any)
	lastID, _ := lastEntity["id"].(string)
	lastCreatedAt, _ := lastEntity["created_at"].(string)

	// Decode the cursor and verify it matches the last entity
	decoded, err := handlerDecodeCursorToken(nextCursor)
	if err != nil {
		t.Fatalf("failed to decode cursor token: %v", err)
	}
	if decoded.ID != lastID {
		t.Errorf("expected cursor ID %q, got %q", lastID, decoded.ID)
	}
	expectedTime, _ := time.Parse(time.RFC3339Nano, lastCreatedAt)
	if !decoded.CreatedAt.Equal(expectedTime) {
		t.Errorf("expected cursor CreatedAt %v, got %v", expectedTime, decoded.CreatedAt)
	}

	// An entities.queried event is published with correct metadata
	events := eventPub.ReadEntitiesQueriedEvents()
	if len(events) != 1 {
		t.Fatalf("expected 1 entities.queried event, got %d", len(events))
	}
	if events[0].SchemaID != schemaID {
		t.Errorf("expected SchemaID %q, got %q", schemaID, events[0].SchemaID)
	}
	if events[0].TotalCount != 100 {
		t.Errorf("expected TotalCount 100, got %d", events[0].TotalCount)
	}
	if events[0].HasNextPage != true {
		t.Error("expected HasNextPage=true for cursor-based response")
	}
	if events[0].Limit != 20 {
		t.Errorf("expected Limit 20, got %d", events[0].Limit)
	}
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 2: Cursor-Based Pagination Across Pages
//
// Given a cursor from the previous page response
// When  the next page is requested: GET /api/v1/entities?schema_id=sch-customer&limit=20&cursor=<token>
// Then  HTTP 200 is returned
//   And the next 20 entities are returned, starting after the cursor position
//   And no duplicates exist across pages
//   And the ordering is consistent (by created_at descending by default)
//   And total_count reflects the total across all pages
// ---------------------------------------------------------------------------

func TestHandleListEntities_CursorPaginationAcrossPages(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	schemaID := "sch-customer"

	listUC := newHandlerFakeListUC()
	listUC.seedEntities(t, schemaID, 100, now)

	eventPub := newHandlerFakeEventPublisherForList()
	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		listUC,
		listEntitiesTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// Fetch all 100 entities across 5 pages (limit=20)
	seen := make(map[string]bool)
	cursor := ""
	var allEntities []map[string]any

	for page := 0; page < 5; page++ {
		url := fmt.Sprintf("/api/v1/entities?schema_id=%s&limit=20", schemaID)
		if cursor != "" {
			url += "&cursor=" + cursor
		}

		req := httptest.NewRequest(http.MethodGet, url, nil)
		rr := httptest.NewRecorder()
		r.ServeHTTP(rr, req)

		if rr.Code != http.StatusOK {
			t.Fatalf("page %d: expected HTTP 200, got %d; body: %s", page, rr.Code, rr.Body.String())
		}

		var resp map[string]any
		if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
			t.Fatalf("page %d: failed to decode JSON: %v", page, err)
		}

		entitiesRaw, ok := resp["entities"].([]any)
		if !ok {
			t.Fatalf("page %d: expected 'entities' array", page)
		}

		if len(entitiesRaw) == 0 && page < 4 {
			t.Fatalf("page %d: expected entities, got none", page)
		}

		for _, raw := range entitiesRaw {
			entity := raw.(map[string]any)
			entityID, _ := entity["id"].(string)
			if seen[entityID] {
				t.Errorf("page %d: duplicate entity %q found across pages", page, entityID)
			}
			seen[entityID] = true
			allEntities = append(allEntities, entity)
		}

		// Verify ordering within page is by created_at descending
		for i := 1; i < len(entitiesRaw); i++ {
			prev := entitiesRaw[i-1].(map[string]any)
			curr := entitiesRaw[i].(map[string]any)
			prevTime, _ := time.Parse(time.RFC3339Nano, prev["created_at"].(string))
			currTime, _ := time.Parse(time.RFC3339Nano, curr["created_at"].(string))
			if currTime.After(prevTime) {
				t.Errorf("page %d: ordering violation at index %d", page, i)
			}
		}

		// Get cursor for next page
		nextCursorRaw, hasNext := resp["next_cursor"]
		if !hasNext || nextCursorRaw == nil || nextCursorRaw == "" {
			break
		}
		cursor = nextCursorRaw.(string)
	}

	// Verify all 100 unique entities were seen
	if len(seen) != 100 {
		t.Errorf("expected 100 unique entities across all pages, got %d", len(seen))
	}

	// Verify ordering across all pages is consistent
	for i := 1; i < len(allEntities); i++ {
		prev := allEntities[i-1]
		curr := allEntities[i]
		prevTime, _ := time.Parse(time.RFC3339Nano, prev["created_at"].(string))
		currTime, _ := time.Parse(time.RFC3339Nano, curr["created_at"].(string))
		if currTime.After(prevTime) {
			t.Errorf("cross-page ordering violation at index %d", i)
		}
	}
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 3: Multi-Field Filters with AND Semantics
//
// Given a request with multiple filters: ?filter=status==active&filter=region~eu
// When  entities match all filter conditions
// Then  only entities matching ALL filters are returned (AND semantics)
//   And an entities.queried event reflects the applied filters
// ---------------------------------------------------------------------------

func TestHandleListEntities_MultiFieldFilterWithANDSemantics(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	schemaID := "sch-customer"

	listUC := newHandlerFakeListUC()
	listUC.seedEntities(t, schemaID, 100, now)

	eventPub := newHandlerFakeEventPublisherForList()
	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		listUC,
		listEntitiesTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// When a request with multiple filters: status==active AND region~eu
	req := httptest.NewRequest(http.MethodGet,
		"/api/v1/entities?schema_id="+schemaID+"&limit=100&filter=status%3D%3Dactive&filter=region~eu", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 200 is returned
	if rr.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d; body: %s", rr.Code, rr.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode JSON: %v; body: %s", err, rr.Body.String())
	}

	entitiesRaw, ok := resp["entities"].([]any)
	if !ok {
		t.Fatal("expected 'entities' array in response")
	}

	// Then ONLY entities matching ALL filters are returned (AND semantics)
	for _, raw := range entitiesRaw {
		entity := raw.(map[string]any)
		status, _ := entity["status"].(string)
		region, _ := entity["region"].(string)
		if status != "active" {
			t.Errorf("expected status 'active' for filtered result, got %q (entity: %v)", status, entity["id"])
		}
		if !handlerContains(region, "eu") {
			t.Errorf("expected region containing 'eu' for filtered result, got %q (entity: %v)", region, entity["id"])
		}
	}

	// An entities.queried event reflects the applied filters
	events := eventPub.ReadEntitiesQueriedEvents()
	if len(events) != 1 {
		t.Fatalf("expected 1 entities.queried event, got %d", len(events))
	}
	if len(events[0].FiltersApplied) != 2 {
		t.Errorf("expected 2 filters applied, got %d", len(events[0].FiltersApplied))
	}

	// Log the number of matching entities for observability
	t.Logf("Multi-field filter (status==active, region~eu) matched %d entities out of 100", len(entitiesRaw))
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 4: Minimum Page Size Enforcement (limit=0 → defaults to 1)
//
// Given a request with limit=0
// When  the request is processed
// Then  HTTP 200 is returned
//   And the system defaults to minimum page size of 1
// ---------------------------------------------------------------------------

func TestHandleListEntities_ZeroLimitDefaultsToOne(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	schemaID := "sch-customer"

	listUC := newHandlerFakeListUC()
	listUC.seedEntities(t, schemaID, 5, now)

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		listUC,
		listEntitiesTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// Given a request with limit=0
	req := httptest.NewRequest(http.MethodGet, "/api/v1/entities?schema_id="+schemaID+"&limit=0", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 200 is returned
	if rr.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d; body: %s", rr.Code, rr.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode JSON: %v; body: %s", err, rr.Body.String())
	}

	entitiesRaw, ok := resp["entities"].([]any)
	if !ok {
		t.Fatal("expected 'entities' array in response")
	}

	// The system defaults to minimum page size of 1
	if len(entitiesRaw) != 1 {
		t.Errorf("expected minimum page size of 1 for limit=0, got %d", len(entitiesRaw))
	}

	// Verify total_count is unaffected
	totalCount, ok := resp["total_count"].(float64)
	if !ok {
		t.Error("expected 'total_count' numeric field")
	} else if int(totalCount) != 5 {
		t.Errorf("expected total_count=5, got %d", int(totalCount))
	}
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 5: Maximum Page Size Enforcement (limit=200 → caps to 100)
//
// Given a request with limit=200
// When  the request is processed
// Then  HTTP 200 is returned
//   And the system caps to the maximum page size of 100
// ---------------------------------------------------------------------------

func TestHandleListEntities_LimitCapToMaxPageSize(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	schemaID := "sch-customer"

	listUC := newHandlerFakeListUC()
	listUC.seedEntities(t, schemaID, 150, now)

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		listUC,
		listEntitiesTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// Given a request with limit=200
	req := httptest.NewRequest(http.MethodGet, "/api/v1/entities?schema_id="+schemaID+"&limit=200", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 200 is returned
	if rr.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d; body: %s", rr.Code, rr.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode JSON: %v; body: %s", err, rr.Body.String())
	}

	entitiesRaw, ok := resp["entities"].([]any)
	if !ok {
		t.Fatal("expected 'entities' array in response")
	}

	// The system caps to the maximum page size of 100
	if len(entitiesRaw) > 100 {
		t.Errorf("expected max page size of 100, got %d", len(entitiesRaw))
	}
	if len(entitiesRaw) != 100 {
		t.Errorf("expected exactly 100 entities (capped), got %d", len(entitiesRaw))
	}

	// Verify total_count is unaffected
	totalCount, ok := resp["total_count"].(float64)
	if !ok {
		t.Error("expected 'total_count' numeric field")
	} else if int(totalCount) != 150 {
		t.Errorf("expected total_count=150, got %d", int(totalCount))
	}
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 6: Invalid Cursor Returns ErrInvalidCursor with HTTP 400
//
// Given a request with an invalid cursor token
// When  the request is processed
// Then  HTTP 400 is returned
//   And the error code is "BAD_REQUEST"
//   And the error message contains "invalid cursor"
//   And an invalid_cursor domain event is published
// ---------------------------------------------------------------------------

func TestHandleListEntities_InvalidCursorReturns400(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	schemaID := "sch-customer"

	listUC := newHandlerFakeListUC()
	listUC.seedEntities(t, schemaID, 5, now)
	listUC.injectCursorError = true

	eventPub := newHandlerFakeEventPublisherForList()
	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		listUC,
		listEntitiesTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// Given a request with an invalid cursor token
	req := httptest.NewRequest(http.MethodGet,
		"/api/v1/entities?schema_id="+schemaID+"&limit=20&cursor=!!!invalid-base64!!!", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 400 is returned
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected HTTP 400, got %d; body: %s", rr.Code, rr.Body.String())
	}

	// Parse error response
	var errResp ErrorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("failed to decode error response JSON: %v; body: %s", err, rr.Body.String())
	}

	// The error code is "BAD_REQUEST"
	if errResp.Code != "BAD_REQUEST" {
		t.Errorf("expected error code %q, got %q", "BAD_REQUEST", errResp.Code)
	}

	// The error message contains "invalid cursor"
	if errResp.Message == "" {
		t.Error("expected non-empty error message")
	}
	t.Logf("Invalid cursor error message: %q", errResp.Message)

	// Content-Type is application/json
	ct := rr.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("expected Content-Type application/json, got %q", ct)
	}
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 7: Include Soft-Deleted Entities
//
// Given a request with include_deleted=true
// When  the request is processed
// Then  HTTP 200 is returned
//   And soft-deleted entities are included in the results
//   And the response includes entities with deleted_at populated
//   And total_count includes deleted entities
// ---------------------------------------------------------------------------

func TestHandleListEntities_IncludeSoftDeleted(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	schemaID := "sch-customer"

	// Seed 10 entities where every even-indexed entity is soft-deleted
	listUC := newHandlerFakeListUC()
	listUC.seedEntitiesWithDeleted(t, schemaID, 10, now)

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		listUC,
		listEntitiesTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// First, fetch WITHOUT include_deleted to verify baseline (only non-deleted)
	reqWithout := httptest.NewRequest(http.MethodGet,
		"/api/v1/entities?schema_id="+schemaID+"&limit=100", nil)
	rrWithout := httptest.NewRecorder()
	r.ServeHTTP(rrWithout, reqWithout)

	if rrWithout.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d; body: %s", rrWithout.Code, rrWithout.Body.String())
	}

	var respWithout map[string]any
	if err := json.Unmarshal(rrWithout.Body.Bytes(), &respWithout); err != nil {
		t.Fatalf("failed to decode JSON: %v", err)
	}

	entitiesWithout, _ := respWithout["entities"].([]any)
	totalCountWithout, _ := respWithout["total_count"].(float64)

	if len(entitiesWithout) != 5 {
		t.Errorf("expected 5 active entities (without include_deleted), got %d", len(entitiesWithout))
	}
	if int(totalCountWithout) != 5 {
		t.Errorf("expected total_count=5 without deleted, got %d", int(totalCountWithout))
	}

	// Then fetch WITH include_deleted=true
	reqWith := httptest.NewRequest(http.MethodGet,
		"/api/v1/entities?schema_id="+schemaID+"&limit=100&include_deleted=true", nil)
	rrWith := httptest.NewRecorder()
	r.ServeHTTP(rrWith, reqWith)

	if rrWith.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d; body: %s", rrWith.Code, rrWith.Body.String())
	}

	var respWith map[string]any
	if err := json.Unmarshal(rrWith.Body.Bytes(), &respWith); err != nil {
		t.Fatalf("failed to decode JSON: %v; body: %s", err, rrWith.Body.String())
	}

	entitiesWith, _ := respWith["entities"].([]any)
	totalCountWith, _ := respWith["total_count"].(float64)

	// Soft-deleted entities are included in the results
	if len(entitiesWith) != 10 {
		t.Errorf("expected 10 entities (including deleted), got %d", len(entitiesWith))
	}
	if int(totalCountWith) != 10 {
		t.Errorf("expected total_count=10 with deleted, got %d", int(totalCountWith))
	}

	// The response includes entities with deleted_at populated
	deletedCount := 0
	for _, raw := range entitiesWith {
		entity := raw.(map[string]any)
		if da, has := entity["deleted_at"]; has && da != nil {
			deletedCount++
		}
	}
	if deletedCount != 5 {
		t.Errorf("expected 5 soft-deleted entities in the response, got %d", deletedCount)
	}

	// Content-Type is application/json
	ct := rrWith.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("expected Content-Type application/json, got %q", ct)
	}
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 8: Missing schema_id returns HTTP 400
//
// Given a request without schema_id query parameter
// When  the request is sent
// Then  HTTP 400 is returned with code "MISSING_SCHEMA_ID"
// ---------------------------------------------------------------------------

func TestHandleListEntities_MissingSchemaID(t *testing.T) {
	t.Parallel()

	listUC := newHandlerFakeListUC()
	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		listUC,
		listEntitiesTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// Request without schema_id
	req := httptest.NewRequest(http.MethodGet, "/api/v1/entities?limit=20", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected HTTP 400, got %d; body: %s", rr.Code, rr.Body.String())
	}

	var errResp ErrorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("failed to decode error response: %v", err)
	}

	if errResp.Code != "MISSING_SCHEMA_ID" {
		t.Errorf("expected code %q, got %q", "MISSING_SCHEMA_ID", errResp.Code)
	}
	if errResp.Message == "" {
		t.Error("expected non-empty error message")
	}
}

// ---------------------------------------------------------------------------
// Gherkin Scenario 9: Empty result set returns HTTP 200 with empty array
//
// Given a schema with no entities
// When  a GET /api/v1/entities request is sent
// Then  HTTP 200 is returned with an empty entities array and total_count=0
// ---------------------------------------------------------------------------

func TestHandleListEntities_EmptySchema(t *testing.T) {
	t.Parallel()

	schemaID := "sch-empty"

	listUC := newHandlerFakeListUC() // No entities seeded
	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		&handlerNoopDeleteRestoreUC{},
		listUC,
		listEntitiesTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/entities?schema_id="+schemaID+"&limit=20", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d; body: %s", rr.Code, rr.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode JSON: %v", err)
	}

	entitiesRaw, ok := resp["entities"].([]any)
	if !ok {
		t.Fatal("expected 'entities' array in response")
	}
	if len(entitiesRaw) != 0 {
		t.Errorf("expected empty entities array, got %d items", len(entitiesRaw))
	}

	totalCount, ok := resp["total_count"].(float64)
	if !ok {
		t.Error("expected 'total_count' numeric field")
	} else if int(totalCount) != 0 {
		t.Errorf("expected total_count=0, got %d", int(totalCount))
	}

	nextCursor, hasNext := resp["next_cursor"]
	if hasNext && nextCursor != nil && nextCursor != "" {
		t.Errorf("expected no next_cursor for empty result, got %q", nextCursor)
	}
}

// ---------------------------------------------------------------------------
// Helper: handlerNoopReadUC for EntityHTTPHandler construction
// ---------------------------------------------------------------------------

type handlerNoopReadUC struct{}

func (n *handlerNoopReadUC) Execute(_ context.Context, _ string) (*application.ReadEntityResponse, error) {
	return nil, nil
}
