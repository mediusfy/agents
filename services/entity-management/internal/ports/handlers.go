// Package ports defines handler interfaces that translate between external
// transports (HTTP, gRPC) and the application layer.
//
// These are "primary ports" (driving side) in Hexagonal Architecture terms.
package ports

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/go-chi/chi/v5"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/application"
	"entity-management/internal/domain"
)

const tracerName = "entity-management.ports"
const meterName = "entity-management.ports"

// HTTPHandler is a marker interface for HTTP handlers that can register
// their routes on a chi router.
type HTTPHandler interface {
	RegisterRoutes(r chi.Router)
}

// GRPCHandler is a marker interface for gRPC service implementations.
type GRPCHandler interface {
	RegisterService(server any) // server is *grpc.Server
}

type CreateEntityUseCase interface {
	Execute(ctx context.Context, req application.CreateEntityRequest) (*application.CreateEntityResponse, error)
}

type ReadEntityUseCase interface {
	Execute(ctx context.Context, entityID string) (*application.ReadEntityResponse, error)
}

type UpdateEntityUseCase interface {
	Execute(ctx context.Context, req application.UpdateEntityRequest) (*application.UpdateEntityResponse, error)
}

type DeleteRestoreUseCase interface {
	SoftDelete(ctx context.Context, id string) error
	HardDelete(ctx context.Context, id string) error
	PermanentDelete(ctx context.Context, id string) error
	Restore(ctx context.Context, id string) error
}

type ListEntitiesUseCase interface {
	Execute(ctx context.Context, req application.ListEntitiesRequest) (*application.ListEntitiesResponse, error)
}

// NewRouter creates a chi router with all routes registered.
func NewRouter(
	schemaSvc *application.SchemaService,
	createUC CreateEntityUseCase,
	readUC ReadEntityUseCase,
	updateUC UpdateEntityUseCase,
	deleteUC DeleteRestoreUseCase,
	listUC ListEntitiesUseCase,
	logger *slog.Logger,
) *chi.Mux {
	r := chi.NewRouter()

	schemaHandler := NewSchemaHTTPHandler(schemaSvc, logger)
	entityHandler := NewEntityHTTPHandler(createUC, readUC, updateUC, deleteUC, listUC, logger)

	r.Route("/api/v1", func(r chi.Router) {
		schemaHandler.RegisterRoutes(r)
		entityHandler.RegisterRoutes(r)
	})

	return r
}

// --- Schema HTTP Handlers ---

// SchemaHTTPHandler translates HTTP requests to the application layer.
type SchemaHTTPHandler struct {
	svc    *application.SchemaService
	logger *slog.Logger
	tracer trace.Tracer
	meter  metric.Meter
}

// NewSchemaHTTPHandler creates a new HTTP handler for schema operations.
func NewSchemaHTTPHandler(svc *application.SchemaService, logger *slog.Logger) *SchemaHTTPHandler {
	return &SchemaHTTPHandler{
		svc:    svc,
		logger: logger.With("handler", "SchemaHTTPHandler"),
		tracer: otel.Tracer(tracerName),
		meter:  otel.Meter(meterName),
	}
}

// RegisterRoutes registers HTTP endpoints on the provided chi router.
func (h *SchemaHTTPHandler) RegisterRoutes(r chi.Router) {
	r.Post("/schemas", h.handleDefineSchema)
	r.Get("/schemas/{id}", h.handleGetSchema)
	r.Get("/schemas", h.handleListSchemas)
}

// SchemaDefineRequest is the HTTP JSON request body for defining a schema.
type SchemaDefineRequest struct {
	Name       string                       `json:"name"`
	Attributes []domain.AttributeDefinition `json:"attributes"`
}

// SchemaDefineResponse is the HTTP JSON response for a successful definition.
type SchemaDefineResponse struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Version int    `json:"version"`
}

