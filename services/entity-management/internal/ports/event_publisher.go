package ports

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"entity-management/internal/domain"
)

const publisherTracerName = "entity-management.ports.eventpublisher"

// EventPublisherAdapter implements domain.EventPublisher by translating
// domain events into CloudEvents envelopes and publishing them via EventBus.
type EventPublisherAdapter struct {
	bus    EventBus
	source string
	logger *slog.Logger
	tracer trace.Tracer
}

// NewEventPublisherAdapter creates a new EventPublisherAdapter.
func NewEventPublisherAdapter(bus EventBus, source string) *EventPublisherAdapter {
	return &EventPublisherAdapter{
		bus:    bus,
		source: source,
		logger: slog.Default().With("adapter", "EventPublisherAdapter"),
		tracer: otel.Tracer(publisherTracerName),
	}
}

func (a *EventPublisherAdapter) PublishSchemaDefined(ctx context.Context, event *domain.EntitySchemaDefined) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishSchemaDefined",
		trace.WithAttributes(attribute.String("schema_id", event.SchemaID)))
	defer span.End()

	env := NewEntitySchemaDefinedEnvelope(event.EventID, event.SchemaID, event.SchemaName, event.Version, event.OccurredAt)
	return a.publish(ctx, "entity.schema.defined", env)
}

func (a *EventPublisherAdapter) PublishSchemaUpdated(ctx context.Context, event *domain.EntitySchemaUpdated) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishSchemaUpdated",
		trace.WithAttributes(attribute.String("schema_id", event.SchemaID)))
	defer span.End()

	env := NewEntitySchemaUpdatedEnvelope(event.EventID, event.SchemaID, event.SchemaName, event.PreviousVer, event.NewVersion, event.OccurredAt)
	return a.publish(ctx, "entity.schema.updated", env)
}

func (a *EventPublisherAdapter) PublishEntityCreated(ctx context.Context, event *domain.EntityCreated) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishEntityCreated",
		trace.WithAttributes(attribute.String("entity_id", event.EntityID)))
	defer span.End()

	env := NewEntityCreatedEnvelope(event.EventID, event.EntityID, event.EntityName, event.EntityType, event.Region, event.OccurredAt)
	return a.publish(ctx, "entity.created", env)
}

func (a *EventPublisherAdapter) PublishEntityUpdated(ctx context.Context, event *domain.EntityUpdated) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishEntityUpdated",
		trace.WithAttributes(
			attribute.String("entity_id", event.EntityID),
			attribute.Int("previous_version", event.PreviousVersion),
			attribute.Int("new_version", event.NewVersion),
		))
	defer span.End()

	env := &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.updated",
			Source:          "/" + a.source,
			ID:              event.EventID,
			Time:            event.OccurredAt,
			DataContentType: "application/json",
			Subject:         event.EntityID,
			Extensions: map[string]string{
				"entityname":      event.EntityName,
				"status":          string(event.Status),
				"region":          event.Region,
				"previousversion": fmt.Sprintf("%d", event.PreviousVersion),
				"newversion":      fmt.Sprintf("%d", event.NewVersion),
				"changed_fields":  fmt.Sprintf("%v", event.ChangedFields),
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"entity_id":"%s","entity_name":"%s","status":"%s","region":"%s","previous_version":%d,"new_version":%d}`,
			event.EntityID, event.EntityName, event.Status, event.Region,
			event.PreviousVersion, event.NewVersion,
		)),
	}
	return a.publish(ctx, "entity.updated", env)
}

func (a *EventPublisherAdapter) PublishEntityDeleted(ctx context.Context, event *domain.EntityDeleted) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishEntityDeleted",
		trace.WithAttributes(attribute.String("entity_id", event.EntityID)))
	defer span.End()

	env := &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.deleted",
			Source:          "/" + a.source,
			ID:              event.EventID,
			Time:            event.OccurredAt,
			DataContentType: "application/json",
			Subject:         event.EntityID,
			Extensions: map[string]string{
				"entityname": event.EntityName,
				"region":     event.Region,
				"deleted_at": event.DeletedAt.Format(time.RFC3339Nano),
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"entity_id":"%s","entity_name":"%s","region":"%s","deleted_at":"%s"}`,
			event.EntityID, event.EntityName, event.Region, event.DeletedAt.Format(time.RFC3339Nano),
		)),
	}
	return a.publish(ctx, "entity.deleted", env)
}

