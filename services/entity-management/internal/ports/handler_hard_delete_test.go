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
// Fake DeleteRestoreUseCase for HTTP handler testing.
// ---------------------------------------------------------------------------

// handlerFakeDeleteRestoreUC is a controllable stub of DeleteRestoreUseCase
// that lets us inject errors and verify calls for hard-delete testing.
type handlerFakeDeleteRestoreUC struct {
	mu             sync.Mutex
	hardDeletedIDs []string
	softDeleteErr  error
	hardDeleteErr  error
	restoreErr     error
}

func newHandlerFakeDeleteRestoreUC() *handlerFakeDeleteRestoreUC {
	return &handlerFakeDeleteRestoreUC{}
}

func (uc *handlerFakeDeleteRestoreUC) SoftDelete(_ context.Context, id string) error {
	return uc.softDeleteErr
}

func (uc *handlerFakeDeleteRestoreUC) HardDelete(_ context.Context, id string) error {
	uc.mu.Lock()
	defer uc.mu.Unlock()
	if uc.hardDeleteErr != nil {
		return uc.hardDeleteErr
	}
	uc.hardDeletedIDs = append(uc.hardDeletedIDs, id)
	return nil
}

func (uc *handlerFakeDeleteRestoreUC) Restore(_ context.Context, _ string) error {
	return uc.restoreErr
}

func (uc *handlerFakeDeleteRestoreUC) HardDeletedIDs() []string {
	uc.mu.Lock()
	defer uc.mu.Unlock()
	result := make([]string, len(uc.hardDeletedIDs))
	copy(result, uc.hardDeletedIDs)
	return result
}

// ---------------------------------------------------------------------------
// Gherkin SCENARIO 1:
//
//	Given entity "ent-001" is soft-deleted (deleted_at set, status="deleted")
//	When a DELETE /api/v1/entities/ent-001?permanent=true request is sent
//	Then the entity record is permanently removed from the database
//	  And an entitymanagement.entity.hard_deleted event is written to the outbox
//	  And HTTP 200 is returned with {"status": "hard_deleted", "entity_id": "ent-001"}
// ---------------------------------------------------------------------------

func TestHandleDeleteEntity_HardDelete_SoftDeletedEntity_Returns200(t *testing.T) {
	t.Parallel()

	deleteUC := newHandlerFakeDeleteRestoreUC() // no error — hard delete succeeds

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		deleteUC,
		&handlerNoopListUC{},
		handlerTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// When a DELETE /api/v1/entities/ent-001?permanent=true request is sent
	req := httptest.NewRequest(http.MethodDelete, "/api/v1/entities/ent-001?permanent=true", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 200 is returned
	if rr.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d; body: %s", rr.Code, rr.Body.String())
	}

	// And HTTP 200 is returned with {"status": "hard_deleted", "entity_id": "ent-001"}
	var resp map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to decode response JSON: %v; body: %s", err, rr.Body.String())
	}

	if resp["status"] != "hard_deleted" {
		t.Errorf("expected status 'hard_deleted', got %q", resp["status"])
	}
	if resp["entity_id"] != "ent-001" {
		t.Errorf("expected entity_id 'ent-001', got %q", resp["entity_id"])
	}

	// Verify the use case was called with the correct ID
	ids := deleteUC.HardDeletedIDs()
	if len(ids) != 1 {
		t.Fatalf("expected 1 hard delete call, got %d", len(ids))
	}
	if ids[0] != "ent-001" {
		t.Errorf("expected hard delete called with 'ent-001', got %q", ids[0])
	}

	// Content-Type is application/json
	ct := rr.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("expected Content-Type application/json, got %q", ct)
	}
}

// ---------------------------------------------------------------------------
// Gherkin SCENARIO 2:
//
//	Given entity "ent-002" is active (deleted_at is NULL)
//	When a hard-delete is attempted on entity "ent-002"
//	Then ErrNotDeleted is returned (HTTP 400)
//	  And message: "entity is not soft-deleted"
//	  And no data is modified
// ---------------------------------------------------------------------------

