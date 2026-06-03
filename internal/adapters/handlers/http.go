package handlers

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"entity-management/internal/domain"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("adapters.handlers.HTTPHandler")

// EntityHandler serves REST endpoints for entity management.
type EntityHandler struct {
	svc    *domain.Service
	logger *slog.Logger
}

// NewEntityHandler wires the domain service into the HTTP layer.
func NewEntityHandler(svc *domain.Service, logger *slog.Logger) *EntityHandler {
	return &EntityHandler{svc: svc, logger: logger}
}

// HandleDeleteHard processes DELETE /api/v1/entities/{id}?permanent=true.
func (h *EntityHandler) HandleDeleteHard(w http.ResponseWriter, r *http.Request) {
	ctx, span := tracer.Start(r.Context(), "adapters.handlers.HTTPHandler.HandleDeleteHard")
	defer span.End()

	// Extract entity ID from the URL path: /api/v1/entities/{id}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/v1/entities/"), "/")
	if len(parts) == 0 || parts[0] == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "missing entity ID in path",
		})
		return
	}
	entityID := parts[0]
	span.SetAttributes(attribute.String("entity.id", entityID))

	// Verify the ?permanent=true query parameter.
	if r.URL.Query().Get("permanent") != "true" {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "query parameter permanent=true is required",
		})
		return
	}

	entity, err := h.svc.HardDelete(ctx, entityID)
	if err != nil {
		switch {
		case errors.Is(err, domain.ErrNotFound):
			writeJSON(w, http.StatusNotFound, map[string]string{
				"error":   "entity not found",
				"message": "no entity exists with the given identifier",
			})
		case errors.Is(err, domain.ErrNotDeleted):
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error":   "entity not deleted",
				"message": "entity must be soft-deleted before hard deletion",
			})
		default:
			h.logger.ErrorContext(ctx, "hard-delete failed", "error", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "internal server error",
			})
		}
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"status":    "hard_deleted",
		"entity_id": entity.ID,
	})
}

// HandleHealth responds to liveness and readiness probes.
func HandleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		// Best-effort.
	}
}

// RegisterRoutes attaches all HTTP routes to the provided mux.
func RegisterRoutes(mux *http.ServeMux, handler *EntityHandler) {
	mux.HandleFunc("GET /healthz", HandleHealth)
	mux.HandleFunc("GET /readyz", HandleHealth)
	mux.HandleFunc("DELETE /api/v1/entities/{id}", handler.HandleDeleteHard)
}
