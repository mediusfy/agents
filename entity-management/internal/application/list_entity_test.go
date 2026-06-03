package application

import (
	"context"
	"encoding/base64"
	"fmt"
	"log/slog"
	"sync"
	"testing"
	"time"

	"entity-management/internal/domain"
)

// fakePaginationRepo implements domain.EntityRepository with in-memory storage
// and supports the ListEntities method for cursor-based pagination testing.
type fakePaginationRepo struct {
	mu       sync.RWMutex
	entities []*domain.Entity
}

func newFakePaginationRepo() *fakePaginationRepo {
	return &fakePaginationRepo{}
}

func (r *fakePaginationRepo) Save(_ context.Context, entity *domain.Entity) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.entities = append(r.entities, entity)
	return nil
}

func (r *fakePaginationRepo) FindByID(_ context.Context, id string) (*domain.Entity, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, e := range r.entities {
		if e.ID == id {
			return e, nil
		}
	}
	return nil, domain.ErrEntityNotFound
}

func (r *fakePaginationRepo) Update(_ context.Context, _ string, _ domain.UpdateOperation) (*domain.Entity, error) {
	return nil, fmt.Errorf("not implemented")
}

func (r *fakePaginationRepo) UpdateStatus(_ context.Context, _ string, _ domain.EntityStatus) error {
	return fmt.Errorf("not implemented")
}

