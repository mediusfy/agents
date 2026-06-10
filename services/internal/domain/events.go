package domain

// EventSubject is a CloudEvents subject for domain events.
type EventSubject string

const (
	SubjectEntityCreated   EventSubject = "entity.entity.created"
	SubjectEntityUpdated   EventSubject = "entity.entity.updated"
	SubjectEntityRetrieved EventSubject = "entity.entity.retrieved"
)
