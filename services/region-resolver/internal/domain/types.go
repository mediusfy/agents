// Package domain defines the core business entities, sentinel errors, and
// port interfaces for the region-resolver bounded context.
//
// In Hexagonal Architecture, interfaces are defined at the consumer site.
// Repository and publisher interfaces live here alongside the domain types.
package domain

import (
	"context"
	"time"

	"shared/residency"
)

// Error is a typed sentinel error for domain-level failures.
type Error string

func (e Error) Error() string { return string(e) }

const (
	ErrEntityNotFound         Error = "entity not found"
	ErrImmutableField         Error = "field is immutable after creation"
	ErrStaleVersion           Error = "stale version: entity has been modified since last read"
	ErrInvalidEntity          Error = "invalid entity"
	ErrDuplicateEvent         Error = "duplicate event detected"
	ErrInvalidStatus          Error = "invalid entity status"
	ErrConcurrentModification Error = "entity was modified concurrently"
)

// DataResidencyZone represents the geographic boundary for entity data storage.
type DataResidencyZone = residency.DataResidencyZone

const (
	ZoneUSEast1 = residency.ZoneUSEast1
	ZoneEUWest1 = residency.ZoneEUWest1
)

// ResolveZone maps a cloud region string to its corresponding data residency
// zone. If the region is unknown, it passes through as-is (default behaviour).
//
// Gherkin compliance:
//   - "eu-west-1" → "eu-west-1"
//   - "us-east-1" → "us-east-1"
//   - Unknown regions (e.g. "ap-southeast-1") are returned unchanged.
func ResolveZone(region string) DataResidencyZone {
	return residency.ResolveZone(region)
}

// ImmutableFields lists entity fields that MUST NOT change after creation.
// Any attempt to modify these fields via the update endpoint MUST be rejected
// with ErrImmutableField.
var ImmutableFields = []string{"id", "region", "data_residency_zone", "created_at"}

// IsImmutableField reports whether the given field name is immutable.
func IsImmutableField(field string) bool {
	for _, f := range ImmutableFields {
		if f == field {
			return true
		}
	}
	return false
}

// EntityStatus represents the lifecycle state of an entity.
type EntityStatus string

const (
	EntityStatusActive   EntityStatus = "active"
	EntityStatusInactive EntityStatus = "inactive"
)

// Entity is the core domain aggregate. Each entity carries an optimistic
// concurrency version that MUST be supplied on every update to detect
// concurrent modifications.
type Entity struct {
	ID                string            `json:"id"`
	Name              string            `json:"name"`
	Region            string            `json:"region"`
	DataResidencyZone DataResidencyZone `json:"data_residency_zone"`
	Status            EntityStatus      `json:"status"`
	Version           int               `json:"version"`
	Labels            map[string]string `json:"labels,omitempty"`
	CreatedAt         time.Time         `json:"created_at"`
	UpdatedAt         time.Time         `json:"updated_at"`
}

// UpdateOperation describes a partial update to an entity.
// ExpectedVersion is the optimistic concurrency lock: it must match the
// entity's current Version for the update to succeed.
type UpdateOperation struct {
	ExpectedVersion   int                `json:"expected_version"`
	Name              *string            `json:"name,omitempty"`
	Status            *EntityStatus      `json:"status,omitempty"`
	DataResidencyZone *DataResidencyZone `json:"data_residency_zone,omitempty"`
	Labels            map[string]string  `json:"labels,omitempty"`
}

// ValidateMutable checks that no immutable fields are being modified by this
// operation. Returns ErrImmutableField if any attempt is detected.
func (op UpdateOperation) ValidateMutable() error {
	if op.DataResidencyZone != nil {
		return ErrImmutableField
	}
	return nil
}

// CollectChangedFields computes the list of changed field names from the
// update operation.
func (op UpdateOperation) CollectChangedFields() []string {
	var fields []string
	if op.Name != nil {
		fields = append(fields, "name")
	}
	if op.Status != nil {
		fields = append(fields, "status")
	}
	if op.DataResidencyZone != nil {
		fields = append(fields, "data_residency_zone")
	}
	for k := range op.Labels {
		fields = append(fields, "labels."+k)
	}
	return fields
}

// ApplyUpdate validates the expected version and applies mutable field changes.
// Returns ErrStaleVersion or ErrImmutableField as appropriate.
func (e *Entity) ApplyUpdate(op UpdateOperation) error {
	if op.ExpectedVersion != e.Version {
		return ErrStaleVersion
	}
	if err := op.ValidateMutable(); err != nil {
		return err
	}
	if op.Name != nil {
		e.Name = *op.Name
	}
	if op.Status != nil {
		e.Status = *op.Status
	}
	if op.Labels != nil {
		if e.Labels == nil {
			e.Labels = make(map[string]string)
		}
		for k, v := range op.Labels {
			e.Labels[k] = v
		}
	}
	e.Version++
	e.UpdatedAt = time.Now().UTC()
	return nil
}

// --- Port Interfaces (consumer-defined per Hexagonal Architecture) ---

// EntityRepository defines the storage contract for entity instances.
type EntityRepository interface {
	Save(ctx context.Context, entity *Entity) error
	FindByID(ctx context.Context, id string) (*Entity, error)
	Update(ctx context.Context, entity *Entity) error
	List(ctx context.Context) ([]*Entity, error)
	Delete(ctx context.Context, id string) error
}

// EventPublisher publishes domain events after successful state changes.
type EventPublisher interface {
	PublishEntityCreated(ctx context.Context, event *EntityCreated) error
	PublishEntityUpdated(ctx context.Context, event *EntityUpdated) error
	PublishEntityDeleted(ctx context.Context, event *EntityDeleted) error
}

// --- Domain Events ---

// DomainEvent is a marker interface for all domain events.
type DomainEvent interface {
	EventName() string
}

// EntityCreated is published when a new entity is persisted.
type EntityCreated struct {
	EventID           string            `json:"event_id"`
	EntityID          string            `json:"entity_id"`
	EntityName        string            `json:"entity_name"`
	Region            string            `json:"region"`
	DataResidencyZone DataResidencyZone `json:"data_residency_zone"`
	OccurredAt        time.Time         `json:"occurred_at"`
}

func (e *EntityCreated) EventName() string { return "region.resolver.entity.created" }

// EntityUpdated is published when an entity's mutable fields change.
type EntityUpdated struct {
	EventID         string    `json:"event_id"`
	EntityID        string    `json:"entity_id"`
	EntityName      string    `json:"entity_name"`
	PreviousVersion int       `json:"previous_version"`
	NewVersion      int       `json:"new_version"`
	ChangedFields   []string  `json:"changed_fields"`
	OccurredAt      time.Time `json:"occurred_at"`
}

func (e *EntityUpdated) EventName() string { return "region.resolver.entity.updated" }

// EntityDeleted is published when an entity is deleted.
type EntityDeleted struct {
	EventID    string    `json:"event_id"`
	EntityID   string    `json:"entity_id"`
	EntityName string    `json:"entity_name"`
	Region     string    `json:"region"`
	OccurredAt time.Time `json:"occurred_at"`
}

func (e *EntityDeleted) EventName() string { return "region.resolver.entity.deleted" }