// ErrorResponse is a standard error payload for the API.
type ErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (h *SchemaHTTPHandler) handleDefineSchema(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tracer.Start(r.Context(), "ports.SchemaHTTPHandler.handleDefineSchema")
	defer span.End()

	var req SchemaDefineRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "INVALID_JSON",
			Message: "invalid request body: " + err.Error(),
		})
		return
	}

	input := &domain.DefineSchemaInput{
		Name:       req.Name,
		Attributes: req.Attributes,
	}

	result, err := h.svc.DefineSchema(ctx, input)
	if err != nil {
		span.RecordError(err)
		h.recordError(ctx, "define_schema")

		code := http.StatusInternalServerError
		switch {
		case errors.Is(err, domain.ErrInvalidSchema),
			errors.Is(err, domain.ErrUnsupportedFieldType):
			code = http.StatusBadRequest
		case errors.Is(err, domain.ErrSchemaAlreadyExists):
			code = http.StatusConflict
		case errors.Is(err, domain.ErrSchemaNotFound):
			code = http.StatusNotFound
		}

		writeJSON(ctx, w, code, ErrorResponse{
			Code:    httpCodeToErrorCode(code),
			Message: unwrapErrorMessage(err),
		})
		return
	}

	span.SetAttributes(
		attribute.String("schema_id", result.Schema.ID),
		attribute.Int("schema_version", result.Schema.Version),
	)
	h.recordSuccess(ctx, "define_schema")

	writeJSON(ctx, w, http.StatusCreated, SchemaDefineResponse{
		ID:      result.Schema.ID,
		Name:    result.Schema.Name,
		Version: result.Schema.Version,
	})
}

func (h *SchemaHTTPHandler) handleGetSchema(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tracer.Start(r.Context(), "ports.SchemaHTTPHandler.handleGetSchema")
	defer span.End()

	id := chi.URLParam(r, "id")
	if id == "" {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "MISSING_ID",
			Message: "schema id is required",
		})
		return
	}

	schema, err := h.svc.GetSchema(ctx, id)
	if err != nil {
		span.RecordError(err)
		h.recordError(ctx, "get_schema")
		code := http.StatusInternalServerError
		if errors.Is(err, domain.ErrSchemaNotFound) {
			code = http.StatusNotFound
		}
		writeJSON(ctx, w, code, ErrorResponse{
			Code:    httpCodeToErrorCode(code),
			Message: unwrapErrorMessage(err),
		})
		return
	}

	h.recordSuccess(ctx, "get_schema")
	writeJSON(ctx, w, http.StatusOK, schema)
}

func (h *SchemaHTTPHandler) handleListSchemas(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tracer.Start(r.Context(), "ports.SchemaHTTPHandler.handleListSchemas")
	defer span.End()

	schemas, err := h.svc.ListSchemas(ctx)
	if err != nil {
		span.RecordError(err)
		h.recordError(ctx, "list_schemas")
		writeJSON(ctx, w, http.StatusInternalServerError, ErrorResponse{
			Code:    "INTERNAL_ERROR",
			Message: err.Error(),
		})
		return
	}
	if schemas == nil {
		schemas = []*domain.EntitySchema{}
	}
	h.recordSuccess(ctx, "list_schemas")
	writeJSON(ctx, w, http.StatusOK, schemas)
}

func (h *SchemaHTTPHandler) recordSuccess(ctx context.Context, operation string) {
	counter, err := h.meter.Int64Counter("entity_management.operations.success",
		metric.WithDescription("Successful operations"),
	)
	if err != nil {
		return
	}
	counter.Add(ctx, 1, metric.WithAttributes(
		attribute.String("operation", operation),
		attribute.String("component", "SchemaHTTPHandler"),
	))
}

func (h *SchemaHTTPHandler) recordError(ctx context.Context, operation string) {
	counter, err := h.meter.Int64Counter("entity_management.operations.error",
		metric.WithDescription("Failed operations"),
	)
	if err != nil {
		return
	}
	counter.Add(ctx, 1, metric.WithAttributes(
		attribute.String("operation", operation),
		attribute.String("component", "SchemaHTTPHandler"),
	))
}

// --- Entity HTTP Handlers ---

// EntityHTTPHandler translates HTTP requests for entity operations.
type EntityHTTPHandler struct {
	createUC CreateEntityUseCase
	readUC   ReadEntityUseCase
	updateUC UpdateEntityUseCase
	deleteUC DeleteRestoreUseCase
	listUC   ListEntitiesUseCase
	logger   *slog.Logger
	tracer   trace.Tracer
	meter    metric.Meter
}

