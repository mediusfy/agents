package domain

import (
	"time"
)

// Status represents the lifecycle state of an entity.
type Status string

const (
	StatusActive  Status = "active"
	StatusDeleted Status = "deleted"
)

// Entity is the core domain aggregate for entity management.
type Entity struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	Status    Status     `json:"status"`
	DeletedAt *time.Time `json:"deleted_at,omitempty"`
	CreatedAt time.Time  `json:"created_at"`
	UpdatedAt time.Time  `json:"updated_at"`
}

// IsSoftDeleted returns true when the entity has been soft-deleted.
func (e *Entity) IsSoftDeleted() bool {
	return e.Status == StatusDeleted && e.DeletedAt != nil
}

// Error is a typed sentinel for domain errors.
type Error string

func (e Error) Error() string { return string(e) }

const (
	ErrNotFound   Error = "entity not found"
	ErrNotDeleted Error = "entity must be soft-deleted before hard deletion"
)
