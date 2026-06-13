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

const (
	tracerName      = "entity-management.ports"
	meterName       = "entity-management.ports"
	iso8601         = "2006-01-02T15:04:05.000Z"
	contentTypeJSON = "application/json"

	metricSuccessName = "entity_management.operations.success"
	metricErrorName   = "entity_management.operations.error"

	attrSchemaID       = "schema_id"
	attrSchemaVersion  = "schema_version"
	attrEntityID       = "entity_id"
	attrEntityName     = "entity_name"
	attrEntityType     = "entity_type"
	attrEntityStatus   = "entity_status"
	attrEntityVersion  = "entity_version"
	attrNewVersion     = "new_version"
	attrRegion         = "region"
	attrHasIdempotency = "has_idempotency_key"
	attrCreated        = "created"
	attrLimit          = "limit"
	attrHasCursor      = "has_cursor"
	attrFilterCount    = "filter_count"
	attrIncludeDeleted = "include_deleted"
	attrOperation      = "operation"
	attrComponent      = "component"

	headerIdempotency  = "Idempotency-Key"
	headerForwardedFor = "X-Forwarded-For"

	opDefineSchema  = "define_schema"
	opGetSchema     = "get_schema"
	opListSchemas   = "list_schemas"
	opCreateEntity  = "create_entity"
	opListEntities  = "list_entities"
	opGetEntity     = "get_entity"
	opUpdateEntity  = "update_entity"
	opDeleteEntity  = "delete_entity"
	opRestoreEntity = "restore_entity"

	compSchemaHandler = "SchemaHTTPHandler"
	compEntityHandler = "EntityHTTPHandler"
)

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

// --- Telemetry Utility Engine ---

type telemetryEngine struct {
	tracer    trace.Tracer
	meter     metric.Meter
	component string
}

func newTelemetryEngine(component string) telemetryEngine {
	return telemetryEngine{
		tracer:    otel.Tracer(tracerName),
		meter:     otel.Meter(meterName),
		component: component,
	}
}

func (t *telemetryEngine) recordSuccess(ctx context.Context, operation string) {
	if counter, err := t.meter.Int64Counter(metricSuccessName, metric.WithDescription("Successful operations")); err == nil {
		counter.Add(ctx, 1, metric.WithAttributes(
			attribute.String(attrOperation, operation),
			attribute.String(attrComponent, t.component),
		))
	}
}

func (t *telemetryEngine) recordError(ctx context.Context, operation string) {
	if counter, err := t.meter.Int64Counter(metricErrorName, metric.WithDescription("Failed operations")); err == nil {
		counter.Add(ctx, 1, metric.WithAttributes(
			attribute.String(attrOperation, operation),
			attribute.String(attrComponent, t.component),
		))
	}
}

// --- Schema HTTP Handlers ---

type SchemaHTTPHandler struct {
	svc    *application.SchemaService
	logger *slog.Logger
	tel    telemetryEngine
}

func NewSchemaHTTPHandler(svc *application.SchemaService, logger *slog.Logger) *SchemaHTTPHandler {
	return &SchemaHTTPHandler{
		svc:    svc,
		logger: logger.With("handler", compSchemaHandler),
		tel:    newTelemetryEngine(compSchemaHandler),
	}
}

func (h *SchemaHTTPHandler) RegisterRoutes(r chi.Router) {
	r.Post("/schemas", h.handleDefineSchema)
	r.Get("/schemas/{id}", h.handleGetSchema)
	r.Get("/schemas", h.handleListSchemas)
}

type SchemaDefineRequest struct {
	Name       string                       `json:"name"`
	Attributes []domain.AttributeDefinition `json:"attributes"`
}

type SchemaDefineResponse struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Version int    `json:"version"`
}

type ErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (h *SchemaHTTPHandler) handleDefineSchema(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tel.tracer.Start(r.Context(), "ports.SchemaHTTPHandler.handleDefineSchema")
	defer span.End()

	var req SchemaDefineRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.tel.recordError(ctx, opDefineSchema)
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
		h.tel.recordError(ctx, opDefineSchema)
		handleHTTPError(ctx, w, err)
		return
	}

	span.SetAttributes(
		attribute.String(attrSchemaID, result.Schema.ID),
		attribute.Int(attrSchemaVersion, result.Schema.Version),
	)
	h.tel.recordSuccess(ctx, opDefineSchema)

	writeJSON(ctx, w, http.StatusCreated, SchemaDefineResponse{
		ID:      result.Schema.ID,
		Name:    result.Schema.Name,
		Version: result.Schema.Version,
	})
}

func (h *SchemaHTTPHandler) handleGetSchema(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tel.tracer.Start(r.Context(), "ports.SchemaHTTPHandler.handleGetSchema")
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
		h.tel.recordError(ctx, opGetSchema)
		handleHTTPError(ctx, w, err)
		return
	}

	h.tel.recordSuccess(ctx, opGetSchema)
	writeJSON(ctx, w, http.StatusOK, schema)
}