// NewEntityHTTPHandler creates a new HTTP handler for entity operations.
func NewEntityHTTPHandler(
	createUC CreateEntityUseCase,
	readUC ReadEntityUseCase,
	updateUC UpdateEntityUseCase,
	deleteUC DeleteRestoreUseCase,
	listUC ListEntitiesUseCase,
	logger *slog.Logger,
) *EntityHTTPHandler {
	return &EntityHTTPHandler{
		createUC: createUC,
		readUC:   readUC,
		updateUC: updateUC,
		deleteUC: deleteUC,
		listUC:   listUC,
		logger:   logger.With("handler", "EntityHTTPHandler"),
		tracer:   otel.Tracer(tracerName),
		meter:    otel.Meter(meterName),
	}
}

// RegisterRoutes registers HTTP endpoints on the provided chi router.
func (h *EntityHTTPHandler) RegisterRoutes(r chi.Router) {
	r.Post("/entities", h.handleCreateEntity)
	r.Get("/entities", h.handleListEntities)
	r.Get("/entities/{id}", h.handleGetEntity)
	r.Put("/entities/{id}", h.handleUpdateEntity)
	r.Delete("/entities/{id}", h.handleDeleteEntity)
	r.Post("/entities/{id}/restore", h.handleRestoreEntity)
}

// --- Create Entity (POST /api/v1/entities) ---

type createEntityRequest struct {
	SchemaID   string         `json:"schema_id"`
	Name       string         `json:"name"`
	Type       string         `json:"type"`
	Region     string         `json:"region"`
	Attributes map[string]any `json:"attributes,omitempty"`
	Metadata   map[string]any `json:"metadata,omitempty"`
}

type createEntityResponse struct {
	ID                string `json:"id"`
	SchemaID          string `json:"schema_id"`
	Name              string `json:"name"`
	Type              string `json:"type"`
	Region            string `json:"region"`
	DataResidencyZone string `json:"data_residency_zone"`
	Status            string `json:"status"`
	Version           int    `json:"version"`
	CreatedAt         string `json:"created_at"`
	UpdatedAt         string `json:"updated_at"`
}

func (h *EntityHTTPHandler) handleCreateEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleCreateEntity")
	defer span.End()

	var req createEntityRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "INVALID_JSON",
			Message: "invalid request body: " + err.Error(),
		})
		h.recordError(ctx, "create_entity")
		return
	}

	if req.SchemaID == "" {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "MISSING_SCHEMA_ID",
			Message: "schema_id is required",
		})
		h.recordError(ctx, "create_entity")
		return
	}
	if req.Name == "" {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "MISSING_NAME",
			Message: "name is required",
		})
		h.recordError(ctx, "create_entity")
		return
	}

	idempotencyKey := r.Header.Get("Idempotency-Key")

	span.SetAttributes(
		attribute.String("schema_id", req.SchemaID),
		attribute.String("entity_name", req.Name),
		attribute.String("entity_type", req.Type),
		attribute.String("region", req.Region),
		attribute.Bool("has_idempotency_key", idempotencyKey != ""),
	)

	appReq := application.CreateEntityRequest{
		SchemaID:       req.SchemaID,
		Name:           req.Name,
		Type:           req.Type,
		Region:         req.Region,
		Attributes:     req.Attributes,
		Metadata:       req.Metadata,
		IdempotencyKey: idempotencyKey,
	}

	result, err := h.createUC.Execute(ctx, appReq)
	if err != nil {
		span.RecordError(err)
		h.recordError(ctx, "create_entity")
		code := http.StatusInternalServerError
		switch {
		case errors.Is(err, domain.ErrSchemaNotFound):
			code = http.StatusNotFound
		case errors.Is(err, domain.ErrValidationFailed),
			errors.Is(err, domain.ErrInvalidEntity),
			errors.Is(err, domain.ErrMissingRequiredAttr):
			code = http.StatusBadRequest
		}
		writeJSON(ctx, w, code, ErrorResponse{
			Code:    httpCodeToErrorCode(code),
			Message: unwrapErrorMessage(err),
		})
		return
	}

	span.SetAttributes(
		attribute.String("entity_id", result.EntityID),
		attribute.Bool("created", result.Created),
	)
	h.recordSuccess(ctx, "create_entity")

	resp := createEntityResponse{
		ID:                result.EntityID,
		SchemaID:          req.SchemaID,
		Name:              result.Name,
		Type:              result.Type,
		Region:            result.Region,
		DataResidencyZone: string(domain.ResolveZone(result.Region)),
		Status:            result.Status,
		Version:           1,
		CreatedAt:         result.CreatedAt.Format(iso8601),
		UpdatedAt:         result.UpdatedAt.Format(iso8601),
	}

	statusCode := http.StatusCreated
	if !result.Created {
		statusCode = http.StatusOK
	}
	writeJSON(ctx, w, statusCode, resp)
}

