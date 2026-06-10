package domain_test

import (
	"context"
	"errors"
	"testing"

	"github.com/drewjocham/agents/internal/domain"
)

// ---- Fake ports (no mocks, no DB) ----

type fakeEntityRepo struct {
	entities map[string]*domain.Entity
}

func (f *fakeEntityRepo) FindByID(_ context.Context, id string) (*domain.Entity, error) {
	e, ok := f.entities[id]
	if !ok {
		return nil, nil
	}
	cp := *e
	return &cp, nil
}

type fakeEventBus struct {
	events []any
}

func (f *fakeEventBus) Publish(_ context.Context, event any) error {
	f.events = append(f.events, event)
	return nil
}

// ---- Tests ----

func TestGetEntity_Found(t *testing.T) {
	repo := &fakeEntityRepo{entities: map[string]*domain.Entity{
		"abc-123": {ID: "abc-123", Name: "test-entity"},
	}}
	bus := &fakeEventBus{}
	svc := domain.NewEntityService(repo, bus)

	ent, err := svc.GetEntity(context.Background(), "abc-123")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ent.ID != "abc-123" {
		t.Errorf("expected id abc-123, got %q", ent.ID)
	}
	if len(bus.events) != 1 {
		t.Errorf("expected 1 event, got %d", len(bus.events))
	}
}

func TestGetEntity_NotFound(t *testing.T) {
	repo := &fakeEntityRepo{entities: map[string]*domain.Entity{}}
	bus := &fakeEventBus{}
	svc := domain.NewEntityService(repo, bus)

	_, err := svc.GetEntity(context.Background(), "nonexistent")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, domain.ErrEntityNotFound) {
		t.Errorf("expected ErrEntityNotFound, got %v", err)
	}
}

func TestGetEntity_EmptyID(t *testing.T) {
	repo := &fakeEntityRepo{entities: map[string]*domain.Entity{}}
	bus := &fakeEventBus{}
	svc := domain.NewEntityService(repo, bus)

	_, err := svc.GetEntity(context.Background(), "")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, domain.ErrInvalidEntityID) {
		t.Errorf("expected ErrInvalidEntityID, got %v", err)
	}
}