func (a *EventPublisherAdapter) PublishEntityRead(ctx context.Context, event *domain.EntityRead) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishEntityRead",
		trace.WithAttributes(attribute.String("entity_id", event.EntityID)))
	defer span.End()

	env := &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.read",
			Source:          "/" + a.source,
			ID:              event.EventID,
			Time:            event.ReadAt,
			DataContentType: "application/json",
			Subject:         event.EntityID,
			Extensions: map[string]string{
				"entityname": event.EntityName,
				"region":     event.Region,
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"entity_id":"%s","entity_name":"%s","region":"%s","read_at":"%s"}`,
			event.EntityID, event.EntityName, event.Region, event.ReadAt.Format(time.RFC3339Nano),
		)),
	}
	return a.publish(ctx, "entity.read", env)
}

func (a *EventPublisherAdapter) PublishEntitySoftDeleted(ctx context.Context, event *domain.EntitySoftDeleted) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishEntitySoftDeleted",
		trace.WithAttributes(attribute.String("entity_id", event.EntityID)))
	defer span.End()

	env := NewEntitySoftDeletedEnvelope(event.EventID, event.EntityID, event.EntityName, event.Region, event.DeletedAt, event.OccurredAt)
	return a.publish(ctx, "entity.soft_deleted", env)
}

func (a *EventPublisherAdapter) PublishEntityHardDeleted(ctx context.Context, event *domain.EntityHardDeleted) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishEntityHardDeleted",
		trace.WithAttributes(attribute.String("entity_id", event.EntityID)))
	defer span.End()

	env := NewEntityHardDeletedEnvelope(event.EventID, event.EntityID, event.EntityName, event.Region, event.DeletedAt, event.OccurredAt)
	return a.publish(ctx, "entity.hard_deleted", env)
}

func (a *EventPublisherAdapter) PublishEntityRestored(ctx context.Context, event *domain.EntityRestored) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishEntityRestored",
		trace.WithAttributes(attribute.String("entity_id", event.EntityID)))
	defer span.End()

	env := NewEntityRestoredEnvelope(event.EventID, event.EntityID, event.EntityName, event.Region, event.OccurredAt)
	return a.publish(ctx, "entity.restored", env)
}

func (a *EventPublisherAdapter) PublishEntitiesQueried(ctx context.Context, event *domain.EntitiesQueried) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishEntitiesQueried",
		trace.WithAttributes(
			attribute.String("schema_id", event.SchemaID),
			attribute.Int("limit", event.Limit),
			attribute.Int("filter_count", len(event.FiltersApplied)),
			attribute.Bool("has_cursor", event.HasCursor),
			attribute.Bool("has_next_page", event.HasNextPage),
			attribute.Int("total_count", event.TotalCount),
			attribute.Int("duration_ms", event.DurationMs),
		))
	defer span.End()

	env := &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entities.queried",
			Source:          "/" + a.source,
			ID:              event.EventID,
			Time:            event.OccurredAt,
			DataContentType: "application/json",
			Subject:         "schema/" + event.SchemaID + "/entities",
			Extensions: map[string]string{
				"schema_id":     event.SchemaID,
				"limit":         fmt.Sprintf("%d", event.Limit),
				"has_cursor":    fmt.Sprintf("%t", event.HasCursor),
				"has_next_page": fmt.Sprintf("%t", event.HasNextPage),
				"total_count":   fmt.Sprintf("%d", event.TotalCount),
				"duration_ms":   fmt.Sprintf("%d", event.DurationMs),
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"event_id":"%s","schema_id":"%s","limit":%d,"filters_applied":%q,"has_cursor":%t,"has_next_page":%t,"total_count":%d,"duration_ms":%d}`,
			event.EventID, event.SchemaID, event.Limit, event.FiltersApplied,
			event.HasCursor, event.HasNextPage, event.TotalCount, event.DurationMs,
		)),
	}

	return a.publish(ctx, "entities.queried", env)
}