// --- List Entities (GET /api/v1/entities) ---

type updateEntityRequest struct {
	ExpectedVersion int            `json:"expected_version"`
	Name            *string        `json:"name,omitempty"`
	Status          *string        `json:"status,omitempty"`
	Region          *string        `json:"region,omitempty"`
	Attributes      map[string]any `json:"attributes,omitempty"`
	Metadata        map[string]any `json:"metadata,omitempty"`
}

func (h *EntityHTTPHandler) handleListEntities(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleListEntities")
	defer span.End()

	schemaID := r.URL.Query().Get("schema_id")
	if schemaID == "" {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "MISSING_SCHEMA_ID",
			Message: "schema_id query parameter is required",
		})
		return
	}

	limit := 20
	if limitStr := r.URL.Query().Get("limit"); limitStr != "" {
		if v, err := strconv.Atoi(limitStr); err == nil {
			limit = v
		}
	}

	requestOrigin := r.Header.Get("X-Forwarded-For")
	if requestOrigin == "" {
		requestOrigin = r.RemoteAddr
	}

	cursor := r.URL.Query().Get("cursor")
	rawFilters := r.URL.Query()["filter"]
	includeDeleted, _ := strconv.ParseBool(r.URL.Query().Get("include_deleted"))

	span.SetAttributes(
		attribute.String("schema_id", schemaID),
		attribute.Int("limit", limit),
		attribute.Bool("has_cursor", cursor != ""),
		attribute.Int("filter_count", len(rawFilters)),
		attribute.Bool("include_deleted", includeDeleted),
	)

	req := application.ListEntitiesRequest{
		SchemaID:       schemaID,
		Limit:          limit,
		Cursor:         cursor,
		Filters:        rawFilters,
		IncludeDeleted: includeDeleted,
		RequestOrigin:  requestOrigin,
	}

	result, err := h.listUC.Execute(ctx, req)
	if err != nil {
		span.RecordError(err)
		h.recordError(ctx, "list_entities")
		code := http.StatusInternalServerError
		if errors.Is(err, domain.ErrInvalidFilter) || errors.Is(err, domain.ErrInvalidCursor) {
			code = http.StatusBadRequest
		}
		writeJSON(ctx, w, code, ErrorResponse{
			Code:    httpCodeToErrorCode(code),
			Message: unwrapErrorMessage(err),
		})
		return
	}

	h.recordSuccess(ctx, "list_entities")

	type listEntityItem struct {
		ID        string  `json:"id"`
		SchemaID  string  `json:"schema_id"`
		Name      string  `json:"name"`
		Type      string  `json:"type"`
		Region    string  `json:"region"`
		Status    string  `json:"status"`
		CreatedAt string  `json:"created_at"`
		UpdatedAt string  `json:"updated_at"`
		DeletedAt *string `json:"deleted_at,omitempty"`
	}

	items := make([]listEntityItem, 0, len(result.Entities))
	for _, e := range result.Entities {
		item := listEntityItem{
			ID:        e.ID,
			SchemaID:  e.SchemaID,
			Name:      e.Name,
			Type:      e.Type,
			Region:    e.Region,
			Status:    e.Status,
			CreatedAt: e.CreatedAt.Format(iso8601),
			UpdatedAt: e.UpdatedAt.Format(iso8601),
		}
		if e.DeletedAt != nil {
			ds := e.DeletedAt.Format(iso8601)
			item.DeletedAt = &ds
		}
		items = append(items, item)
	}

	response := map[string]any{
		"entities":    items,
		"next_cursor": result.NextCursor,
		"total_count": result.TotalCount,
	}

	writeJSON(ctx, w, http.StatusOK, response)
}