func (h *SchemaHTTPHandler) handleListSchemas(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tel.tracer.Start(r.Context(), "ports.SchemaHTTPHandler.handleListSchemas")
	defer span.End()

	schemas, err := h.svc.ListSchemas(ctx)
	if err != nil {
		span.RecordError(err)
		h.tel.recordError(ctx, opListSchemas)
		handleHTTPError(ctx, w, err)
		return
	}
	if schemas == nil {
		schemas = []*domain.EntitySchema{}
	}
	h.tel.recordSuccess(ctx, opListSchemas)
	writeJSON(ctx, w, http.StatusOK, schemas)
}

// --- Entity HTTP Handlers ---

type EntityHTTPHandler struct {
	createUC CreateEntityUseCase
	readUC   ReadEntityUseCase
	updateUC UpdateEntityUseCase
	deleteUC DeleteRestoreUseCase
	listUC   ListEntitiesUseCase
	logger   *slog.Logger
	tel      telemetryEngine
}

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
		logger:   logger.With("handler", compEntityHandler),
		tel:      newTelemetryEngine(compEntityHandler),
	}
}

func (h *EntityHTTPHandler) RegisterRoutes(r chi.Router) {
	r.Post("/entities", h.handleCreateEntity)
	r.Get("/entities", h.handleListEntities)
	r.Get("/entities/{id}", h.handleGetEntity)
	r.Put("/entities/{id}", h.handleUpdateEntity)
	r.Delete("/entities/{id}", h.handleDeleteEntity)
	r.Post("/entities/{id}/restore", h.handleRestoreEntity)
}

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
	ctx, span := h.tel.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleCreateEntity")
	defer span.End()

	var req createEntityRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.tel.recordError(ctx, opCreateEntity)
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "INVALID_JSON",
			Message: "invalid request body: " + err.Error(),
		})
		return
	}

	if req.SchemaID == "" {
		h.tel.recordError(ctx, opCreateEntity)
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{Code: "MISSING_SCHEMA_ID", Message: "schema_id is required"})
		return
	}
	if req.Name == "" {
		h.tel.recordError(ctx, opCreateEntity)
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{Code: "MISSING_NAME", Message: "name is required"})
		return
	}

	idempotencyKey := r.Header.Get(headerIdempotency)

	span.SetAttributes(
		attribute.String(attrSchemaID, req.SchemaID),
		attribute.String(attrEntityName, req.Name),
		attribute.String(attrEntityType, req.Type),
		attribute.String(attrRegion, req.Region),
		attribute.Bool(attrHasIdempotency, idempotencyKey != ""),
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
		h.tel.recordError(ctx, opCreateEntity)
		handleHTTPError(ctx, w, err)
		return
	}

	span.SetAttributes(
		attribute.String(attrEntityID, result.EntityID),
		attribute.Bool(attrCreated, result.Created),
	)
	h.tel.recordSuccess(ctx, opCreateEntity)

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

type updateEntityRequest struct {
	ExpectedVersion int            `json:"expected_version"`
	Name            *string        `json:"name,omitempty"`
	Status          *string        `json:"status,omitempty"`
	Region          *string        `json:"region,omitempty"`
	Attributes      map[string]any `json:"attributes,omitempty"`
	Metadata        map[string]any `json:"metadata,omitempty"`
}

func (h *EntityHTTPHandler) handleListEntities(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tel.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleListEntities")
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

	requestOrigin := r.Header.Get(headerForwardedFor)
	if requestOrigin == "" {
		requestOrigin = r.RemoteAddr
	}

	cursor := r.URL.Query().Get("cursor")
	rawFilters := r.URL.Query()["filter"]
	includeDeleted, _ := strconv.ParseBool(r.URL.Query().Get("include_deleted"))

	span.SetAttributes(
		attribute.String(attrSchemaID, schemaID),
		attribute.Int(attrLimit, limit),
		attribute.Bool(attrHasCursor, cursor != ""),
		attribute.Int(attrFilterCount, len(rawFilters)),
		attribute.Bool(attrIncludeDeleted, includeDeleted),
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
		h.tel.recordError(ctx, opListEntities)
		handleHTTPError(ctx, w, err)
		return
	}

	h.tel.recordSuccess(ctx, opListEntities)

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

	writeJSON(ctx, w, http.StatusOK, map[string]any{
		"entities":    items,
		"next_cursor": result.NextCursor,
		"total_count": result.TotalCount,
	})
}

func (h *EntityHTTPHandler) handleGetEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tel.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleGetEntity")
	defer span.End()

	id := chi.URLParam(r, "id")
	if id == "" {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "MISSING_ID",
			Message: "entity id is required",
		})
		return
	}

	span.SetAttributes(attribute.String(attrEntityID, id))

	entity, err := h.readUC.Execute(ctx, id)
	if err != nil {
		span.RecordError(err)
		h.tel.recordError(ctx, opGetEntity)
		handleHTTPError(ctx, w, err)
		return
	}

	h.tel.recordSuccess(ctx, opGetEntity)
	span.SetAttributes(
		attribute.String(attrEntityStatus, entity.Status),
		attribute.Int(attrEntityVersion, entity.Version),
	)

	writeJSON(ctx, w, http.StatusOK, entity)
}

