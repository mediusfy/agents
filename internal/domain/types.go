package domain

import "time"

// Entity represents the core domain aggregate for a managed resource.
type Entity struct {
	ID        string
	Name      string
	Type      string
	Version   int
	Metadata  map[string]string
	CreatedAt time.Time
	UpdatedAt time.Time
}

// CreateEntityInput is the application-level command to create a new entity.
type CreateEntityInput struct {
	Name     string
	Type     string
	Metadata map[string]string
}

// UpdateEntityInput is the application-level command to update an existing entity.
type UpdateEntityInput struct {
	ID   string
	Name string
}

// EntityCreatedEvent is a domain event emitted when an entity is successfully created.
type EntityCreatedEvent struct {
	Entity Entity
}

// EntityUpdatedEvent is emitted when an entity is successfully updated.
type EntityUpdatedEvent struct {
	EntityID string `json:"entity_id"`
	Name     string `json:"name"`
	Version  int    `json:"version"`
}

// EntityRetrievedEvent is emitted when an entity is fetched via the service.
type EntityRetrievedEvent struct {
	EntityID    string
	RetrievedAt time.Time
}

// ListInput carries pagination parameters for listing entities.
type ListInput struct {
	Page  int
	Limit int
}

// ListResult is the paginated response from a list query.
type ListResult struct {
	Items []Entity
	Total int
	Page  int
	Limit int
}

// NextPage computes the query string for the next page,
// or returns empty string if there are no more pages.
func (r *ListResult) NextPage() string {
	offset := (r.Page - 1) * r.Limit
	if offset+len(r.Items) >= r.Total {
		return ""
	}
	nextPage := r.Page + 1
	return "?page=" + itoa(nextPage) + "&limit=" + itoa(r.Limit)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [12]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
