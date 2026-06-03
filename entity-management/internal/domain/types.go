package domain

import (
	"context"
	"time"
)

// Error is a typed sentinel error for domain-level failures.
type Error string

func (e Error) Error() string { return string(e) }

const (
	ErrSchemaNotFound          Error = "entity schema not found"
	ErrSchemaAlreadyExists     Error = "entity schema already exists"
	ErrInvalidSchema           Error = "invalid entity schema definition"
	ErrEntityNotFound          Error = "entity not found"
	ErrInvalidEntity           Error = "invalid entity"
	ErrDuplicateEvent          Error = "duplicate event detected"
	ErrValidationFailed        Error = "schema validation failed"
	ErrMissingRequiredAttr     Error = "missing required attribute"
	ErrImmutableField          Error = "field is immutable after creation"
	ErrInvalidStatusTransition Error = "invalid status transition"
	ErrAlreadyDeleted          Error = "entity is already deleted"
	ErrNotDeleted              Error = "entity is not soft-deleted"
	ErrConcurrentModification  Error = "entity was modified concurrently"
	ErrStaleVersion            Error = "stale version: entity has been modified since last read"
	ErrUnsupportedFieldType    Error = "unsupported field type"
	ErrInvalidCursor           Error = "invalid pagination cursor"
	ErrInvalidFilter           Error = "invalid filter expression"
)

// AttributeType defines the supported data types for entity schema attributes.
type AttributeType string

const (
	AttributeTypeString AttributeType = "string"
	AttributeTypeEnum   AttributeType = "enum"
	AttributeTypeMap    AttributeType = "map"
	AttributeTypeInt    AttributeType = "int"
	AttributeTypeBool   AttributeType = "bool"
	AttributeTypeJSON   AttributeType = "json"
)

// Constraint holds optional validation rules applied to an attribute.
type Constraint struct {
	Enum    []string `json:"enum,omitempty"`
	Min     *int     `json:"min,omitempty"`
	Max     *int     `json:"max,omitempty"`
	Pattern string   `json:"pattern,omitempty"`
}

// AttributeDefinition describes a single field within an entity schema.
type AttributeDefinition struct {
	Name       string        `json:"name"`
	Type       AttributeType `json:"type"`
	Required   bool          `json:"required"`
	Constraint *Constraint   `json:"constraint,omitempty"`
}

// EntitySchema defines the structure of a type of entity. It is the aggregate
// root for schema definition operations.
type EntitySchema struct {
	ID         string                `json:"id"`
	Name       string                `json:"name"`
	Version    int                   `json:"version"`
	Attributes []AttributeDefinition `json:"attributes"`
	CreatedAt  time.Time             `json:"created_at"`
	UpdatedAt  time.Time             `json:"updated_at"`
}

// EntityStatus represents the lifecycle state of an entity.
type EntityStatus string

const (
	EntityStatusActive   EntityStatus = "active"
	EntityStatusInactive EntityStatus = "inactive"
	EntityStatusDeleted  EntityStatus = "deleted"
)

// ValidTransitions returns the set of statuses that can be transitioned to
// from the current status via a regular update operation.
func (s EntityStatus) ValidTransitions() []EntityStatus {
	switch s {
	case EntityStatusActive:
		return []EntityStatus{EntityStatusInactive, EntityStatusDeleted}
	case EntityStatusInactive:
		return []EntityStatus{EntityStatusActive, EntityStatusDeleted}
	case EntityStatusDeleted:
		return []EntityStatus{}
	default:
		return nil
	}
}

// IsDeleted reports whether the status represents a soft-deleted entity.
func (s EntityStatus) IsDeleted() bool { return s == EntityStatusDeleted }

// CanTransitionTo reports whether transitioning to the target status is valid.
func (s EntityStatus) CanTransitionTo(target EntityStatus) bool {
	for _, t := range s.ValidTransitions() {
		if t == target {
			return true
		}
	}
	return false
}

