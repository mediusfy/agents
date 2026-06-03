package ports

import (
	"context"
	"fmt"
	"time"
)

type CloudEventAttributes struct {
	SpecVersion     string            `json:"specversion"`
	Type            string            `json:"type"`
	Source          string            `json:"source"`
	ID              string            `json:"id"`
	Time            time.Time         `json:"time"`
	DataContentType string            `json:"datacontenttype"`
	Subject         string            `json:"subject,omitempty"`
	Extensions      map[string]string `json:"extensions,omitempty"`
}

type Envelope struct {
	CloudEventAttributes
	Data []byte `json:"data"`
}

func NewEntityCreatedEnvelope(eventID, entityID, entityName, entityType, region string, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.created",
			Source:          "/entity-manager",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         entityID,
			Extensions: map[string]string{
				"entityname": entityName,
				"entitytype": entityType,
				"region":     region,
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"entity_id":"%s","entity_name":"%s","entity_type":"%s","region":"%s"}`,
			entityID, entityName, entityType, region,
		)),
	}
}

func NewEntitySoftDeletedEnvelope(eventID, entityID, entityName, region string, deletedAt, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.soft_deleted",
			Source:          "/entity-manager",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         entityID,
			Extensions: map[string]string{
				"entityname": entityName,
				"region":     region,
				"deleted_at": deletedAt.Format(time.RFC3339Nano),
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"entity_id":"%s","entity_name":"%s","region":"%s","deleted_at":"%s"}`,
			entityID, entityName, region, deletedAt.Format(time.RFC3339Nano),
		)),
	}
}

func NewEntityHardDeletedEnvelope(eventID, entityID, entityName, region string, deletedAt, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.hard_deleted",
			Source:          "/entity-manager",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         entityID,
			Extensions: map[string]string{
				"entityname": entityName,
				"region":     region,
				"deleted_at": deletedAt.Format(time.RFC3339Nano),
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"entity_id":"%s","entity_name":"%s","region":"%s","deleted_at":"%s"}`,
			entityID, entityName, region, deletedAt.Format(time.RFC3339Nano),
		)),
	}
}

func NewEntityRestoredEnvelope(eventID, entityID, entityName, region string, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.entity.restored",
			Source:          "/entity-manager",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         entityID,
			Extensions: map[string]string{
				"entityname": entityName,
				"region":     region,
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"entity_id":"%s","entity_name":"%s","region":"%s"}`,
			entityID, entityName, region,
		)),
	}
}

func NewEntitySchemaDefinedEnvelope(eventID, schemaID, schemaName string, version int, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.schema.defined",
			Source:          "/entity-manager",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         schemaID,
			Extensions: map[string]string{
				"schemaname": schemaName,
				"version":    fmt.Sprintf("%d", version),
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"schema_id":"%s","schema_name":"%s","version":%d}`,
			schemaID, schemaName, version,
		)),
	}
}

func NewEntitySchemaUpdatedEnvelope(eventID, schemaID, schemaName string, prevVer, newVer int, occurredAt time.Time) *Envelope {
	return &Envelope{
		CloudEventAttributes: CloudEventAttributes{
			SpecVersion:     "1.0",
			Type:            "entitymanagement.schema.updated",
			Source:          "/entity-manager",
			ID:              eventID,
			Time:            occurredAt,
			DataContentType: "application/json",
			Subject:         schemaID,
			Extensions: map[string]string{
				"schemaname":      schemaName,
				"previousversion": fmt.Sprintf("%d", prevVer),
				"newversion":      fmt.Sprintf("%d", newVer),
			},
		},
		Data: []byte(fmt.Sprintf(
			`{"schema_id":"%s","schema_name":"%s","previous_version":%d,"new_version":%d}`,
			schemaID, schemaName, prevVer, newVer,
		)),
	}
}

type EventBus interface {
	Publish(ctx context.Context, subject string, envelope *Envelope) error
	Subscribe(ctx context.Context, subject string, handler EventHandler) error
	Close() error
}

type Disposition int

const (
	Ack Disposition = iota
	Retry
	BadRequest
)

type EventHandler func(ctx context.Context, data []byte) Disposition
