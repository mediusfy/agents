// Package domain defines the core entities, value objects, domain events,
// and repository interfaces for the Entity Management bounded context.
//
// This package has zero I/O dependencies and zero external SDK imports.
// It is the innermost layer of the Hexagonal Architecture.
package domain

import (
	"errors"
	"fmt"
	"time"
)

// ---------------------------------------------------------------------------
// Value Objects
// ---------------------------------------------------------------------------

// EntityID is a strongly-typed wrapper around a UUID identifying an entity.
type EntityID string

// EntityName is the human-readable name of an entity.
type EntityName string

// EntityType identifies the schema used to validate this entity (e.g. "ServiceComponent").
type EntityType string

// Region is an AWS/GCP/Azure region code (e.g. "us-east-1").
type Region string

// DataResidencyZone is the geopolitical zone derived from Region at write time.
// Examples: "US", "EU", "APAC", "ME".
type DataResidencyZone string

// EntityStatus represents the lifecycle state of an entity.
type EntityStatus string

const (
	EntityStatusActive  EntityStatus = "active"
	EntityStatusDeleted EntityStatus = "deleted"
	EntityStatusDormant EntityStatus = "dormant"
)

// SchemaDefinition is raw JSON Schema used to validate entity payloads.
type SchemaDefinition string

// ---------------------------------------------------------------------------
// sentinel domain errors
// ---------------------------------------------------------------------------

// Error is a typed domain error.
type Error string

func (e Error) Error() string { return string(e) }

const (
	ErrEntityNotFound         Error = "entity not found"
	ErrEntityAlreadyExists    Error = "entity already exists"
	ErrEntityNameRequired     Error = "entity name is required"
	ErrEntityTypeRequired     Error = "entity type is required"
	ErrRegionRequired         Error = "region is required"
	ErrInvalidEntityType      Error = "invalid entity type"
	ErrInvalidRegion          Error = "invalid region"
	ErrInvalidEntityStatus    Error = "invalid entity status"
	ErrSchemaNotFound         Error = "schema not found"
	ErrSchemaVersionConflict  Error = "schema version conflict"
	ErrValidationFailed       Error = "validation failed"
	ErrDuplicateEvent         Error = "duplicate event received"
	ErrDataResidencyMismatch  Error = "data residency zone mismatch"
	ErrConcurrentModification Error = "concurrent modification detected"
)

// DomainError wraps a sentinel with an operation label and optional cause.
type DomainError struct {
	Op    string
	ID    string
	Err   error
	Cause error
}

func (e *DomainError) Error() string {
	if e.Cause != nil {
		return fmt.Sprintf("domain: %s id=%s: %v: %v", e.Op, e.ID, e.Err, e.Cause)
	}
	return fmt.Sprintf("domain: %s id=%s: %v", e.Op, e.ID, e.Err)
}

func (e *DomainError) Unwrap() error { return e.Err }

// ---------------------------------------------------------------------------
// Core Entity Aggregate
// ---------------------------------------------------------------------------

// Entity is the aggregate root for the Entity Management bounded context.
// It carries a version field for optimistic concurrency control.
type Entity struct {
	ID               EntityID        `json:"id"`
	Name             EntityName      `json:"name"`
	Type             EntityType      `json:"entity_type"`
	Region           Region          `json:"region"`
	DataResidencyZone DataResidencyZone `json:"data_residency_zone"`
	Status           EntityStatus    `json:"status"`
	Version          int             `json:"version"`
	CreatedAt        time.Time       `json:"created_at"`
	UpdatedAt        time.Time       `json:"updated_at"`
}

// DeriveResidencyZone maps a region code to a geopolitical data residency zone.
// This implements the ADR-005 pattern: enforce_data_residency() at write time.
func DeriveResidencyZone(r Region) DataResidencyZone {
	switch {
	case r == "":
		return "UNKNOWN"
	case r == "us-east-1" || r == "us-east-2" || r == "us-west-1" || r == "us-west-2":
		return "US"
	case r == "eu-west-1" || r == "eu-west-2" || r == "eu-central-1" || r == "eu-north-1":
		return "EU"
	case r == "ap-southeast-1" || r == "ap-southeast-2" || r == "ap-northeast-1" || r == "ap-south-1":
		return "APAC"
	case r == "me-south-1" || r == "me-central-1":
		return "ME"
	default:
		return "OTHER"
	}
}

// AllowedRegions returns the set of regions currently supported by the platform.
func AllowedRegions() []Region {
	return []Region{
		"us-east-1", "us-east-2", "us-west-1", "us-west-2",
		"eu-west-1", "eu-west-2", "eu-central-1", "eu-north-1",
		"ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "ap-south-1",
		"me-south-1", "me-central-1",
	}
}

// ---------------------------------------------------------------------------
// Entity Schema
// ---------------------------------------------------------------------------

// EntitySchema defines the JSON Schema validation rules for a given entity type.
type EntitySchema struct {
	Type      EntityType      `json:"entity_type"`
	Version   int             `json:"version"`
	Schema    SchemaDefinition `json:"schema"`
	CreatedAt time.Time       `json:"created_at"`
	UpdatedAt time.Time       `json:"updated_at"`
}

// ---------------------------------------------------------------------------
// Domain Events
// ---------------------------------------------------------------------------

// EventMeta carries metadata common to every domain event.
type EventMeta struct {
	EventID     string    `json:"event_id"`
	EntityID    EntityID  `json:"entity_id"`
	OccurredAt  time.Time `json:"occurred_at"`
	EventType   string    `json:"event_type"`
	EventVersion int      `json:"event_version"`
}