// DataResidencyZone represents the geographic boundary for entity data storage.
type DataResidencyZone string

const (
	ZoneUSEast1 DataResidencyZone = "us-east-1"
	ZoneEUWest1 DataResidencyZone = "eu-west-1"
)

// ResolveZone maps a cloud region to its data residency zone.
func ResolveZone(region string) DataResidencyZone {
	switch region {
	case "us-east-1", "us-west-2":
		return ZoneUSEast1
	case "eu-west-1", "eu-central-1":
		return ZoneEUWest1
	default:
		return DataResidencyZone(region)
	}
}

// ImmutableFields lists entity fields that cannot be changed after creation.
var ImmutableFields = []string{"id", "region", "data_residency_zone", "type", "created_at"}

// IsImmutableField reports whether the given top-level field name is immutable.
func IsImmutableField(field string) bool {
	for _, f := range ImmutableFields {
		if f == field {
			return true
		}
	}
	return false
}

// Entity is a concrete instance conforming to an EntitySchema.
type Entity struct {
	ID                string            `json:"id"`
	SchemaID          string            `json:"schema_id"`
	Name              string            `json:"name"`
	Type              string            `json:"type"`
	Region            string            `json:"region"`
	DataResidencyZone DataResidencyZone `json:"data_residency_zone"`
	Status            EntityStatus      `json:"status"`
	Version           int               `json:"version"`
	Attributes        map[string]any    `json:"attributes,omitempty"`
	Metadata          map[string]any    `json:"metadata,omitempty"`
	CreatedAt         time.Time         `json:"created_at"`
	UpdatedAt         time.Time         `json:"updated_at"`
	DeletedAt         *time.Time        `json:"deleted_at,omitempty"`
}

// MarkDeleted transitions the entity to the deleted state.
func (e *Entity) MarkDeleted(at time.Time) error {
	if e.Status.IsDeleted() {
		return ErrAlreadyDeleted
	}
	if !e.Status.CanTransitionTo(EntityStatusDeleted) {
		return ErrInvalidStatusTransition
	}
	e.Status = EntityStatusDeleted
	e.Version++
	e.UpdatedAt = at
	e.DeletedAt = &at
	return nil
}

// IsSoftDeleted returns true if the entity's deleted_at field is set.
func (e *Entity) IsSoftDeleted() bool {
	return e.DeletedAt != nil
}

// ApplySoftDelete sets only the deleted_at timestamp without changing status.
func (e *Entity) ApplySoftDelete(at time.Time) {
	e.DeletedAt = &at
	e.UpdatedAt = at
}

// ApplyRestore clears the deleted_at timestamp, transitions status to active,
// and increments the version for optimistic concurrency tracking.
func (e *Entity) ApplyRestore(at time.Time) {
	e.DeletedAt = nil
	e.Status = EntityStatusActive
	e.Version++
	e.UpdatedAt = at
}

// UpdateOperation describes a partial update to an entity.
type UpdateOperation struct {
	ExpectedVersion int            `json:"expected_version"`
	Name            *string        `json:"name,omitempty"`
	Status          *EntityStatus  `json:"status,omitempty"`
	Region          *string        `json:"region,omitempty"`
	Attributes      map[string]any `json:"attributes,omitempty"`
	Metadata        map[string]any `json:"metadata,omitempty"`
}

// ValidateMutable checks that no immutable fields are being modified.
func (op UpdateOperation) ValidateMutable() error {
	if op.Region != nil {
		return ErrImmutableField
	}
	return nil
}

// CollectChangedFields computes the list of changed fields from the update
// operation using dot notation for nested attribute changes.
func (op UpdateOperation) CollectChangedFields() []string {
	var fields []string
	if op.Name != nil {
		fields = append(fields, "name")
	}
	if op.Status != nil {
		fields = append(fields, "status")
	}
	if op.Region != nil {
		fields = append(fields, "region")
	}
	for attrKey := range op.Attributes {
		fields = append(fields, "attributes."+attrKey)
	}
	for metaKey := range op.Metadata {
		fields = append(fields, "metadata."+metaKey)
	}
	return fields
}

