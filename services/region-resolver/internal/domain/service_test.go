package domain

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// mockEntityRepo implements EntityRepository in-memory for testing.
type mockEntityRepo struct {
	mu      sync.Mutex
	data    map[string]*Entity
	saveErr error
}

func newMockEntityRepo() *mockEntityRepo {
	return &mockEntityRepo{
		data: make(map[string]*Entity),
	}
}

func (m *mockEntityRepo) Save(ctx context.Context, entity *Entity) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.saveErr != nil {
		return m.saveErr
	}
	// Clone to simulate database persistence boundary
	clone := *entity
	m.data[entity.ID] = &clone
	return nil
}

func (m *mockEntityRepo) FindByID(ctx context.Context, id string) (*Entity, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	entity, ok := m.data[id]
	if !ok {
		return nil, ErrEntityNotFound
	}
	clone := *entity
	return &clone, nil
}

func (m *mockEntityRepo) Update(ctx context.Context, entity *Entity) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.data[entity.ID]; !ok {
		return ErrEntityNotFound
	}
	clone := *entity
	m.data[entity.ID] = &clone
	return nil
}

func (m *mockEntityRepo) List(ctx context.Context) ([]*Entity, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var list []*Entity
	for _, entity := range m.data {
		clone := *entity
		list = append(list, &clone)
	}
	return list, nil
}

func (m *mockEntityRepo) Delete(ctx context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.data[id]; !ok {
		return ErrEntityNotFound
	}
	delete(m.data, id)
	return nil
}

// mockEventPublisher implements EventPublisher for testing.
type mockEventPublisher struct {
	mu            sync.Mutex
	createdEvents []*EntityCreated
	updatedEvents []*EntityUpdated
	deletedEvents []*EntityDeleted
}

func (m *mockEventPublisher) PublishEntityCreated(ctx context.Context, event *EntityCreated) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.createdEvents = append(m.createdEvents, event)
	return nil
}

func (m *mockEventPublisher) PublishEntityUpdated(ctx context.Context, event *EntityUpdated) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.updatedEvents = append(m.updatedEvents, event)
	return nil
}

func (m *mockEventPublisher) PublishEntityDeleted(ctx context.Context, event *EntityDeleted) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.deletedEvents = append(m.deletedEvents, event)
	return nil
}

func TestResolveZone(t *testing.T) {
	tests := []struct {
		region string
		want   DataResidencyZone
	}{
		{"us-east-1", ZoneUSEast1},
		{"us-west-2", ZoneUSEast1},
		{"eu-west-1", ZoneEUWest1},
		{"eu-central-1", ZoneEUWest1},
		{"ap-southeast-1", "ap-southeast-1"},
	}

	for _, tt := range tests {
		t.Run(tt.region, func(t *testing.T) {
			if got := ResolveZone(tt.region); got != tt.want {
				t.Errorf("ResolveZone(%q) = %q, want %q", tt.region, got, tt.want)
			}
		})
	}
}