func TestHandleDeleteEntity_HardDelete_ActiveEntity_Returns400(t *testing.T) {
	t.Parallel()

	deleteUC := newHandlerFakeDeleteRestoreUC()
	deleteUC.hardDeleteErr = domain.ErrNotDeleted // inject ErrNotDeleted

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		deleteUC,
		&handlerNoopListUC{},
		handlerTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// When a hard-delete is attempted on entity "ent-002"
	req := httptest.NewRequest(http.MethodDelete, "/api/v1/entities/ent-002?permanent=true", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 400 is returned
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected HTTP 400, got %d; body: %s", rr.Code, rr.Body.String())
	}

	// And the body is a valid ErrorResponse
	var errResp ErrorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("failed to decode error response: %v; body: %s", err, rr.Body.String())
	}

	// With code "BAD_REQUEST"
	if errResp.Code != "BAD_REQUEST" {
		t.Errorf("expected error code 'BAD_REQUEST', got %q", errResp.Code)
	}

	// And message: "entity is not soft-deleted"
	if errResp.Message != "entity is not soft-deleted" {
		t.Errorf("expected error message 'entity is not soft-deleted', got %q", errResp.Message)
	}

	// No calls to HardDelete should have been made (the use case returned error)
	ids := deleteUC.HardDeletedIDs()
	if len(ids) != 0 {
		t.Errorf("expected no hard delete calls to succeed, got %d", len(ids))
	}
}

// ---------------------------------------------------------------------------
// Gherkin SCENARIO 3:
//
//	Given entity "ent-999" does not exist
//	When a hard-delete is attempted
//	Then HTTP 404 Not Found is returned
// ---------------------------------------------------------------------------

func TestHandleDeleteEntity_HardDelete_NonExistentEntity_Returns404(t *testing.T) {
	t.Parallel()

	deleteUC := newHandlerFakeDeleteRestoreUC()
	deleteUC.hardDeleteErr = domain.ErrEntityNotFound // inject ErrEntityNotFound

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		deleteUC,
		&handlerNoopListUC{},
		handlerTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	// When a hard-delete is attempted on a non-existent entity
	req := httptest.NewRequest(http.MethodDelete, "/api/v1/entities/ent-999?permanent=true", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 404 Not Found is returned
	if rr.Code != http.StatusNotFound {
		t.Fatalf("expected HTTP 404, got %d; body: %s", rr.Code, rr.Body.String())
	}

	// And the body is a valid ErrorResponse
	var errResp ErrorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("failed to decode error response: %v; body: %s", err, rr.Body.String())
	}

	// With code "NOT_FOUND"
	if errResp.Code != "NOT_FOUND" {
		t.Errorf("expected error code 'NOT_FOUND', got %q", errResp.Code)
	}

	// With message "entity not found"
	if errResp.Message != "entity not found" {
		t.Errorf("expected error message 'entity not found', got %q", errResp.Message)
	}

	// No calls to HardDelete should have been made
	ids := deleteUC.HardDeletedIDs()
	if len(ids) != 0 {
		t.Errorf("expected no hard delete calls to succeed, got %d", len(ids))
	}
}

// ---------------------------------------------------------------------------
// Edge case: Missing entity ID in URL returns HTTP 400
// ---------------------------------------------------------------------------

func TestHandleDeleteEntity_HardDelete_EmptyID_Returns400(t *testing.T) {
	t.Parallel()

	deleteUC := newHandlerFakeDeleteRestoreUC()

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		deleteUC,
		&handlerNoopListUC{},
		handlerTestLogger(t),
	)

	// Build request with empty ID
	req := httptest.NewRequest(http.MethodDelete, "/entities/?permanent=true", nil)
	rr := httptest.NewRecorder()

	// Inject chi route context with empty "id" param
	chiCtx := chi.NewRouteContext()
	chiCtx.URLParams.Add("id", "")
	req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, chiCtx))

	handler.handleDeleteEntity(rr, req)

	// Then HTTP 400 is returned
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected HTTP 400 for empty ID, got %d; body: %s", rr.Code, rr.Body.String())
	}

	var errResp ErrorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("failed to decode error response: %v; body: %s", err, rr.Body.String())
	}
	if errResp.Code != "MISSING_ID" {
		t.Errorf("expected code 'MISSING_ID', got %q", errResp.Code)
	}
	if errResp.Message == "" {
		t.Error("expected non-empty error message")
	}
}

// ---------------------------------------------------------------------------
// Edge case: Unexpected repository error results in HTTP 500
// ---------------------------------------------------------------------------

func TestHandleDeleteEntity_HardDelete_InternalServerError_Returns500(t *testing.T) {
	t.Parallel()

	deleteUC := newHandlerFakeDeleteRestoreUC()
	deleteUC.hardDeleteErr = domain.ErrConcurrentModification // generic unexpected error

	handler := NewEntityHTTPHandler(
		&handlerNoopCreateUC{},
		&handlerNoopReadUC{},
		&handlerNoopUpdateUC{},
		deleteUC,
		&handlerNoopListUC{},
		handlerTestLogger(t),
	)

	r := chi.NewRouter()
	r.Route("/api/v1", func(r chi.Router) {
		handler.RegisterRoutes(r)
	})

	req := httptest.NewRequest(http.MethodDelete, "/api/v1/entities/ent-500?permanent=true", nil)
	rr := httptest.NewRecorder()
	r.ServeHTTP(rr, req)

	// Then HTTP 500 is returned
	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("expected HTTP 500 for unexpected error, got %d; body: %s", rr.Code, rr.Body.String())
	}

	var errResp ErrorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("failed to decode error response: %v; body: %s", err, rr.Body.String())
	}
	if errResp.Code == "" {
		t.Error("expected non-empty error code")
	}
	if errResp.Message == "" {
		t.Error("expected non-empty error message")
	}
}

