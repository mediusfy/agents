package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"

	"github.com/prodanlabs/region-resolver/internal/domain"
)

var httpTracer = otel.Tracer("handlers.http")

// HTTPHandler implements RESTful HTTP endpoints for the region-resolver
// service, translating between JSON and domain types.
type HTTPHandler struct {
	svc    *domain.Service
	logger *slog.Logger
}

// NewHTTPHandler creates a new HTTP handler.
func NewHTTPHandler(svc *domain.Service, logger *slog.Logger) *HTTPHandler {
	return &HTTPHandler{
		svc:    svc,
		logger: logger.With("handler", "HTTPHandler"),
	}
}

// RegisterRoutes registers all HTTP endpoints on the provided mux.
func (h *HTTPHandler) RegisterRoutes(mux *http.ServeMux, readyFunc func(context.Context) bool) {
	mux.HandleFunc("GET /healthz", h.handleHealthz)
	mux.HandleFunc("GET /readyz", h.handleReadyz(readyFunc))
	mux.HandleFunc("POST /api/v1/entities", h.handleCreateEntity)
	mux.HandleFunc("GET /api/v1/entities", h.handleListEntities)
	mux.HandleFunc("GET /api/v1/entities/{id}", h.handleGetEntity)
	mux.HandleFunc("PUT /api/v1/entities/{id}", h.handleUpdateEntity)
	mux.HandleFunc("DELETE /api/v1/entities/{id}", h.handleDeleteEntity)
}

// --- Health Endpoints ---

func (h *HTTPHandler) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *HTTPHandler) handleReadyz(readyFunc func(context.Context) bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if readyFunc(r.Context()) {
			writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
		} else {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unavailable"})
		}
	}
}

// --- Request/Response Types ---

type createEntityRequest struct {
	Name   string            `json:"name"`
	Region string            `json:"region"`
	Labels map[string]string `json:"labels,omitempty"`
}

type entityResponse struct {
	ID                string            `json:"id"`
	Name              string            `json:"name"`
	Region            string            `json:"region"`
	DataResidencyZone string            `json:"data_residency_zone"`
	Status            string            `json:"status"`
	Version           int               `json:"version"`
	Labels            map[string]string `json:"labels,omitempty"`
	CreatedAt         string            `json:"created_at"`
	UpdatedAt         string            `json:"updated_at"`
}

type updateEntityRequest struct {
	ExpectedVersion int               `json:"expected_version"`
	Name            *string           `json:"name,omitempty"`
	Status          *string           `json:"status,omitempty"`
	Labels          map[string]string `json:"labels,omitempty"`
}

type errorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// --- Create Entity ---

func (h *HTTPHandler) handleCreateEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := httpTracer.Start(r.Context(), "handlers.HTTPHandler.handleCreateEntity")
	defer span.End()

	var req createEntityRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse{
			Code: "INVALID_JSON", Message: "invalid request body: " + err.Error(),
		})
		return
	}

	span.SetAttributes(
		attribute.String("entity_name", req.Name),
		attribute.String("region", req.Region),
	)

	result, err := h.svc.CreateEntity(ctx, domain.CreateEntityInput{
		Name:   req.Name,
		Region: req.Region,
		Labels: req.Labels,
	})
	if err != nil {
		span.RecordError(err)
		code, resp := httpErrorResponse(err)
		writeJSON(w, code, resp)
		return
	}

	span.SetAttributes(
		attribute.String("entity_id", result.Entity.ID),
		attribute.String("data_residency_zone", string(result.Entity.DataResidencyZone)),
	)

	writeJSON(w, http.StatusCreated, entityToResponse(result.Entity))
}

// --- Get Entity ---

func (h *HTTPHandler) handleGetEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := httpTracer.Start(r.Context(), "handlers.HTTPHandler.handleGetEntity")
	defer span.End()

	id := r.PathValue("id")
	span.SetAttributes(attribute.String("entity_id", id))

	entity, err := h.svc.GetEntity(ctx, id)
	if err != nil {
		span.RecordError(err)
		code, resp := httpErrorResponse(err)
		writeJSON(w, code, resp)
		return
	}

	span.SetAttributes(
		attribute.String("region", entity.Region),
		attribute.String("data_residency_zone", string(entity.DataResidencyZone)),
	)

	writeJSON(w, http.StatusOK, entityToResponse(entity))
}