func (a *EventPublisherAdapter) PublishInvalidCursorProvided(ctx context.Context, event *domain.InvalidCursorProvided) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishInvalidCursorProvided",
		trace.WithAttributes(
			attribute.String("schema_id", event.SchemaID),
			attribute.String("error_detail", event.ErrorDetail),
			attribute.String("request_origin", event.RequestOrigin),
		))
	defer span.End()

	env := &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.invalid_cursor",
			Source:          "/" + a.source,
			ID:              event.EventID,
			Time:            event.OccurredAt,
			DataContentType: "application/json",
			Subject:         "cursor/error",
			Extensions: map[string]string{
				"schema_id":       event.SchemaID,
				"provided_cursor": event.ProvidedCursor,
				"error_detail":    event.ErrorDetail,
				"request_origin":  event.RequestOrigin,
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"event_id":"%s","provided_cursor":"%s","schema_id":"%s","error_detail":"%s","request_origin":"%s"}`,
			event.EventID, event.ProvidedCursor, event.SchemaID,
			event.ErrorDetail, event.RequestOrigin,
		)),
	}

	return a.publish(ctx, "invalid_cursor", env)
}

func (a *EventPublisherAdapter) PublishAppStarted(ctx context.Context, event *domain.AppStarted) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishAppStarted",
		trace.WithAttributes(
			attribute.String("service_name", event.ServiceName),
			attribute.String("version", event.ServiceVersion),
			attribute.String("region", event.Region),
			attribute.Int("migration_version", event.MigrationVersion),
		))
	defer span.End()

	env := NewAppStartedEnvelope(event)
	return a.publish(ctx, "app.started", env)
}

func (a *EventPublisherAdapter) PublishAppStartupFailed(ctx context.Context, event *domain.AppStartupFailed) error {
	ctx, span := a.tracer.Start(ctx, "EventPublisherAdapter.PublishAppStartupFailed",
		trace.WithAttributes(
			attribute.String("service_name", event.ServiceName),
			attribute.String("stage", event.Stage),
			attribute.String("error", event.Error),
		))
	defer span.End()

	env := NewAppStartupFailedEnvelope(event)
	return a.publish(ctx, "app.startup_failed", env)
}

func (a *EventPublisherAdapter) publish(ctx context.Context, subject string, env *Envelope) error {
	if a.bus == nil {
		a.logger.WarnContext(ctx, "event bus is nil, dropping event", "subject", subject, "event_id", env.ID)
		return nil
	}
	return a.bus.Publish(ctx, subject, env)
}

// NewAppStartedEnvelope creates a CloudEvents envelope for an app.started event.
func NewAppStartedEnvelope(event *domain.AppStarted) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.app.started",
			Source:          "/" + event.ServiceName,
			ID:              event.EventID,
			Time:            event.StartedAt,
			DataContentType: "application/json",
			Subject:         "app/started/" + event.ServiceName,
			Extensions: map[string]string{
				"service_name":      event.ServiceName,
				"version":           event.ServiceVersion,
				"region":            event.Region,
				"migration_version": fmt.Sprintf("%d", event.MigrationVersion),
				"hostname":          event.Hostname,
				"pid":               fmt.Sprintf("%d", event.PID),
				"uptime_seconds":    fmt.Sprintf("%.2f", event.UptimeSeconds),
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"event_id":"%s","service_name":"%s","version":"%s","region":"%s","migration_id":"%s","migration_version":%d,"hostname":"%s","pid":%d,"startup_duration_ms":%d,"uptime_seconds":%.2f,"started_at":"%s"}`,
			event.EventID, event.ServiceName, event.ServiceVersion, event.Region,
			event.MigrationID, event.MigrationVersion, event.Hostname, event.PID,
			event.StartupDurationMs, event.UptimeSeconds,
			event.StartedAt.Format(time.RFC3339Nano),
		)),
	}
}