func (r *fakePaginationRepo) FindBySchemaID(_ context.Context, schemaID string) ([]*domain.Entity, error) {
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

func (r *fakePaginationRepo) List(_ context.Context, _ domain.EntityFilter) ([]*domain.Entity, error) {
	return nil, fmt.Errorf("not implemented")
}

func (r *fakePaginationRepo) SoftDelete(_ context.Context, _ string, _ time.Time) error {
	return fmt.Errorf("not implemented")
}

func (r *fakePaginationRepo) Restore(_ context.Context, _ string) error {
	return fmt.Errorf("not implemented")
}

func (r *fakePaginationRepo) HardDelete(_ context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i, e := range r.entities {
		if e.ID == id {
			r.entities = append(r.entities[:i], r.entities[i+1:]...)
			return nil
		}
	}
	return domain.ErrEntityNotFound
}

// ListEntities implements cursor-based pagination in-memory for testing.
// It mimics the behavior of the postgres adapter.
func (r *fakePaginationRepo) ListEntities(_ context.Context, params domain.ListEntitiesParams) (*domain.PaginatedResult, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	// Filter by schema_id.
	var filtered []*domain.Entity
	for _, e := range r.entities {
		if e.SchemaID != params.SchemaID {
			continue
		}
		if !params.IncludeDeleted && e.DeletedAt != nil {
			continue
		}

		// Apply cursor-based offset.
		if params.Cursor != "" {
			decoded, err := base64.StdEncoding.DecodeString(params.Cursor)
			if err != nil {
				return nil, fmt.Errorf("%w: base64 decode: %w", domain.ErrInvalidCursor, err)
			}
			_ = decoded // cursor validation only
		}

		// Apply multi-field filters (AND semantics).
		match := true
		for _, f := range params.Filters {
			val := getFieldValue(e, f.Field)
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
				if !contains(val, f.Value) {
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

	// Apply cursor position (skip entities before the cursor).
	if params.Cursor != "" {
		cursor, err := decodeCursorToken(params.Cursor)
		if err != nil {
			return nil, fmt.Errorf("%w: %w", domain.ErrInvalidCursor, err)
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

	// Apply limit.
	limit := params.Limit
	if limit <= 0 {
		limit = 20
	}
	end := limit
	if end > len(filtered) {
		end = len(filtered)
	}
	page := filtered[:end]

	return &domain.PaginatedResult{
		Entities:   page,
		TotalCount: len(filtered),
	}, nil
}

func getFieldValue(e *domain.Entity, field string) string {
	switch field {
	case "id":
		return e.ID
	case "name":
		return e.Name
	case "type":
		return e.Type
	case "region":
		return e.Region
	case "status":
		return string(e.Status)
	default:
		return ""
	}
}

func contains(val, substr string) bool {
	return len(val) >= len(substr) && searchSubstring(val, substr)
}

func searchSubstring(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func decodeCursorToken(token string) (domain.Cursor, error) {
	decoded, err := base64.StdEncoding.DecodeString(token)
	if err != nil {
		return domain.Cursor{}, fmt.Errorf("%w: base64 decode: %w", domain.ErrInvalidCursor, err)
	}

	parts := splitAt(decoded, '|')
	if len(parts) != 2 {
		return domain.Cursor{}, domain.ErrInvalidCursor
	}

	createdAt, err := time.Parse(time.RFC3339Nano, string(parts[0]))
	if err != nil {
		return domain.Cursor{}, fmt.Errorf("%w: parse timestamp: %w", domain.ErrInvalidCursor, err)
	}

	return domain.Cursor{CreatedAt: createdAt, ID: string(parts[1])}, nil
}

func splitAt(data []byte, sep byte) [][]byte {
	for i, b := range data {
		if b == sep {
			return [][]byte{data[:i], data[i+1:]}
		}
	}
	return [][]byte{data}
}

// --- Test: Basic pagination with limit ---

func TestListEntities_BasicPagination(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	repo := newFakePaginationRepo()
	uc := NewListEntitiesUseCase(repo, testLogger(t))

	now := time.Now().UTC()
	schemaID := "sch-customer"
	for i := 0; i < 100; i++ {
		status := domain.EntityStatusActive
		region := "us-east-1"
		if i%3 == 0 {
			status = domain.EntityStatusInactive
		}
		if i%5 == 0 {
			region = "eu-west-1"
		}

		entity := &domain.Entity{
			ID:        fmt.Sprintf("ent-%03d", 100-i),
			SchemaID:  schemaID,
			Name:      fmt.Sprintf("Entity-%d", i),
			Type:      "customer",
			Region:    region,
			Status:    status,
			Version:   1,
			CreatedAt: now.Add(-time.Duration(i) * time.Minute),
			UpdatedAt: now.Add(-time.Duration(i) * time.Minute),
		}
		if err := repo.Save(ctx, entity); err != nil {
			t.Fatalf("save entity %d: %v", i, err)
		}
	}

	req := ListEntitiesRequest{
		SchemaID: schemaID,
		Limit:    20,
	}

	result, err := uc.Execute(ctx, req)
	if err != nil {
		t.Fatalf("ListEntities failed: %v", err)
	}

	if len(result.Entities) != 20 {
		t.Errorf("expected 20 entities, got %d", len(result.Entities))
	}
	if result.NextCursor == "" {
		t.Error("expected next_cursor to be non-empty")
	}

	lastEntity := result.Entities[19]
	cursor, err := decodeCursorToken(result.NextCursor)
	if err != nil {
		t.Fatalf("decode cursor: %v", err)
	}
	if cursor.ID != lastEntity.ID {
		t.Errorf("expected cursor ID %q, got %q", lastEntity.ID, cursor.ID)
	}
	if !cursor.CreatedAt.Equal(lastEntity.CreatedAt) {
		t.Errorf("expected cursor CreatedAt %v, got %v", lastEntity.CreatedAt, cursor.CreatedAt)
	}
}

// --- Test: Pagination across pages ---

func TestListEntities_CursorPaginationNoDuplicates(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	repo := newFakePaginationRepo()
	uc := NewListEntitiesUseCase(repo, testLogger(t))

	now := time.Now().UTC()
	schemaID := "sch-customer"
	for i := 0; i < 100; i++ {
		entity := &domain.Entity{
			ID:        fmt.Sprintf("ent-%03d", 100-i),
			SchemaID:  schemaID,
			Name:      fmt.Sprintf("Entity-%d", i),
			Type:      "customer",
			Region:    "us-east-1",
			Status:    domain.EntityStatusActive,
			Version:   1,
			CreatedAt: now.Add(-time.Duration(i) * time.Minute),
			UpdatedAt: now.Add(-time.Duration(i) * time.Minute),
		}
		if err := repo.Save(ctx, entity); err != nil {
			t.Fatalf("save entity %d: %v", i, err)
		}
	}

	seen := make(map[string]bool)
	cursor := ""
	for page := 0; page < 5; page++ {
		req := ListEntitiesRequest{
			SchemaID: schemaID,
			Limit:    20,
			Cursor:   cursor,
		}

		result, err := uc.Execute(ctx, req)
		if err != nil {
			t.Fatalf("page %d: ListEntities failed: %v", page, err)
		}

		if len(result.Entities) == 0 && page < 4 {
			t.Fatalf("page %d: expected entities, got none", page)
		}

		for _, e := range result.Entities {
			if seen[e.ID] {
				t.Errorf("page %d: duplicate entity %q found across pages", page, e.ID)
			}
			seen[e.ID] = true
		}

		for i := 1; i < len(result.Entities); i++ {
			prev := result.Entities[i-1]
			curr := result.Entities[i]
			if curr.CreatedAt.After(prev.CreatedAt) {
				t.Errorf("page %d: ordering violation at index %d: %v > %v",
					page, i, curr.CreatedAt, prev.CreatedAt)
			}
		}

		cursor = result.NextCursor
		if cursor == "" {
			break
		}
	}

	if len(seen) != 100 {
		t.Errorf("expected 100 unique entities across all pages, got %d", len(seen))
	}
}

// --- Test: Multi-field filters with AND semantics ---

func TestListEntities_MultiFieldFilter(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	repo := newFakePaginationRepo()
	uc := NewListEntitiesUseCase(repo, testLogger(t))

	now := time.Now().UTC()
	schemaID := "sch-customer"
	entities := []*domain.Entity{
		{ID: "ent-001", SchemaID: schemaID, Name: "E1", Type: "customer", Region: "us-east-1", Status: domain.EntityStatusActive, Version: 1, CreatedAt: now.Add(-1 * time.Minute)},
		{ID: "ent-002", SchemaID: schemaID, Name: "E2", Type: "customer", Region: "eu-west-1", Status: domain.EntityStatusActive, Version: 1, CreatedAt: now.Add(-2 * time.Minute)},
		{ID: "ent-003", SchemaID: schemaID, Name: "E3", Type: "customer", Region: "us-east-1", Status: domain.EntityStatusInactive, Version: 1, CreatedAt: now.Add(-3 * time.Minute)},
		{ID: "ent-004", SchemaID: schemaID, Name: "E4", Type: "customer", Region: "eu-west-1", Status: domain.EntityStatusInactive, Version: 1, CreatedAt: now.Add(-4 * time.Minute)},
		{ID: "ent-005", SchemaID: schemaID, Name: "E5", Type: "customer", Region: "us-east-1", Status: domain.EntityStatusActive, Version: 1, CreatedAt: now.Add(-5 * time.Minute)},
	}
	for _, e := range entities {
		if err := repo.Save(ctx, e); err != nil {
			t.Fatalf("save entity: %v", err)
		}
	}

	req := ListEntitiesRequest{
		SchemaID: schemaID,
		Limit:    20,
		Filters:  []string{"status==active", "region~us"},
	}

	result, err := uc.Execute(ctx, req)
	if err != nil {
		t.Fatalf("ListEntities failed: %v", err)
	}

	if len(result.Entities) != 2 {
		t.Errorf("expected 2 entities matching BOTH filters, got %d", len(result.Entities))
	}
	for _, e := range result.Entities {
		if e.Status != "active" {
			t.Errorf("expected status 'active', got %q for entity %s", e.Status, e.ID)
		}
		if e.Region != "us-east-1" {
			t.Errorf("expected region containing 'us', got %q for entity %s", e.Region, e.ID)
		}
	}
}

// --- Test: limit=0 defaults to minimum page size of 1 ---

func TestListEntities_ZeroLimit(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	repo := newFakePaginationRepo()
	uc := NewListEntitiesUseCase(repo, testLogger(t))

	now := time.Now().UTC()
	schemaID := "sch-customer"
	for i := 0; i < 5; i++ {
		entity := &domain.Entity{
			ID:        fmt.Sprintf("ent-%03d", i),
			SchemaID:  schemaID,
			Name:      fmt.Sprintf("Entity-%d", i),
			Type:      "customer",
			Region:    "us-east-1",
			Status:    domain.EntityStatusActive,
			Version:   1,
			CreatedAt: now.Add(-time.Duration(i) * time.Minute),
			UpdatedAt: now.Add(-time.Duration(i) * time.Minute),
		}
		if err := repo.Save(ctx, entity); err != nil {
			t.Fatalf("save entity: %v", err)
		}
	}

	req := ListEntitiesRequest{
		SchemaID: schemaID,
		Limit:    0,
	}

	result, err := uc.Execute(ctx, req)
	if err != nil {
		t.Fatalf("ListEntities failed: %v", err)
	}

	if len(result.Entities) != 1 {
		t.Errorf("expected minimum page size of 1 for limit=0, got %d", len(result.Entities))
	}
}

// --- Test: limit=200 caps to maximum page size of 100 ---

func TestListEntities_LimitCap(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	repo := newFakePaginationRepo()
	uc := NewListEntitiesUseCase(repo, testLogger(t))

	now := time.Now().UTC()
	schemaID := "sch-customer"
	for i := 0; i < 150; i++ {
		entity := &domain.Entity{
			ID:        fmt.Sprintf("ent-%03d", i),
			SchemaID:  schemaID,
			Name:      fmt.Sprintf("Entity-%d", i),
			Type:      "customer",
			Region:    "us-east-1",
			Status:    domain.EntityStatusActive,
			Version:   1,
			CreatedAt: now.Add(-time.Duration(i) * time.Minute),
			UpdatedAt: now.Add(-time.Duration(i) * time.Minute),
		}
		if err := repo.Save(ctx, entity); err != nil {
			t.Fatalf("save entity: %v", err)
		}
	}

	req := ListEntitiesRequest{
		SchemaID: schemaID,
		Limit:    200,
	}

	result, err := uc.Execute(ctx, req)
	if err != nil {
		t.Fatalf("ListEntities failed: %v", err)
	}

	if len(result.Entities) > 100 {
		t.Errorf("expected max page size of 100, got %d", len(result.Entities))
	}
	if len(result.Entities) != 100 {
		t.Errorf("expected exactly 100 entities (capped), got %d", len(result.Entities))
	}
}

// --- Test: Invalid cursor returns ErrInvalidCursor ---

func TestListEntities_InvalidCursor(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	repo := newFakePaginationRepo()
	uc := NewListEntitiesUseCase(repo, testLogger(t))

	now := time.Now().UTC()
	schemaID := "sch-customer"
	entity := &domain.Entity{
		ID:        "ent-001",
		SchemaID:  schemaID,
		Name:      "Entity-1",
		Type:      "customer",
		Region:    "us-east-1",
		Status:    domain.EntityStatusActive,
		Version:   1,
		CreatedAt: now,
		UpdatedAt: now,
	}
	if err := repo.Save(ctx, entity); err != nil {
		t.Fatalf("save entity: %v", err)
	}

	req := ListEntitiesRequest{
		SchemaID: schemaID,
		Limit:    20,
		Cursor:   "!!!invalid-base64!!!",
	}

	_, err := uc.Execute(ctx, req)
	if err == nil {
		t.Fatal("expected error for invalid cursor, got nil")
	}
}

// --- Test: include_deleted=true includes soft-deleted entities ---

func TestListEntities_IncludeDeleted(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	repo := newFakePaginationRepo()
	uc := NewListEntitiesUseCase(repo, testLogger(t))

	now := time.Now().UTC()
	schemaID := "sch-customer"

	entities := []*domain.Entity{
		{ID: "ent-001", SchemaID: schemaID, Name: "E1", Type: "customer", Region: "us-east-1", Status: domain.EntityStatusActive, Version: 1, CreatedAt: now.Add(-1 * time.Minute)},
		{ID: "ent-002", SchemaID: schemaID, Name: "E2", Type: "customer", Region: "eu-west-1", Status: domain.EntityStatusDeleted, Version: 2, CreatedAt: now.Add(-2 * time.Minute), DeletedAt: &now},
		{ID: "ent-003", SchemaID: schemaID, Name: "E3", Type: "customer", Region: "us-east-1", Status: domain.EntityStatusActive, Version: 1, CreatedAt: now.Add(-3 * time.Minute)},
		{ID: "ent-004", SchemaID: schemaID, Name: "E4", Type: "customer", Region: "eu-west-1", Status: domain.EntityStatusDeleted, Version: 2, CreatedAt: now.Add(-4 * time.Minute), DeletedAt: &now},
		{ID: "ent-005", SchemaID: schemaID, Name: "E5", Type: "customer", Region: "us-east-1", Status: domain.EntityStatusActive, Version: 1, CreatedAt: now.Add(-5 * time.Minute)},
	}
	for _, e := range entities {
		if err := repo.Save(ctx, e); err != nil {
			t.Fatalf("save entity: %v", err)
		}
	}

	// Without include_deleted — only active entities.
	reqWithout := ListEntitiesRequest{
		SchemaID: schemaID,
		Limit:    20,
	}

	resultWithout, err := uc.Execute(ctx, reqWithout)
	if err != nil {
		t.Fatalf("ListEntities (without deleted) failed: %v", err)
	}
	if len(resultWithout.Entities) != 3 {
		t.Errorf("expected 3 active entities (excluding deleted), got %d", len(resultWithout.Entities))
	}

	// With include_deleted=true.
	reqWith := ListEntitiesRequest{
		SchemaID:      schemaID,
		Limit:         20,
		IncludeDeleted: true,
	}

	resultWith, err := uc.Execute(ctx, reqWith)
	if err != nil {
		t.Fatalf("ListEntities (with deleted) failed: %v", err)
	}
	if len(resultWith.Entities) != 5 {
		t.Errorf("expected 5 entities (including deleted), got %d", len(resultWith.Entities))
	}
}

// testLogger creates a no-op logger for tests.
func testLogger(t *testing.T) *slog.Logger {
	t.Helper()
	return slog.New(slog.DiscardHandler)
}
