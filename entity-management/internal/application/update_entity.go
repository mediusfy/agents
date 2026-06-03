package application

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/domain"
)

type UpdateEntityRequest struct {
	EntityID        string         `json:"entity_id"`
	ExpectedVersion int            `json:"expected_version"`
	Name            *string        `json:"name,omitempty"`
	Status          *string        `json:"status,omitempty"`
	Region          *string        `json:"region,omitempty"`
	Attributes      map[string]any `json:"attributes,omitempty"`
	Metadata        map[string]any `json:"metadata,omitempty"`
}

type UpdateEntityResponse struct {
	ID                string            `json:"id"`
	SchemaID          string            `json:"schema_id"`
	Name              string            `json:"name"`
	Type              string            `json:"type"`
	Region            string            `json:"region"`
	DataResidencyZone string            `json:"data_residency_zone"`
	Status            string            `json:"status"`
	Version           int               `json:"version"`
	Attributes        map[string]any    `json:"attributes,omitempty"`
	Metadata          map[string]any    `json:"metadata,omitempty"`
	CreatedAt         time.Time         `json:"created_at"`
	UpdatedAt         time.Time         `json:"updated_at"`
	DeletedAt         *time.Time        `json:"deleted_at,omitempty"`
}

type UpdateEntityUseCase struct {
	svc    *domain.Service
	logger *slog.Logger
	tracer trace.Tracer
}

func NewUpdateEntityUseCase(svc *domain.Service, logger *slog.Logger) *UpdateEntityUseCase {
	return &UpdateEntityUseCase{
		svc:    svc,
		logger: logger.With("component", "UpdateEntityUseCase"),
		tracer: otel.Tracer(tracerName),
	}
}

func (uc *UpdateEntityUseCase) Execute(ctx context.Context, req UpdateEntityRequest) (*UpdateEntityResponse, error) {
	ctx, span := uc.tracer.Start(ctx, "application.UpdateEntityUseCase.Execute",
		trace.WithAttributes(
			attribute.String("entity_id", req.EntityID),
			attribute.Int("expected_version", req.ExpectedVersion),
		))
	defer span.End()

	var statusPtr *domain.EntityStatus
	if req.Status != nil {
		s := domain.EntityStatus(*req.Status)
		statusPtr = &s
	}

	op := domain.UpdateOperation{
		ExpectedVersion: req.ExpectedVersion,
		Name:            req.Name,
		Status:          statusPtr,
		Region:          req.Region,
		Attributes:      req.Attributes,
		Metadata:        req.Metadata,
	}

	entity, err := uc.svc.UpdateEntity(ctx, req.EntityID, op)
	if err != nil {
		switch {
		case errors.Is(err, domain.ErrStaleVersion),
			errors.Is(err, domain.ErrConcurrentModification):
			span.SetAttributes(attribute.Bool("stale_version", true))
		case errors.Is(err, domain.ErrImmutableField):
			span.SetAttributes(attribute.Bool("immutable_field", true))
		}
		span.RecordError(err)
		return nil, fmt.Errorf("update entity: %w", err)
	}

	span.SetAttributes(
		attribute.Int("new_version", entity.Version),
		attribute.String("entity_status", string(entity.Status)),
	)

	return &UpdateEntityResponse{
		ID:                entity.ID,
		SchemaID:          entity.SchemaID,
		Name:              entity.Name,
		Type:              entity.Type,
		Region:            entity.Region,
		DataResidencyZone: string(entity.DataResidencyZone),
		Status:            string(entity.Status),
		Version:           entity.Version,
		Attributes:        entity.Attributes,
		Metadata:          entity.Metadata,
		CreatedAt:         entity.CreatedAt,
		UpdatedAt:         entity.UpdatedAt,
		DeletedAt:         entity.DeletedAt,
	}, nil
}