// ApplyUpdate validates the expected version and applies mutable field changes.
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
		if !e.Status.CanTransitionTo(*op.Status) {
			return ErrInvalidStatusTransition
		}
		e.Status = *op.Status
	}
	if op.Attributes != nil {
		for k, v := range op.Attributes {
			e.Attributes[k] = v
		}
	}
	if op.Metadata != nil {
		for k, v := range op.Metadata {
			e.Metadata[k] = v
		}
	}
	e.Version++
	e.UpdatedAt = time.Now().UTC()
	return nil
}

// --- Cursor-Based Pagination Types ---

// FilterOp is the comparison operator for a field filter.
type FilterOp string

const (
	FilterOpEqual       FilterOp = "=="
	FilterOpNotEqual    FilterOp = "!="
	FilterOpContains    FilterOp = "~"
	FilterOpGreaterThan FilterOp = ">"
	FilterOpLessThan    FilterOp = "<"
)

// Filter represents a single field-level filter expression.
type Filter struct {
	Field string   `json:"field"`
	Op    FilterOp `json:"op"`
	Value string   `json:"value"`
}

// ParseFilter parses a filter expression of the form "field==value".
func ParseFilter(expr string) (Filter, error) {
	ops := []FilterOp{FilterOpEqual, FilterOpNotEqual, FilterOpContains, FilterOpGreaterThan, FilterOpLessThan}
	for _, op := range ops {
		opStr := string(op)
		idx := findOpIndex(expr, opStr)
		if idx > 0 && idx < len(expr)-len(opStr) {
			return Filter{Field: expr[:idx], Op: op, Value: expr[idx+len(opStr):]}, nil
		}
	}
	return Filter{}, ErrInvalidFilter
}

func findOpIndex(s, op string) int {
	for i := 0; i <= len(s)-len(op); i++ {
		if s[i:i+len(op)] == op {
			return i
		}
	}
	return -1
}

// Cursor represents an opaque pagination cursor pointing to a specific entity.
type Cursor struct {
	CreatedAt time.Time `json:"created_at"`
	ID        string    `json:"id"`
}

// ListEntitiesParams encapsulates all parameters for listing entities with
// cursor-based pagination and multi-field filtering.
type ListEntitiesParams struct {
	SchemaID       string   `json:"schema_id"`
	Limit          int      `json:"limit"`
	Cursor         string   `json:"cursor,omitempty"`
	Filters        []Filter `json:"filters,omitempty"`
	IncludeDeleted bool     `json:"include_deleted,omitempty"`
}

// PaginatedResult holds the result of a paginated entity listing.
type PaginatedResult struct {
	Entities   []*Entity `json:"entities"`
	NextCursor string    `json:"next_cursor,omitempty"`
	TotalCount int       `json:"total_count"`
}

// --- Domain Events ---

// DomainEvent is a marker interface for all domain events.
type DomainEvent interface {
	EventName() string
}

// EntitySchemaDefined is published when a new entity schema is persisted.
type EntitySchemaDefined struct {
	EventID    string    `json:"event_id"`
	SchemaID   string    `json:"schema_id"`
	SchemaName string    `json:"schema_name"`
	Version    int       `json:"version"`
	OccurredAt time.Time `json:"occurred_at"`
}

func (e *EntitySchemaDefined) EventName() string { return "entity.schema.defined" }

// EntitySchemaUpdated is published when a schema's attributes or version change.
type EntitySchemaUpdated struct {
	EventID     string    `json:"event_id"`
	SchemaID    string    `json:"schema_id"`
	SchemaName  string    `json:"schema_name"`
	PreviousVer int       `json:"previous_version"`
	NewVersion  int       `json:"new_version"`
	OccurredAt  time.Time `json:"occurred_at"`
}

func (e *EntitySchemaUpdated) EventName() string { return "entity.schema.updated" }