func TestService_CreateEntity(t *testing.T) {
	repo := newMockEntityRepo()
	pub := &mockEventPublisher{}
	fixedTime := time.Date(2026, 6, 11, 12, 0, 0, 0, time.UTC)
	svc := NewService(repo, pub, WithClock(func() time.Time { return fixedTime }))

	// Test validation error
	_, err := svc.CreateEntity(context.Background(), CreateEntityInput{Name: "", Region: "us-east-1"})
	if !errors.Is(err, ErrInvalidEntity) {
		t.Fatalf("expected ErrInvalidEntity for empty name, got: %v", err)
	}

	_, err = svc.CreateEntity(context.Background(), CreateEntityInput{Name: "test", Region: ""})
	if !errors.Is(err, ErrInvalidEntity) {
		t.Fatalf("expected ErrInvalidEntity for empty region, got: %v", err)
	}

	// Test successful creation
	result, err := svc.CreateEntity(context.Background(), CreateEntityInput{
		Name:   "Test Entity",
		Region: "eu-west-1",
		Labels: map[string]string{"env": "test"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result.Entity.Name != "Test Entity" {
		t.Errorf("expected name Test Entity, got %q", result.Entity.Name)
	}
	if result.Entity.DataResidencyZone != ZoneEUWest1 {
		t.Errorf("expected residency zone %q, got %q", ZoneEUWest1, result.Entity.DataResidencyZone)
	}
	if result.Entity.Version != 1 {
		t.Errorf("expected version 1, got %d", result.Entity.Version)
	}

	// Check persistence
	persisted, err := repo.FindByID(context.Background(), result.Entity.ID)
	if err != nil {
		t.Fatalf("failed to find persisted entity: %v", err)
	}
	if persisted.Name != "Test Entity" {
		t.Errorf("persisted name mismatch: %q", persisted.Name)
	}

	// Check event publishing
	pub.mu.Lock()
	defer pub.mu.Unlock()
	if len(pub.createdEvents) != 1 {
		t.Fatalf("expected 1 created event, got %d", len(pub.createdEvents))
	}
	if pub.createdEvents[0].EntityID != result.Entity.ID {
		t.Errorf("event entity ID mismatch: %q", pub.createdEvents[0].EntityID)
	}
}

func TestService_UpdateEntity(t *testing.T) {
	repo := newMockEntityRepo()
	pub := &mockEventPublisher{}
	fixedTime := time.Date(2026, 6, 11, 12, 0, 0, 0, time.UTC)
	svc := NewService(repo, pub, WithClock(func() time.Time { return fixedTime }))

	// Seed an entity
	res, err := svc.CreateEntity(context.Background(), CreateEntityInput{
		Name:   "Original",
		Region: "us-east-1",
	})
	if err != nil {
		t.Fatalf("failed to create entity: %v", err)
	}
	id := res.Entity.ID

	// Test immutable field update rejection
	zoneOverride := ZoneEUWest1
	_, err = svc.UpdateEntity(context.Background(), id, UpdateOperation{
		ExpectedVersion:   1,
		DataResidencyZone: &zoneOverride,
	})
	if !errors.Is(err, ErrImmutableField) {
		t.Fatalf("expected ErrImmutableField, got: %v", err)
	}

	// Test version check (optimistic concurrency)
	newName := "New Name"
	_, err = svc.UpdateEntity(context.Background(), id, UpdateOperation{
		ExpectedVersion: 99, // incorrect version
		Name:            &newName,
	})
	if !errors.Is(err, ErrStaleVersion) {
		t.Fatalf("expected ErrStaleVersion, got: %v", err)
	}

	// Test successful update
	updated, err := svc.UpdateEntity(context.Background(), id, UpdateOperation{
		ExpectedVersion: 1,
		Name:            &newName,
	})
	if err != nil {
		t.Fatalf("unexpected update error: %v", err)
	}

	if updated.Name != "New Name" {
		t.Errorf("expected updated name New Name, got %q", updated.Name)
	}
	if updated.Version != 2 {
		t.Errorf("expected version to be incremented to 2, got %d", updated.Version)
	}

	// Check event publishing
	pub.mu.Lock()
	defer pub.mu.Unlock()
	if len(pub.updatedEvents) != 1 {
		t.Fatalf("expected 1 updated event, got %d", len(pub.updatedEvents))
	}
	if pub.updatedEvents[0].EntityID != id {
		t.Errorf("event ID mismatch: %q", pub.updatedEvents[0].EntityID)
	}
}

func TestService_DeleteEntity(t *testing.T) {
	repo := newMockEntityRepo()
	pub := &mockEventPublisher{}
	svc := NewService(repo, pub)

	// Seed entity
	res, err := svc.CreateEntity(context.Background(), CreateEntityInput{
		Name:   "ToDelete",
		Region: "us-east-1",
	})
	if err != nil {
		t.Fatalf("failed to create entity: %v", err)
	}
	id := res.Entity.ID

	// Delete
	err = svc.DeleteEntity(context.Background(), id)
	if err != nil {
		t.Fatalf("unexpected delete error: %v", err)
	}

	// Verify not found
	_, err = repo.FindByID(context.Background(), id)
	if !errors.Is(err, ErrEntityNotFound) {
		t.Fatalf("expected ErrEntityNotFound after deletion, got: %v", err)
	}

	// Check event publishing
	pub.mu.Lock()
	defer pub.mu.Unlock()
	if len(pub.deletedEvents) != 1 {
		t.Fatalf("expected 1 deleted event, got %d", len(pub.deletedEvents))
	}
}
