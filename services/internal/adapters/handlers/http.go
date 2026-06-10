package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/drewjocham/agents/internal/domain"
)

// HTTPServer holds dependencies for HTTP handlers.
type HTTPServer struct {
	svc *domain.EntityService
	mux *http.ServeMux
}

// NewHTTPServer creates an HTTP server wired to the entity service.
func NewHTTPServer(svc *domain.EntityService) *HTTPServer {
	h := &HTTPServer{
		svc: svc,
		mux: http.NewServeMux(),
	}
	h.registerRoutes()
	return h
}

func (h *HTTPServer) registerRoutes() {
	h.mux.HandleFunc("GET /api/v1/entities", h.handleListEntities)
	h.mux.HandleFunc("GET /api/v1/entities/{id}", h.handleGetEntity)
	h.mux.HandleFunc("GET /healthz", h.handleHealthz)
	h.mux.HandleFunc("GET /readyz", h.handleReadyz)
}

// ServeHTTP implements http.Handler.
func (h *HTTPServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.mux.ServeHTTP(w, r)
}

// ------- Handlers -------

func (h *HTTPServer) handleListEntities(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	page, limit := parsePagination(r)
	input := domain.ListInput{Page: page, Limit: limit}

	result, err := h.svc.ListEntities(ctx, input)
	if err != nil {
		slog.ErrorContext(ctx, "list entities failed", "error", err)
		writeJSON(ctx, w, http.StatusInternalServerError, map[string]string{"error": "internal server error"})
		return
	}

	items := make([]entityResponse, 0, len(result.Items))
	for _, e := range result.Items {
		items = append(items, entityToResponse(e))
	}

	resp := listEntitiesResponse{
		Items: items,
		Total: result.Total,
		Page:  result.Page,
		Limit: result.Limit,
	}
	if next := result.NextPage(); next != "" {
		resp.Next = next
	}

	writeJSON(ctx, w, http.StatusOK, resp)
}

func (h *HTTPServer) handleGetEntity(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	id := strings.TrimSpace(r.PathValue("id"))

	entity, err := h.svc.GetEntity(ctx, id)
	if err != nil {
		switch {
		case errors.Is(err, domain.ErrEntityNotFound):
			writeJSON(ctx, w, http.StatusNotFound, map[string]string{"error": "entity not found"})
		case errors.Is(err, domain.ErrInvalidEntityID):
			writeJSON(ctx, w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		default:
			slog.ErrorContext(ctx, "get entity failed", "id", id, "error", err)
			writeJSON(ctx, w, http.StatusInternalServerError, map[string]string{"error": "internal server error"})
		}
		return
	}

	writeJSON(ctx, w, http.StatusOK, entityToResponse(*entity))
}

func (h *HTTPServer) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"ok"}`))
}

func (h *HTTPServer) handleReadyz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"ready"}`))
}

// ------- Request / Response types -------

type listEntitiesResponse struct {
	Items []entityResponse `json:"items"`
	Total int              `json:"total"`
	Page  int              `json:"page,omitempty"`
	Limit int              `json:"limit,omitempty"`
	Next  string           `json:"next,omitempty"`
}

type entityResponse struct {
	ID        string            `json:"id"`
	Name      string            `json:"name"`
	Type      string            `json:"type"`
	Metadata  map[string]string `json:"metadata,omitempty"`
	CreatedAt string            `json:"created_at"`
	UpdatedAt string            `json:"updated_at"`
}

func entityToResponse(e domain.Entity) entityResponse {
	return entityResponse{
		ID:        e.ID,
		Name:      e.Name,
		Type:      e.Type,
		Metadata:  e.Metadata,
		CreatedAt: e.CreatedAt.Format("2006-01-02T15:04:05Z07:00"),
		UpdatedAt: e.UpdatedAt.Format("2006-01-02T15:04:05Z07:00"),
	}
}

// ------- Helpers -------

// parsePagination extracts page and limit from query parameters with defaults.
func parsePagination(r *http.Request) (page, limit int) {
	page = 1
	limit = 20

	if p := r.URL.Query().Get("page"); p != "" {
		if v, err := strconv.Atoi(p); err == nil && v > 0 {
			page = v
		}
	}
	if l := r.URL.Query().Get("limit"); l != "" {
		if v, err := strconv.Atoi(l); err == nil && v > 0 && v <= 100 {
			limit = v
		}
	}
	return
}

func writeJSON(_ context.Context, w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("write json response", "error", err)
	}
}