// EntityCreated is published when a new entity is created.
type EntityCreated struct {
	EventID    string    `json:"event_id"`
	EntityID   string    `json:"entity_id"`
	EntityName string    `json:"entity_name"`
	EntityType string    `json:"entity_type"`
	Region     string    `json:"region"`
	OccurredAt time.Time `json:"occurred_at"`
}

func (e *EntityCreated) EventName() string { return "entity.created" }

// EntityUpdated is published when an existing entity's fields change.
type EntityUpdated struct {
	EventID         string       `json:"event_id"`
	EntityID        string       `json:"entity_id"`
	EntityName      string       `json:"entity_name"`
	Status          EntityStatus `json:"status"`
	Region          string       `json:"region"`
	PreviousVersion int          `json:"previous_version"`
	NewVersion      int          `json:"new_version"`
	ChangedFields   []string     `json:"changed_fields"`
	OccurredAt      time.Time    `json:"occurred_at"`
}

func (e *EntityUpdated) EventName() string { return "entity.updated" }

// EntityDeleted is published when an entity is soft-deleted.
type EntityDeleted struct {
	EventID    string    `json:"event_id"`
	EntityID   string    `json:"entity_id"`
	EntityName string    `json:"entity_name"`
	Region     string    `json:"region"`
	DeletedAt  time.Time `json:"deleted_at"`
	OccurredAt time.Time `json:"occurred_at"`
}

func (e *EntityDeleted) EventName() string { return "entity.deleted" }

// EntityRead is published when an entity is read/retrieved (observability event).
type EntityRead struct {
	EventID    string    `json:"event_id"`
	EntityID   string    `json:"entity_id"`
	EntityName string    `json:"entity_name"`
	Region     string    `json:"region"`
	ReadAt     time.Time `json:"read_at"`
}

func (e *EntityRead) EventName() string { return "entity.read" }

// --- Delete/Restore Domain Events ---

// EntitySoftDeleted is published when an entity is soft-deleted (deleted_at set).
type EntitySoftDeleted struct {
	EventID    string    `json:"event_id"`
	EntityID   string    `json:"entity_id"`
	EntityName string    `json:"entity_name"`
	Region     string    `json:"region"`
	DeletedAt  time.Time `json:"deleted_at"`
	OccurredAt time.Time `json:"occurred_at"`
}

func (e *EntitySoftDeleted) EventName() string { return "entity.soft_deleted" }

// EntityHardDeleted is published when an entity is permanently removed.
type EntityHardDeleted struct {
	EventID    string    `json:"event_id"`
	EntityID   string    `json:"entity_id"`
	EntityName string    `json:"entity_name"`
	Region     string    `json:"region"`
	DeletedAt  time.Time `json:"deleted_at"`
	OccurredAt time.Time `json:"occurred_at"`
}

func (e *EntityHardDeleted) EventName() string { return "entity.hard_deleted" }

// EntityRestored is published when a soft-deleted entity is restored.
type EntityRestored struct {
	EventID    string    `json:"event_id"`
	EntityID   string    `json:"entity_id"`
	EntityName string    `json:"entity_name"`
	Region     string    `json:"region"`
	Status     string    `json:"status"`
	OccurredAt time.Time `json:"occurred_at"`
}

func (e *EntityRestored) EventName() string { return "entity.restored" }

// --- ENTITYMGMT-09: Pagination / Query Events ---

// EntitiesQueried is published when a paginated list query is executed successfully.
type EntitiesQueried struct {
	EventID        string    `json:"event_id"`
	SchemaID       string    `json:"schema_id"`
	Limit          int       `json:"limit"`
	FiltersApplied []string  `json:"filters_applied"`
	HasCursor      bool      `json:"has_cursor"`
	HasNextPage    bool      `json:"has_next_page"`
	TotalCount     int       `json:"total_count"`
	DurationMs     int       `json:"duration_ms"`
	OccurredAt     time.Time `json:"occurred_at"`
}