// ---------------------------------------------------------------------------
// Table-driven: Hard-Delete HTTP Handler Scenarios
// ---------------------------------------------------------------------------

func TestHandleDeleteEntity_HardDelete_TableDriven(t *testing.T) {
	t.Parallel()

	type testCase struct {
		name           string
		entityID       string
		injectErr      error
		wantHTTPStatus int
		wantCode       string // ErrorResponse code
		wantMessage    string // ErrorResponse message (empty means success)
		wantStatus     string // JSON response status field (success case)
		wantCalled     bool   // whether hard delete was called
	}

	tests := []testCase{
		{
			name:           "soft-deleted entity hard-delete succeeds",
			entityID:       "ent-001",
			injectErr:      nil,
			wantHTTPStatus: http.StatusOK,
			wantStatus:     "hard_deleted",
			wantCalled:     true,
		},
		{
			name:           "active entity hard-delete returns 400",
			entityID:       "ent-002",
			injectErr:      domain.ErrNotDeleted,
			wantHTTPStatus: http.StatusBadRequest,
			wantCode:       "BAD_REQUEST",
			wantMessage:    "entity is not soft-deleted",
			wantCalled:     false,
		},
		{
			name:           "non-existent entity hard-delete returns 404",
			entityID:       "ent-999",
			injectErr:      domain.ErrEntityNotFound,
			wantHTTPStatus: http.StatusNotFound,
			wantCode:       "NOT_FOUND",
			wantMessage:    "entity not found",
			wantCalled:     false,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			deleteUC := newHandlerFakeDeleteRestoreUC()
			deleteUC.hardDeleteErr = tt.injectErr

			handler := NewEntityHTTPHandler(
				&handlerNoopCreateUC{},
				&handlerNoopReadUC{},
				&handlerNoopUpdateUC{},
				deleteUC,
				&handlerNoopListUC{},
				handlerTestLogger(t),
			)

			r := chi.NewRouter()
			r.Route("/api/v1", func(r chi.Router) {
				handler.RegisterRoutes(r)
			})

			req := httptest.NewRequest(http.MethodDelete, "/api/v1/entities/"+tt.entityID+"?permanent=true", nil)
			rr := httptest.NewRecorder()
			r.ServeHTTP(rr, req)

			if rr.Code != tt.wantHTTPStatus {
				t.Fatalf("expected HTTP %d, got %d; body: %s", tt.wantHTTPStatus, rr.Code, rr.Body.String())
			}

			if tt.wantStatus != "" {
				// Success case — verify JSON body
				var resp map[string]string
				if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
					t.Fatalf("failed to decode response JSON: %v; body: %s", err, rr.Body.String())
				}
				if resp["status"] != tt.wantStatus {
					t.Errorf("expected status %q, got %q", tt.wantStatus, resp["status"])
				}
				if resp["entity_id"] != tt.entityID {
					t.Errorf("expected entity_id %q, got %q", tt.entityID, resp["entity_id"])
				}
			}

			if tt.wantCode != "" {
				// Error case — verify ErrorResponse
				var errResp ErrorResponse
				if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
					t.Fatalf("failed to decode error response: %v; body: %s", err, rr.Body.String())
				}
				if errResp.Code != tt.wantCode {
					t.Errorf("expected error code %q, got %q", tt.wantCode, errResp.Code)
				}
				if errResp.Message != tt.wantMessage {
					t.Errorf("expected error message %q, got %q", tt.wantMessage, errResp.Message)
				}
			}

			// Verify whether hard delete was called
			ids := deleteUC.HardDeletedIDs()
			if tt.wantCalled && len(ids) != 1 {
				t.Errorf("expected hard delete to be called once, got %d calls", len(ids))
			}
			if !tt.wantCalled && len(ids) != 0 {
				t.Errorf("expected no hard delete calls, got %d", len(ids))
			}
			if tt.wantCalled && len(ids) == 1 && ids[0] != tt.entityID {
				t.Errorf("expected hard delete called with %q, got %q", tt.entityID, ids[0])
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Stub: handlerNoopReadUC needed for EntityHTTPHandler construction.
// ---------------------------------------------------------------------------

type handlerNoopReadUC struct{}

func (n *handlerNoopReadUC) Execute(_ context.Context, _ string) (*application.ReadEntityResponse, error) {
	return nil, nil
}