func (h *EntityHTTPHandler) handleGetEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleGetEntity")
	defer span.End()

	id := chi.URLParam(r, "id")
	if id == "" {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "MISSING_ID",
			Message: "entity id is required",
		})
		return
	}

	span.SetAttributes(attribute.String("entity_id", id))

	entity, err := h.readUC.Execute(ctx, id)
	if err != nil {
		span.RecordError(err)
		h.recordError(ctx, "get_entity")

		code := http.StatusInternalServerError
		if errors.Is(err, domain.ErrEntityNotFound) {
			code = http.StatusNotFound
		}

		writeJSON(ctx, w, code, ErrorResponse{
			Code:    httpCodeToErrorCode(code),
			Message: unwrapErrorMessage(err),
		})
		return
	}

	h.recordSuccess(ctx, "get_entity")
	span.SetAttributes(
		attribute.String("entity_status", entity.Status),
		attribute.Int("entity_version", entity.Version),
	)

	writeJSON(ctx, w, http.StatusOK, entity)
}

func (h *EntityHTTPHandler) handleUpdateEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleUpdateEntity")
	defer span.End()

	id := chi.URLParam(r, "id")
	if id == "" {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "MISSING_ID",
			Message: "entity id is required",
		})
		return
	}
	span.SetAttributes(attribute.String("entity_id", id))

	var req updateEntityRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "INVALID_JSON",
			Message: "invalid request body: " + err.Error(),
		})
		h.recordError(ctx, "update_entity")
		return
	}

	if req.ExpectedVersion <= 0 {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "INVALID_VERSION",
			Message: "expected_version must be a positive integer",
		})
		h.recordError(ctx, "update_entity")
		return
	}

	appReq := application.UpdateEntityRequest{
		EntityID:        id,
		ExpectedVersion: req.ExpectedVersion,
		Name:            req.Name,
		Status:          req.Status,
		Region:          req.Region,
		Attributes:      req.Attributes,
		Metadata:        req.Metadata,
	}

	entity, err := h.updateUC.Execute(ctx, appReq)
	if err != nil {
		span.RecordError(err)
		h.recordError(ctx, "update_entity")
		code := http.StatusInternalServerError
		switch {
		case errors.Is(err, domain.ErrEntityNotFound):
			code = http.StatusNotFound
		case errors.Is(err, domain.ErrStaleVersion),
			errors.Is(err, domain.ErrConcurrentModification):
			code = http.StatusConflict
		case errors.Is(err, domain.ErrImmutableField):
			code = http.StatusBadRequest
		case errors.Is(err, domain.ErrInvalidStatusTransition):
			code = http.StatusBadRequest
		}
		writeJSON(ctx, w, code, ErrorResponse{
			Code:    httpCodeToErrorCode(code),
			Message: unwrapErrorMessage(err),
		})
		return
	}

	h.recordSuccess(ctx, "update_entity")
	span.SetAttributes(
		attribute.Int("new_version", entity.Version),
		attribute.String("entity_status", entity.Status),
	)

	writeJSON(ctx, w, http.StatusOK, entity)
}

// handleDeleteEntity handles DELETE /api/v1/entities/{id}.
//
// Gherkin: "As an API consumer, I want to DELETE /api/v1/entities/{id}"
//
//	Scenario: Successful deletion
//	  Given an entity with ID "abc-123" exists
//	  When a DELETE request is made to /api/v1/entities/abc-123
//	  Then the response status is 204
//	  And the entity with ID "abc-123" no longer exists in the database
//
//	Scenario: Entity not found
//	  Given no entity with ID "nonexistent" exists
//	  When a DELETE request is made to /api/v1/entities/nonexistent
//	  Then the response status is 404
func (h *EntityHTTPHandler) handleDeleteEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleDeleteEntity")
	defer span.End()

	id := chi.URLParam(r, "id")
	if id == "" {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "MISSING_ID",
			Message: "entity id is required",
		})
		h.recordError(ctx, "delete_entity")
		return
	}
	span.SetAttributes(attribute.String("entity_id", id))

	permanent := r.URL.Query().Get("permanent") == "true"
	if permanent {
		if err := h.deleteUC.HardDelete(ctx, id); err != nil {
			span.RecordError(err)
			h.recordError(ctx, "delete_entity")

			if errors.Is(err, domain.ErrEntityNotFound) {
				writeJSON(ctx, w, http.StatusNotFound, ErrorResponse{
					Code:    "NOT_FOUND",
					Message: "entity not found",
				})
				return
			}
			if errors.Is(err, domain.ErrNotDeleted) {
				writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
					Code:    "BAD_REQUEST",
					Message: "entity is not soft-deleted",
				})
				return
			}

			writeJSON(ctx, w, http.StatusInternalServerError, ErrorResponse{
				Code:    "INTERNAL_ERROR",
				Message: unwrapErrorMessage(err),
			})
			return
		}

		h.recordSuccess(ctx, "delete_entity")
		writeJSON(ctx, w, http.StatusOK, map[string]string{
			"status":    "hard_deleted",
			"entity_id": id,
		})
		return
	}

	if err := h.deleteUC.PermanentDelete(ctx, id); err != nil {
		span.RecordError(err)
		h.recordError(ctx, "delete_entity")

		if errors.Is(err, domain.ErrEntityNotFound) {
			writeJSON(ctx, w, http.StatusNotFound, ErrorResponse{
				Code:    "NOT_FOUND",
				Message: "entity not found",
			})
			return
		}

		writeJSON(ctx, w, http.StatusInternalServerError, ErrorResponse{
			Code:    "INTERNAL_ERROR",
			Message: unwrapErrorMessage(err),
		})
		return
	}

	h.recordSuccess(ctx, "delete_entity")
	w.WriteHeader(http.StatusNoContent) // 204 No Content
}

