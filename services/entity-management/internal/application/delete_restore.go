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

type DeleteRestoreDomainService interface {
	SoftDeleteEntity(ctx context.Context, id string) error
	HardDeleteEntity(ctx context.Context, id string) error
	PermanentDeleteEntity(ctx context.Context, id string) error
	RestoreEntity(ctx context.Context, id string) error
}

type DeleteRestoreUseCase struct {
	svc    DeleteRestoreDomainService
	logger *slog.Logger
	tracer trace.Tracer
}

func NewDeleteRestoreUseCase(svc DeleteRestoreDomainService, logger *slog.Logger) *DeleteRestoreUseCase {
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
		return err
	}

	span.SetAttributes(attribute.Bool("hard_deleted", true))
	return nil
}

// PermanentDelete permanently removes an entity from the database regardless
// of its soft-delete state. This is the backing method for the Gherkin spec
//
//	DELETE /api/v1/entities/{id}
//
// which returns 204 No Content on success or 404 Not Found when the entity
// does not exist.
func (uc *DeleteRestoreUseCase) PermanentDelete(ctx context.Context, id string) error {
	ctx, span := uc.tracer.Start(ctx, "application.DeleteRestoreUseCase.PermanentDelete",
		trace.WithAttributes(attribute.String("entity_id", id)))
	defer span.End()

	if err := uc.svc.PermanentDeleteEntity(ctx, id); err != nil {
		if errors.Is(err, domain.ErrEntityNotFound) {
			span.SetAttributes(attribute.Bool("found", false))
		}
		span.RecordError(err)
		return fmt.Errorf("permanent delete: %w", err)
	}

	span.SetAttributes(attribute.Bool("deleted", true))
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
