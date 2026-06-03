package application

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/domain"
)

type DeleteRestoreUseCase struct {
	svc    *domain.Service
	logger *slog.Logger
	tracer trace.Tracer
}

func NewDeleteRestoreUseCase(svc *domain.Service, logger *slog.Logger) *DeleteRestoreUseCase {
	return &DeleteRestoreUseCase{
		svc:    svc,
		logger: logger.With("component", "DeleteRestoreUseCase"),
		tracer: otel.Tracer(tracerName),
	}
}

func (uc *DeleteRestoreUseCase) SoftDelete(ctx context.Context, id string) error {
	ctx, span := uc.tracer.Start(ctx, "application.DeleteRestoreUseCase.SoftDelete",
		trace.WithAttributes(attribute.String("entity_id", id)))
	defer span.End()

	if err := uc.svc.SoftDeleteEntity(ctx, id); err != nil {
		if errors.Is(err, domain.ErrAlreadyDeleted) {
			span.SetAttributes(attribute.Bool("already_deleted", true))
		}
		span.RecordError(err)
		return fmt.Errorf("soft delete: %w", err)
	}

	span.SetAttributes(attribute.Bool("soft_deleted", true))
	return nil
}

func (uc *DeleteRestoreUseCase) HardDelete(ctx context.Context, id string) error {
	ctx, span := uc.tracer.Start(ctx, "application.DeleteRestoreUseCase.HardDelete",
		trace.WithAttributes(attribute.String("entity_id", id)))
	defer span.End()

	if err := uc.svc.HardDeleteEntity(ctx, id); err != nil {
		if errors.Is(err, domain.ErrNotDeleted) {
			span.SetAttributes(attribute.Bool("not_soft_deleted", true))
		}
		span.RecordError(err)
		return fmt.Errorf("hard delete: %w", err)
	}

	span.SetAttributes(attribute.Bool("hard_deleted", true))
	return nil
}

func (uc *DeleteRestoreUseCase) Restore(ctx context.Context, id string) error {
	ctx, span := uc.tracer.Start(ctx, "application.DeleteRestoreUseCase.Restore",
		trace.WithAttributes(attribute.String("entity_id", id)))
	defer span.End()

	if err := uc.svc.RestoreEntity(ctx, id); err != nil {
		if errors.Is(err, domain.ErrNotDeleted) {
			span.SetAttributes(attribute.Bool("not_soft_deleted", true))
		}
		span.RecordError(err)
		return fmt.Errorf("restore: %w", err)
	}

	span.SetAttributes(attribute.Bool("restored", true))
	return nil
}
