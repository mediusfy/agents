package domain_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/cto-ai/entity-management/internal/domain"
)

// ---- Fake ports for testing ----

type fakeEntityRepo struct {
	entities map[string]*domain.Entity
}

func (f *fakeEntityRepo) GetByID(_ context.Context, id string) (*domain.Entity, error) {
	e, ok := f.entities[id]
	if !ok {
		return nil, domain.ErrEntityNotFound
	}
	// Return a copy to simulate a real DB read.
	cp := *e
	return &cp, nil
}

func (f *fakeEntityRepo) Update(_ context.Context, e *domain.Entity) error {
	existing, ok := f.entities[e.ID]
	if !ok {
		return domain.ErrEntityNotFound
	}
	if existing.Version != e.Version-1 {
		return domain.ErrStaleVersion
	}
	f.entities[e.ID] = e
	return nil
}

func (f *fakeEntityRepo) Close(_ context.Context) error { return nil }

type fakeOutboxRepo struct {
	messages []domain.OutboxMessage
}

func (f *fakeOutboxRepo) Insert(_ context.Context, msg *domain.OutboxMessage) error {
	f.messages = append(f.messages, *msg)
	return nil
}

func (f *fakeOutboxRepo) FetchPending(_ context.Context, _ int) ([]domain.OutboxMessage, error) {
	return f.messages, nil
}

func (f *fakeOutboxRepo) MarkPublished(_ context.Context, _ []string) error { return nil }
func (f *fakeOutboxRepo) DeletePublished(_ context.Context, _ time.Duration) error { return nil }

// ---- Tests ----

func TestEntityService_Update_Success(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC().Truncate(time.Microsecond)
	entity := &domain.Entity{
		ID:        "ENT-456",
		Name:      "Original Name",
		Labels:    map[string]string{"env": "prod"},
		Version:   3,
		CreatedAt: now,
		UpdatedAt: now,
	}

	repo := &fakeEntityRepo{entities: map[string]*domain.Entity{"ENT-456": entity}}
	outbox := &fakeOutboxRepo{}
	svc := domain.NewEntityService(repo, outbox)

	newName := "Updated Name"
	updated, err := svc.Update(context.Background(), domain.UpdateCommand{
		ID:      "ENT-456",
		Name:    &newName,
		Labels:  map[string]string{"env": "staging"},
		Version: 3,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if updated.Version != 4 {
		t.Errorf("expected version 4, got %d", updated.Version)
	}
	if updated.Name != "Updated Name" {
		t.Errorf("expected name 'Updated Name', got %q", updated.Name)
	}
	if v := updated.Labels["env"]; v != "staging" {
		t.Errorf("expected label env=staging, got %q", v)
	}

	if len(outbox.messages) != 1 {
		t.Fatalf("expected 1 outbox message, got %d", len(outbox.messages))
	}
	if outbox.messages[0].EventType != "io.cto-ai.entitymanagement.entity.updated" {
		t.Errorf("unexpected event type: %s", outbox.messages[0].EventType)
	}
}

func TestEntityService_Update_StaleVersion(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC().Truncate(time.Microsecond)
	entity := &domain.Entity{
		ID:        "ENT-456",
		Name:      "Original",
		Version:   3,
		CreatedAt: now,
		UpdatedAt: now,
	}

	repo := &fakeEntityRepo{entities: map[string]*domain.Entity{"ENT-456": entity}}
	outbox := &fakeOutboxRepo{}
	svc := domain.NewEntityService(repo, outbox)

	name := "Should Not Apply"
	_, err := svc.Update(context.Background(), domain.UpdateCommand{
		ID:      "ENT-456",
		Name:    &name,
		Version: 2, // stale
	})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, domain.ErrStaleVersion) {
		t.Errorf("expected ErrStaleVersion, got %v", err)
	}

	// Verify no outbox message was written.
	if len(outbox.messages) > 0 {
		t.Errorf("expected 0 outbox messages on failure, got %d", len(outbox.messages))
	}
}

func TestEntityService_Update_EntityNotFound(t *testing.T) {
	t.Parallel()

	repo := &fakeEntityRepo{entities: map[string]*domain.Entity{}}
	outbox := &fakeOutboxRepo{}
	svc := domain.NewEntityService(repo, outbox)

	name := "N/A"
	_, err := svc.Update(context.Background(), domain.UpdateCommand{
		ID:      "DOES_NOT_EXIST",
		Name:    &name,
		Version: 1,
	})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, domain.ErrEntityNotFound) {
		t.Errorf("expected ErrEntityNotFound, got %v", err)
	}
}
