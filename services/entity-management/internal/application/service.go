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

const tracerName = "entity-management.application"

type SchemaService struct {
	schemas  domain.SchemaRepository
	outbox   domain.OutboxRepository
	uow      domain.UnitOfWork
	events   domain.EventPublisher
	valiator domain.SchemaValidator
	logger   *slog.Logger
	tracer   trace.Tracer
}

func NewSchemaService(
	schemas domain.SchemaRepository,
	outbox domain.OutboxRepository,
	uow domain.UnitOfWork,
	events domain.EventPublisher,
	valiator domain.SchemaValidator,
	logger *slog.Logger,
) *SchemaService {
	return &SchemaService{
		schemas:  schemas,
		outbox:   outbox,
		uow:      uow,
		events:   events,
		valiator: valiator,
		logger:   logger.With("component", "SchemaService"),
		tracer:   otel.Tracer(tracerName),
	}
}

type DefineSchemaResult struct {
	Schema      *domain.EntitySchema        `json:"schema"`
	Event       *domain.EntitySchemaDefined `json:"event,omitempty"`
	IsNewSchema bool                        `json:"is_new_schema"`
}

func (s *SchemaService) DefineSchema(ctx context.Context, input *domain.DefineSchemaInput) (*DefineSchemaResult, error) {
	ctx, span := s.tracer.Start(ctx, "application.SchemaService.DefineSchema",
		trace.WithAttributes(
			attribute.String("schema_name", input.Name),
			attribute.Int("attr_count", len(input.Attributes)),
		))
	defer span.End()

	if err := input.Validate(); err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("define schema: %w", err)
	}

	existing, err := s.schemas.FindByName(ctx, input.Name)
	if err != nil && !errors.Is(err, domain.ErrSchemaNotFound) {
		span.RecordError(err)
		return nil, fmt.Errorf("define schema: check existing: %w", err)
	}
	if existing != nil {
		err := domain.ErrSchemaAlreadyExists
		span.RecordError(err)
		return nil, fmt.Errorf("define schema: %w", err)
	}

	now := time.Now().UTC()
	schema := &domain.EntitySchema{
		ID:         uuid.New().String(),
		Name:       input.Name,
		Version:    1,
		Attributes: input.Attributes,
		CreatedAt:  now,
		UpdatedAt:  now,
	}

	eventID := uuid.New().String()
	outboxEvent := &domain.OutboxEvent{
		ID:            uuid.New().String(),
		AggregateID:   schema.ID,
		AggregateType: "entity_schema",
		EventType:     (&domain.EntitySchemaDefined{}).EventName(),
		Payload:       marshalSchemaDefinedPayload(eventID, schema),
		Status:        domain.OutboxStatusPending,
		CreatedAt:     now,
	}

	if err := s.uow.Execute(ctx, func(uowCtx context.Context) error {
		if err := s.schemas.Save(uowCtx, schema); err != nil {
			return fmt.Errorf("persist schema: %w", err)
		}
		if err := s.outbox.Save(uowCtx, outboxEvent); err != nil {
			return fmt.Errorf("persist outbox event: %w", err)
		}
		return nil
	}); err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("define schema: %w", err)
	}

	event := &domain.EntitySchemaDefined{
		EventID:    eventID,
		SchemaID:   schema.ID,
		SchemaName: schema.Name,
		Version:    schema.Version,
		OccurredAt: now,
	}
	if err := s.events.PublishSchemaDefined(ctx, event); err != nil {
		s.logger.ErrorContext(ctx, "failed to publish schema defined event", "event_id", eventID, "error", err)
		span.RecordError(err)
	}

	if err := s.valiator.CompileSchema(ctx, schema); err != nil {
		s.logger.ErrorContext(ctx, "failed to compile schema in cache", "error", err)
	}

	span.SetAttributes(
		attribute.String("schema_id", schema.ID),
		attribute.Int("schema_version", schema.Version),
	)

	return &DefineSchemaResult{
		Schema:      schema,
		Event:       event,
		IsNewSchema: true,
	}, nil
}

func (s *SchemaService) GetSchema(ctx context.Context, id string) (*domain.EntitySchema, error) {
	ctx, span := s.tracer.Start(ctx, "application.SchemaService.GetSchema",
		trace.WithAttributes(attribute.String("schema_id", id)))
	defer span.End()

	schema, err := s.schemas.FindByID(ctx, id)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("get schema: %w", err)
	}
	return schema, nil
}

func (s *SchemaService) ListSchemas(ctx context.Context) ([]*domain.EntitySchema, error) {
	ctx, span := s.tracer.Start(ctx, "application.SchemaService.ListSchemas")
	defer span.End()

	schemas, err := s.schemas.FindAll(ctx)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("list schemas: %w", err)
	}
	return schemas, nil
}

func marshalSchemaDefinedPayload(eventID string, schema *domain.EntitySchema) []byte {
	return []byte(fmt.Sprintf(
		`{"event_id":"%s","schema_id":"%s","schema_name":"%s","version":%d,"occurred_at":"%s"}`,
		eventID, schema.ID, schema.Name, schema.Version,
		schema.CreatedAt.Format(time.RFC3339Nano),
	))
}