// EntityCreated is the domain event emitted when a new entity is created.
// Its serialised form is validated against the versioned contract in SVCREG ACL.
// Contract fields: event_id, entity_id, entity_name, entity_type, region, occurred_at.
type EntityCreated struct {
	Meta       EventMeta  `json:"meta"`
	EntityName EntityName `json:"entity_name"`
	EntityType EntityType `json:"entity_type"`
	Region     Region     `json:"region"`
}

// EntitySchemaDefined is emitted when a new or updated entity schema is stored.
// This event invalidates the SchemaValidatorCache in the application layer.
type EntitySchemaDefined struct {
	Meta      EventMeta       `json:"meta"`
	Type      EntityType      `json:"entity_type"`
	Version   int             `json:"version"`
	Schema    SchemaDefinition `json:"schema"`
}

// EntityStatusChanged is emitted when an entity transitions between statuses.
type EntityStatusChanged struct {
	Meta   EventMeta    `json:"meta"`
	OldStatus EntityStatus `json:"old_status"`
	NewStatus EntityStatus `json:"new_status"`
}

// ---------------------------------------------------------------------------
// Outbox Record (Domain Model)
// ---------------------------------------------------------------------------

// OutboxEvent represents a pending event in the transactional outbox table
// (per ADR-002 pattern). The application writes to this within the same
// database transaction as the aggregate, then a relay process publishes
// to NATS JetStream.
type OutboxEvent struct {
	ID        int64     `json:"id"`
	Aggregate  string    `json:"aggregate"`  // e.g. "entity"
	AggregateID string  `json:"aggregate_id"` // the EntityID
	EventType  string    `json:"event_type"`
	Payload    []byte    `json:"payload"`    // CloudEvents JSON payload
	Status     string    `json:"status"`     // "pending" | "published" | "failed"
	CreatedAt  time.Time `json:"created_at"`
}

const (
	OutboxStatusPending   = "pending"
	OutboxStatusPublished = "published"
	OutboxStatusFailed    = "failed"
)

// ---------------------------------------------------------------------------
// Repository Ports (interfaces consumed by the application layer)
// ---------------------------------------------------------------------------

// EntityRepository is the storage port for the Entity aggregate.
// Implementations: postgres.EntityRepository, memory.EntityRepository (for tests).
type EntityRepository interface {
	// Save persists a new entity. Returns ErrEntityAlreadyExists on id conflict.
	Save(entity *Entity) error

	// Update performs an optimistic-concurrency update.
	// Returns ErrConcurrentModification if the version does not match.
	Update(entity *Entity) error

	// FindByID retrieves an entity by its ID. Returns ErrEntityNotFound if missing.
	FindByID(id EntityID) (*Entity, error)

	// FindByTypeAndRegion returns entities matching the given type and region,
	// optionally filtered by status.
	FindByTypeAndRegion(entityType EntityType, region Region, status *EntityStatus) ([]*Entity, error)

	// Delete performs a soft-delete by setting status to "deleted".
	Delete(id EntityID) error
}

// EntitySchemaRepository is the storage port for entity schemas.
type EntitySchemaRepository interface {
	// Save stores or updates a schema. Returns ErrSchemaVersionConflict if the
	// schema type exists with a higher version.
	Save(schema *EntitySchema) error

	// FindByType retrieves the latest version of a schema.
	FindByType(entityType EntityType) (*EntitySchema, error)

	// FindByTypeAndVersion retrieves a specific schema version.
	FindByTypeAndVersion(entityType EntityType, version int) (*EntitySchema, error)
}

// OutboxRepository is the storage port for the transactional outbox.
type OutboxRepository interface {
	// Insert appends an event to the outbox within the same transaction as the aggregate write.
	Insert(event *OutboxEvent) error

	// FetchPending retrieves up to limit pending events, ordered by created_at.
	FetchPending(limit int) ([]*OutboxEvent, error)

	// MarkPublished updates the status of an outbox event to "published".
	MarkPublished(id int64) error

	// MarkFailed updates the status of an outbox event to "failed".
	MarkFailed(id int64, cause error) error
}

// IdempotencyStore is the deduplication port.
// Deduplicates by (event_id, entity_id) with a 7-day TTL (per SVCREG-01 scenario 3).
type IdempotencyStore interface {
	// IsDuplicate returns true if the (eventID, entityID) pair has been seen within TTL.
	IsDuplicate(eventID string, entityID EntityID) (bool, error)

	// MarkSeen records the (eventID, entityID) pair for deduplication.
	MarkSeen(eventID string, entityID EntityID, ttl time.Duration) error
}

// ---------------------------------------------------------------------------
// Domain Service Interface (optional — defined when consumed)
// ---------------------------------------------------------------------------

// SchemaValidator validates entity payloads against a compiled JSON Schema.
// The implementation uses SchemaValidatorCache with sync.RWMutex.
type SchemaValidator interface {
	// Validate checks payload against the schema for the given entity type.
	// Returns ErrSchemaNotFound if no schema is registered.
	// Returns ErrValidationFailed with details if validation fails.
	Validate(entityType EntityType, payload []byte) error

	// Compile pre-compiles a schema for faster validation.
	Compile(schema *EntitySchema) error

	// Invalidate removes a cached schema, forcing a reload on next access.
	Invalidate(entityType EntityType)
}