func (e *EntitiesQueried) EventName() string { return "entities.queried" }

// InvalidCursorProvided is published when an invalid, expired, or tampered
// cursor token is provided.
type InvalidCursorProvided struct {
	EventID        string    `json:"event_id"`
	ProvidedCursor string    `json:"provided_cursor"`
	SchemaID       string    `json:"schema_id"`
	ErrorDetail    string    `json:"error_detail"`
	RequestOrigin  string    `json:"request_origin"`
	OccurredAt     time.Time `json:"occurred_at"`
}

func (e *InvalidCursorProvided) EventName() string { return "invalid_cursor" }

// --- ENTITYMGMT-12: App Lifecycle Events ---

// AppStarted is published when the application completes initialization
// and is ready to serve traffic.
type AppStarted struct {
	EventID           string    `json:"event_id"`
	ServiceName       string    `json:"service_name"`
	ServiceVersion    string    `json:"version"`
	Region            string    `json:"region"`
	MigrationID       string    `json:"migration_id"`
	MigrationVersion  int       `json:"migration_version"`
	Hostname          string    `json:"hostname"`
	PID               int       `json:"pid"`
	DeploymentID      string    `json:"deployment_id,omitempty"`
	StartupDurationMs int       `json:"startup_duration_ms,omitempty"`
	UptimeSeconds     float64   `json:"uptime_seconds"`
	StartedAt         time.Time `json:"started_at"`
}

func (e *AppStarted) EventName() string { return "app.started" }

// AppStartupFailed is published when the application fails to initialize.
type AppStartupFailed struct {
	EventID        string    `json:"event_id"`
	ServiceName    string    `json:"service_name"`
	ServiceVersion string    `json:"service_version,omitempty"`
	Region         string    `json:"region,omitempty"`
	Error          string    `json:"error"`
	Stage          string    `json:"stage"`
	Hostname       string    `json:"hostname,omitempty"`
	PID            int       `json:"pid,omitempty"`
	OccurredAt     time.Time `json:"occurred_at"`
}

func (e *AppStartupFailed) EventName() string { return "app.startup_failed" }

// --- Outbox ---

// OutboxStatus tracks the delivery state of a pending event.
type OutboxStatus string

const (
	OutboxStatusPending   OutboxStatus = "pending"
	OutboxStatusPublished OutboxStatus = "published"
	OutboxStatusFailed    OutboxStatus = "failed"
)

// OutboxEvent represents a domain event queued for publication via the
// transactional outbox pattern.
type OutboxEvent struct {
	ID            string       `json:"id"`
	AggregateID   string       `json:"aggregate_id"`
	AggregateType string       `json:"aggregate_type"`
	EventType     string       `json:"event_type"`
	Payload       []byte       `json:"payload"`
	Status        OutboxStatus `json:"status"`
	RetryCount    int          `json:"retry_count"`
	CreatedAt     time.Time    `json:"created_at"`
}

// IdempotencyKey identifies an event for deduplication.
type IdempotencyKey struct {
	EventID  string
	EntityID string
}

// IdempotencyRecord tracks whether an event has already been processed.
type IdempotencyRecord struct {
	Key       IdempotencyKey
	CreatedAt time.Time
	ExpiresAt time.Time
}

// EntityFilter specifies filtering and pagination parameters for listing entities.
// Deprecated: Use ListEntitiesParams with cursor-based pagination instead.
type EntityFilter struct {
	Status *EntityStatus      `json:"status,omitempty"`
	Region *string            `json:"region,omitempty"`
	Zone   *DataResidencyZone `json:"zone,omitempty"`
	Limit  int                `json:"limit"`
	Offset int                `json:"offset"`
}

// DefineSchemaInput is the domain input for defining a new schema.
type DefineSchemaInput struct {
	Name       string                `json:"name"`
	Attributes []AttributeDefinition `json:"attributes"`
}

