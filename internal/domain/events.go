package domain

// EventSubject is the CloudEvents subject for entity lifecycle events.
type EventSubject string

const (
	SubjectEntityHardDeleted EventSubject = "entitymanagement.entity.hard_deleted"
)

// EntityHardDeletedEvent is the domain event payload for hard-deletion.
type EntityHardDeletedEvent struct {
	EntityID string `json:"entity_id"`
}
