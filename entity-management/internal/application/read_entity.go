package application

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/domain"
)

type ReadEntityResponse struct {
	ID                string         `json:"id"`
	SchemaID          string         `json:"schema_id"`
	Name              string         `json:"name"`
	Type              string         `json:"type"`
	Region            string         `json:"region"`
	DataResidencyZone string         `json:"data_residency_zone"`
	Status            string         `json:"status"`
	Version           int            `json:"version"`
	Attributes        map[string]any `json:"attributes,omitempty"`
	Metadata          map[string]any `json:"metadata,omitempty"`
	CreatedAt         time.Time      `json:"created_at"`
	UpdatedAt         time.Time      `json:"updated_at"`
	DeletedAt         *time.Time     `json:"deleted_at,omitempty"`
}

type ReadEntityUseCase struct {
	entities domain.EntityRepository
	events   domain.EventPublisher
	logger   *slog.Logger
	tracer   trace.Tracer
}

func NewReadEntityUseCase(
	entities domain.EntityRepository,
	events domain.EventPublisher,
	logger *slog.Logger,
) *ReadEntityUseCase {
	return &ReadEntityUseCase{
		entities: entities,
		events:   events,
		logger:   logger.With("component", "ReadEntityUseCase"),
		tracer:   otel.Tracer(tracerName),
	}
}

func (uc *ReadEntityUseCase) Execute(ctx context.Context, id string) (*ReadEntityResponse, error) {
	ctx, span := uc.tracer.Start(ctx, "application.ReadEntityUseCase.Execute",
		trace.WithAttributes(attribute.String("entity_id", id)))
	defer span.End()

	entity, err := uc.entities.FindByID(ctx, id)
	if err != nil {
		if errors.Is(err, domain.ErrEntityNotFound) {
			span.SetAttributes(attribute.Bool("found", false))
			return nil, fmt.Errorf("read entity: %w", domain.ErrEntityNotFound)
		}
		span.RecordError(err)
		return nil, fmt.Errorf("read entity: %w", err)
	}

	span.SetAttributes(
		attribute.Bool("found", true),
		attribute.String("entity_status", string(entity.Status)),
		attribute.Int("entity_version", entity.Version),
	)

	readEvent := &domain.EntityRead{
		EventID:    uuid.New().String(),
		EntityID:   entity.ID,
		EntityName: entity.Name,
		Region:     entity.Region,
		ReadAt:     time.Now().UTC(),
	}
	if err := uc.events.PublishEntityRead(ctx, readEvent); err != nil {
		uc.logger.WarnContext(ctx, "failed to publish entity.read event (non-fatal)",
			"entity_id", entity.ID, "error", err)
		span.RecordError(err)
	}

	return entityToResponse(entity), nil
}

func entityToResponse(e *domain.Entity) *ReadEntityResponse {
	return &ReadEntityResponse{
		ID:                e.ID,
		SchemaID:          e.SchemaID,
		Name:              e.Name,
		Type:              e.Type,
		Region:            e.Region,
		DataResidencyZone: string(e.DataResidencyZone),
		Status:            string(e.Status),
		Version:           e.Version,
		Attributes:        e.Attributes,
		Metadata:          e.Metadata,
		CreatedAt:         e.CreatedAt,
		UpdatedAt:         e.UpdatedAt,
		DeletedAt:         e.DeletedAt,
	}
}