func (h *EntityHTTPHandler) handleUpdateEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tel.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleUpdateEntity")
	defer span.End()

	id := chi.URLParam(r, "id")
	if id == "" {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "MISSING_ID",
			Message: "entity id is required",
		})
		return
	}
	span.SetAttributes(attribute.String(attrEntityID, id))

	var req updateEntityRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.tel.recordError(ctx, opUpdateEntity)
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "INVALID_JSON",
			Message: "invalid request body: " + err.Error(),
		})
		return
	}

	if req.ExpectedVersion <= 0 {
		h.tel.recordError(ctx, opUpdateEntity)
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "INVALID_VERSION",
			Message: "expected_version must be a positive integer",
		})
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
		h.tel.recordError(ctx, opUpdateEntity)
		handleHTTPError(ctx, w, err)
		return
	}

	h.tel.recordSuccess(ctx, opUpdateEntity)
	span.SetAttributes(
		attribute.Int(attrNewVersion, entity.Version),
		attribute.String(attrEntityStatus, entity.Status),
	)

	writeJSON(ctx, w, http.StatusOK, entity)
}

func (h *EntityHTTPHandler) handleDeleteEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tel.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleDeleteEntity")
	defer span.End()

	id := chi.URLParam(r, "id")
	if id == "" {
		h.tel.recordError(ctx, opDeleteEntity)
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{Code: "MISSING_ID", Message: "entity id is required"})
		return
	}
	span.SetAttributes(attribute.String(attrEntityID, id))

	permanent := r.URL.Query().Get("permanent") == "true"
	if permanent {
		if err := h.deleteUC.HardDelete(ctx, id); err != nil {
			span.RecordError(err)
			h.tel.recordError(ctx, opDeleteEntity)
			handleHTTPError(ctx, w, err)
			return
		}

		h.tel.recordSuccess(ctx, opDeleteEntity)
		writeJSON(ctx, w, http.StatusOK, map[string]string{
			"status":    "hard_deleted",
			"entity_id": id,
		})
		return
	}

	if err := h.deleteUC.SoftDelete(ctx, id); err != nil {
		span.RecordError(err)
		h.tel.recordError(ctx, opDeleteEntity)
		handleHTTPError(ctx, w, err)
		return
	}

	h.tel.recordSuccess(ctx, opDeleteEntity)
	writeJSON(ctx, w, http.StatusOK, map[string]string{
		"status":    "soft_deleted",
		"entity_id": id,
	})
}

func (h *EntityHTTPHandler) handleRestoreEntity(w http.ResponseWriter, r *http.Request) {
	ctx, span := h.tel.tracer.Start(r.Context(), "ports.EntityHTTPHandler.handleRestoreEntity")
	defer span.End()

	id := chi.URLParam(r, "id")
	if id == "" {
		writeJSON(ctx, w, http.StatusBadRequest, ErrorResponse{
			Code:    "MISSING_ID",
			Message: "entity id is required",
		})
		return
	}
	span.SetAttributes(attribute.String(attrEntityID, id))

	if err := h.deleteUC.Restore(ctx, id); err != nil {
		span.RecordError(err)
		h.tel.recordError(ctx, opRestoreEntity)
		handleHTTPError(ctx, w, err)
		return
	}

	h.tel.recordSuccess(ctx, opRestoreEntity)
	writeJSON(ctx, w, http.StatusOK, map[string]string{
		"status":    "restored",
		"entity_id": id,
	})
}

// --- Structural Helpers & Global Mappings ---

func writeJSON(ctx context.Context, w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", contentTypeJSON)
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Default().ErrorContext(ctx, "failed to encode JSON response", "error", err)
	}
}

func handleHTTPError(ctx context.Context, w http.ResponseWriter, err error) {
	code := http.StatusInternalServerError

	switch {
	case errors.Is(err, domain.ErrSchemaNotFound), errors.Is(err, domain.ErrEntityNotFound):
		code = http.StatusNotFound
	case errors.Is(err, domain.ErrInvalidSchema),
		errors.Is(err, domain.ErrUnsupportedFieldType),
		errors.Is(err, domain.ErrValidationFailed),
		errors.Is(err, domain.ErrInvalidEntity),
		errors.Is(err, domain.ErrMissingRequiredAttr),
		errors.Is(err, domain.ErrInvalidFilter),
		errors.Is(err, domain.ErrInvalidCursor),
		errors.Is(err, domain.ErrImmutableField),
		errors.Is(err, domain.ErrNotDeleted),
		errors.Is(err, domain.ErrInvalidStatusTransition):
		code = http.StatusBadRequest
	case errors.Is(err, domain.ErrSchemaAlreadyExists):
		code = http.StatusConflict
	case errors.Is(err, domain.ErrStaleVersion),
		errors.Is(err, domain.ErrConcurrentModification):
		code = http.StatusConflict
	}

	writeJSON(ctx, w, code, ErrorResponse{
		Code:    httpCodeToErrorCode(code),
		Message: unwrapErrorMessage(err),
	})
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