// NewAppStartupFailedEnvelope creates a CloudEvents envelope for an app.startup_failed event.
func NewAppStartupFailedEnvelope(event *domain.AppStartupFailed) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.app.startup_failed",
			Source:          "/" + event.ServiceName,
			ID:              event.EventID,
			Time:            event.OccurredAt,
			DataContentType: "application/json",
			Subject:         "app/startup_failed/" + event.ServiceName,
			Extensions: map[string]string{
				"service_name": event.ServiceName,
				"stage":        event.Stage,
				"error":        event.Error,
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"event_id":"%s","service_name":"%s","error":"%s","stage":"%s","service_version":"%s","region":"%s","hostname":"%s","pid":%d,"occurred_at":"%s"}`,
			event.EventID, event.ServiceName, event.Error, event.Stage,
			event.ServiceVersion, event.Region, event.Hostname, event.PID,
			event.OccurredAt.Format(time.RFC3339Nano),
		)),
	}
}

// compile-time check
var _ domain.EventPublisher = (*EventPublisherAdapter)(nil)

// NewEntitySchemaDefinedEnvelope creates a CloudEvents envelope for schema defined event.
func NewEntitySchemaDefinedEnvelope(eventID, schemaID, schemaName string, version int, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.schema.defined",
			Source:          "/entity-management",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         "schema/" + schemaID,
			Extensions: map[string]string{
				"schema_id": schemaID,
				"version":   fmt.Sprintf("%d", version),
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"event_id":"%s","schema_id":"%s","schema_name":"%s","version":%d,"occurred_at":"%s"}`,
			eventID, schemaID, schemaName, version, occurredAt.Format(time.RFC3339Nano),
		)),
	}
}

// NewEntitySchemaUpdatedEnvelope creates a CloudEvents envelope for schema updated event.
func NewEntitySchemaUpdatedEnvelope(eventID, schemaID, schemaName string, previousVer, newVersion int, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.schema.updated",
			Source:          "/entity-management",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         "schema/" + schemaID,
			Extensions: map[string]string{
				"schema_id":    schemaID,
				"new_version":  fmt.Sprintf("%d", newVersion),
				"previous_ver": fmt.Sprintf("%d", previousVer),
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"event_id":"%s","schema_id":"%s","schema_name":"%s","previous_version":%d,"new_version":%d,"occurred_at":"%s"}`,
			eventID, schemaID, schemaName, previousVer, newVersion, occurredAt.Format(time.RFC3339Nano),
		)),
	}
}

// NewEntityCreatedEnvelope creates a CloudEvents envelope for entity created event.
func NewEntityCreatedEnvelope(eventID, entityID, entityName, entityType, region string, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.created",
			Source:          "/entity-management",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         "entity/" + entityID,
			Extensions: map[string]string{
				"entity_id":   entityID,
				"entity_type": entityType,
				"region":      region,
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"event_id":"%s","entity_id":"%s","entity_name":"%s","entity_type":"%s","region":"%s","occurred_at":"%s"}`,
			eventID, entityID, entityName, entityType, region, occurredAt.Format(time.RFC3339Nano),
		)),
	}
}

// NewEntitySoftDeletedEnvelope creates a CloudEvents envelope for entity soft deleted event.
func NewEntitySoftDeletedEnvelope(eventID, entityID, entityName, region string, deletedAt time.Time, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.soft_deleted",
			Source:          "/entity-management",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         "entity/" + entityID,
			Extensions: map[string]string{
				"entity_id": entityID,
				"region":    region,
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"event_id":"%s","entity_id":"%s","entity_name":"%s","region":"%s","deleted_at":"%s","occurred_at":"%s"}`,
			eventID, entityID, entityName, region, deletedAt.Format(time.RFC3339Nano), occurredAt.Format(time.RFC3339Nano),
		)),
	}
}

// NewEntityHardDeletedEnvelope creates a CloudEvents envelope for entity hard deleted event.
func NewEntityHardDeletedEnvelope(eventID, entityID, entityName, region string, deletedAt time.Time, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.hard_deleted",
			Source:          "/entity-management",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         "entity/" + entityID,
			Extensions: map[string]string{
				"entity_id": entityID,
				"region":    region,
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"event_id":"%s","entity_id":"%s","entity_name":"%s","region":"%s","deleted_at":"%s","occurred_at":"%s"}`,
			eventID, entityID, entityName, region, deletedAt.Format(time.RFC3339Nano), occurredAt.Format(time.RFC3339Nano),
		)),
	}
}

// NewEntityRestoredEnvelope creates a CloudEvents envelope for entity restored event.
func NewEntityRestoredEnvelope(eventID, entityID, entityName, region string, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.restored",
			Source:          "/entity-management",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         "entity/" + entityID,
			Extensions: map[string]string{
				"entity_id": entityID,
				"region":    region,
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"event_id":"%s","entity_id":"%s","entity_name":"%s","region":"%s","occurred_at":"%s"}`,
			eventID, entityID, entityName, region, occurredAt.Format(time.RFC3339Nano),
		)),
	}
}