// Validate checks the input against domain rules.
func (i *DefineSchemaInput) Validate() error {
	if i.Name == "" {
		return ErrInvalidSchema
	}
	if len(i.Attributes) == 0 {
		return ErrInvalidSchema
	}
	for _, attr := range i.Attributes {
		if attr.Name == "" {
			return ErrInvalidSchema
		}
		switch attr.Type {
		case AttributeTypeString, AttributeTypeEnum, AttributeTypeMap,
			AttributeTypeInt, AttributeTypeBool, AttributeTypeJSON:
		default:
			return ErrUnsupportedFieldType
		}
	}
	return nil
}

// --- Port Interfaces (consumer-defined, Hexagonal Architecture) ---

// SchemaRepository defines the storage contract for entity schemas.
type SchemaRepository interface {
	Save(ctx context.Context, schema *EntitySchema) error
	FindByID(ctx context.Context, id string) (*EntitySchema, error)
	FindByName(ctx context.Context, name string) (*EntitySchema, error)
	FindAll(ctx context.Context) ([]*EntitySchema, error)
	Delete(ctx context.Context, id string) error
}

// EntityRepository defines the storage contract for entity instances.
type EntityRepository interface {
	Save(ctx context.Context, entity *Entity) error
	FindByID(ctx context.Context, id string) (*Entity, error)
	Update(ctx context.Context, id string, op UpdateOperation) (*Entity, error)
	UpdateStatus(ctx context.Context, id string, status EntityStatus) error
	FindBySchemaID(ctx context.Context, schemaID string) ([]*Entity, error)
	List(ctx context.Context, filter EntityFilter) ([]*Entity, error)
	SoftDelete(ctx context.Context, id string, deletedAt time.Time) error
	Restore(ctx context.Context, id string) error
	HardDelete(ctx context.Context, id string) error
	ListEntities(ctx context.Context, params ListEntitiesParams) (*PaginatedResult, error)
}

// EventPublisher publishes domain events via the transactional outbox.
type EventPublisher interface {
	PublishSchemaDefined(ctx context.Context, event *EntitySchemaDefined) error
	PublishSchemaUpdated(ctx context.Context, event *EntitySchemaUpdated) error
	PublishEntityCreated(ctx context.Context, event *EntityCreated) error
	PublishEntityUpdated(ctx context.Context, event *EntityUpdated) error
	PublishEntityDeleted(ctx context.Context, event *EntityDeleted) error
	PublishEntityRead(ctx context.Context, event *EntityRead) error
	PublishEntitySoftDeleted(ctx context.Context, event *EntitySoftDeleted) error
	PublishEntityHardDeleted(ctx context.Context, event *EntityHardDeleted) error
	PublishEntityRestored(ctx context.Context, event *EntityRestored) error
	PublishEntitiesQueried(ctx context.Context, event *EntitiesQueried) error
	PublishInvalidCursorProvided(ctx context.Context, event *InvalidCursorProvided) error
	PublishAppStarted(ctx context.Context, event *AppStarted) error
	PublishAppStartupFailed(ctx context.Context, event *AppStartupFailed) error
}

// OutboxRepository defines storage for outbound events awaiting dispatch.
type OutboxRepository interface {
	Save(ctx context.Context, event *OutboxEvent) error
	MarkPublished(ctx context.Context, id string) error
	MarkFailed(ctx context.Context, id string, err error) error
	FetchPending(ctx context.Context, limit int) ([]*OutboxEvent, error)
}

// IdempotencyStore provides idempotent event processing guarantees.
type IdempotencyStore interface {
	IsDuplicate(ctx context.Context, key IdempotencyKey) (bool, error)
	MarkProcessed(ctx context.Context, key IdempotencyKey) error
	CleanExpired(ctx context.Context) (int, error)
}

// SchemaValidator compiles and caches validation rules for entity schemas.
type SchemaValidator interface {
	Validate(ctx context.Context, schemaID string, attrs map[string]any) error
	CompileSchema(ctx context.Context, schema *EntitySchema) error
	Invalidate(ctx context.Context, schemaID string) error
}