// --- Update Entity ---

func (h *HTTPHandler) handleUpdateEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := httpTracer.Start(r.Context(), "handlers.HTTPHandler.handleUpdateEntity")
	defer span.End()

	id := r.PathValue("id")
	span.SetAttributes(attribute.String("entity_id", id))

	var req updateEntityRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse{
			Code: "INVALID_JSON", Message: "invalid request body: " + err.Error(),
		})
		return
	}

	if req.ExpectedVersion <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse{
			Code: "INVALID_VERSION", Message: "expected_version must be a positive integer",
		})
		return
	}

	op := domain.UpdateOperation{
		ExpectedVersion: req.ExpectedVersion,
	}
	if req.Name != nil {
		op.Name = req.Name
	}
	if req.Status != nil {
		s := domain.EntityStatus(*req.Status)
		op.Status = &s
	}
	if req.Labels != nil {
		op.Labels = req.Labels
	}

	entity, err := h.svc.UpdateEntity(ctx, id, op)
	if err != nil {
		span.RecordError(err)
		code, resp := httpErrorResponse(err)
		writeJSON(w, code, resp)
		return
	}

	span.SetAttributes(attribute.Int("new_version", entity.Version))
	writeJSON(w, http.StatusOK, entityToResponse(entity))
}

// --- Delete Entity ---

func (h *HTTPHandler) handleDeleteEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := httpTracer.Start(r.Context(), "handlers.HTTPHandler.handleDeleteEntity")
	defer span.End()

	id := r.PathValue("id")
	span.SetAttributes(attribute.String("entity_id", id))

	if err := h.svc.DeleteEntity(ctx, id); err != nil {
		span.RecordError(err)
		code, resp := httpErrorResponse(err)
		writeJSON(w, code, resp)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted", "entity_id": id})
}

// --- List Entities ---

func (h *HTTPHandler) handleListEntities(w http.ResponseWriter, r *http.Request) {
	ctx, span := httpTracer.Start(r.Context(), "handlers.HTTPHandler.handleListEntities")
	defer span.End()

	entities, err := h.svc.ListEntities(ctx)
	if err != nil {
		span.RecordError(err)
		code, resp := httpErrorResponse(err)
		writeJSON(w, code, resp)
		return
	}

	items := make([]entityResponse, 0, len(entities))
	for _, e := range entities {
		items = append(items, entityToResponse(e))
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"entities": items,
		"count":    len(items),
	})
}

// --- Helpers ---

func entityToResponse(e *domain.Entity) entityResponse {
	return entityResponse{
		ID:                e.ID,
		Name:              e.Name,
		Region:            e.Region,
		DataResidencyZone: string(e.DataResidencyZone),
		Status:            string(e.Status),
		Version:           e.Version,
		Labels:            e.Labels,
		CreatedAt:         e.CreatedAt.Format(iso8601),
		UpdatedAt:         e.UpdatedAt.Format(iso8601),
	}
}

const iso8601 = "2006-01-02T15:04:05.000Z"

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Default().Error("failed to encode JSON response", "error", err)
	}
}

func httpErrorResponse(err error) (int, errorResponse) {
	switch {
	case errors.Is(err, domain.ErrEntityNotFound):
		return http.StatusNotFound, errorResponse{Code: "NOT_FOUND", Message: err.Error()}
	case errors.Is(err, domain.ErrImmutableField):
		return http.StatusBadRequest, errorResponse{Code: "IMMUTABLE_FIELD", Message: err.Error()}
	case errors.Is(err, domain.ErrStaleVersion):
		return http.StatusConflict, errorResponse{Code: "STALE_VERSION", Message: err.Error()}
	case errors.Is(err, domain.ErrInvalidEntity):
		return http.StatusBadRequest, errorResponse{Code: "INVALID_ENTITY", Message: err.Error()}
	default:
		return http.StatusInternalServerError, errorResponse{Code: "INTERNAL_ERROR", Message: err.Error()}
	}
}

// Silence unused import warning.
var _ = strconv.Itoa