func (h *EntityHTTPHandler) handleRestoreEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleRestoreEntity")
	defer span.End()

	id := chi.URLParam(r, "id")
	if id == "" {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "MISSING_ID",
			Message: "entity id is required",
		})
		return
	}
	span.SetAttributes(attribute.String("entity_id", id))

	if err := h.deleteUC.Restore(ctx, id); err != nil {
		span.RecordError(err)
		h.recordError(ctx, "restore_entity")
		code := http.StatusInternalServerError
		switch {
		case errors.Is(err, domain.ErrEntityNotFound):
			code = http.StatusNotFound
		case errors.Is(err, domain.ErrNotDeleted):
			code = http.StatusBadRequest
		}
		writeJSON(ctx, w, code, ErrorResponse{
			Code:    httpCodeToErrorCode(code),
			Message: unwrapErrorMessage(err),
		})
		return
	}

	h.recordSuccess(ctx, "restore_entity")
	writeJSON(ctx, w, http.StatusOK, map[string]string{
		"status":    "restored",
		"entity_id": id,
	})
}

func (h *EntityHTTPHandler) recordSuccess(ctx context.Context, operation string) {
	counter, err := h.meter.Int64Counter("entity_management.operations.success",
		metric.WithDescription("Successful operations"),
	)
	if err != nil {
		return
	}
	counter.Add(ctx, 1, metric.WithAttributes(
		attribute.String("operation", operation),
		attribute.String("component", "EntityHTTPHandler"),
	))
}

func (h *EntityHTTPHandler) recordError(ctx context.Context, operation string) {
	counter, err := h.meter.Int64Counter("entity_management.operations.error",
		metric.WithDescription("Failed operations"),
	)
	if err != nil {
		return
	}
	counter.Add(ctx, 1, metric.WithAttributes(
		attribute.String("operation", operation),
		attribute.String("component", "EntityHTTPHandler"),
	))
}

// --- Helpers ---

const iso8601 = "2006-01-02T15:04:05.000Z"

func writeJSON(ctx context.Context, w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Default().ErrorContext(ctx, "failed to encode JSON response", "error", err)
	}
}

func httpCodeToErrorCode(code int) string {
	switch code {
	case http.StatusBadRequest:
		return "BAD_REQUEST"
	case http.StatusNotFound:
		return "NOT_FOUND"
	case http.StatusConflict:
		return "CONFLICT"
	case http.StatusCreated:
		return "CREATED"
	default:
		return fmt.Sprintf("HTTP_%d", code)
	}
}

// unwrapErrorMessage extracts the innermost sentinel error message from a
// wrapped error chain.
func unwrapErrorMessage(err error) string {
	if err == nil {
		return ""
	}
	current := err
	for {
		var domainErr domain.Error
		if errors.As(current, &domainErr) {
			return domainErr.Error()
		}
		u := errors.Unwrap(current)
		if u == nil {
			break
		}
		current = u
	}
	return err.Error()
}
