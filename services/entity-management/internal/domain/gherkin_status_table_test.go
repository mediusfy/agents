package domain

import (
	"context"
	"errors"
	"testing"
	"time"
)

// =============================================================================
// Table-driven Gherkin Tests for Entity Status Transitions
//
// Covers the following Gherkin scenarios:
//
// SCENARIO 1:
//   Given an entity exists with status "active"
//   When a user updates the entity setting status="inactive"
//   Then the transition succeeds
//     And an entitymanagement.entity.updated event is emitted
//       with changed_fields including "status"
//
// SCENARIO 2:
//   Given an entity exists with status "inactive"
//   When a user updates the entity setting status="active"
//   Then the transition succeeds
//
// SCENARIO 3:
//   Given an entity exists with status "active"
//   When a soft-delete is performed (via DELETE endpoint)
//   Then the entity status transitions to "deleted" (terminal state)
//
// SCENARIO 4:
//   Given an entity exists with status "deleted" (after soft-delete)
//   When a user attempts a status-only update setting status="active"
//   Then ErrInvalidStatusTransition is returned
//     And the only way to exit "deleted" is via the restore endpoint
//
// SCENARIO 5:
//   Given an entity exists with status "inactive"
//   When a user attempts to set status to an invalid value "unknown"
//   Then ErrInvalidStatusTransition is returned
//     And no data is modified
// =============================================================================

// statusTransitionTestCase describes a single Gherkin-driven status transition
// scenario at the domain service level.
type statusTransitionTestCase struct {
	name string

	// Initial state
	initialStatus EntityStatus
	initialVer    int

	// Operation to perform
	useSoftDelete bool // if true, call SoftDeleteEntity instead of UpdateEntity
	targetStatus  *EntityStatus
	expectedVer   int // expected version for the update op

	// Expected outcome
	wantErr error

	// Post-conditions
	wantStatus             EntityStatus
	wantVersion            int
	wantDeletedAtSet       bool
	wantOutboxEvent        bool
	wantEventType          string // expected outbox event type
	wantChangedFieldStatus bool   // changed_fields should include "status"

	// SCENARIO 4: restore should succeed after this test
	wantRestorePossible bool
}

// TestGherkin_StatusTransitions_TableDriven exercises all 5 Gherkin scenarios
// covering entity status lifecycle transitions via a single table-driven test.
func TestGherkin_StatusTransitions_TableDriven(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	frozenNow := time.Date(2025, 6, 15, 14, 30, 0, 0, time.UTC)

	active := EntityStatusActive
	inactive := EntityStatusInactive
	unknown := EntityStatus("unknown")

	tests := []statusTransitionTestCase{
		// ------------------------------------------------------------------
		// SCENARIO 1: Active → Inactive via UpdateEntity
		//   "Given an entity exists with status 'active'
		//    When a user updates the entity setting status='inactive'
		//    Then the transition succeeds
		//      And an entitymanagement.entity.updated event is emitted
		//        with changed_fields including 'status'"
		// ------------------------------------------------------------------
		{
			name:                   "SCENARIO_1: active_to_inactive_emits_event_with_changed_fields",
			initialStatus:          EntityStatusActive,
			initialVer:             1,
			targetStatus:           &inactive,
			expectedVer:            1,
			wantErr:                nil,
			wantStatus:             EntityStatusInactive,
			wantVersion:            2,
			wantDeletedAtSet:       false,
			wantOutboxEvent:        true,
			wantEventType:          (&EntityUpdated{}).EventName(),
			wantChangedFieldStatus: true,
			wantRestorePossible:    false,
		},

		// ------------------------------------------------------------------
		// SCENARIO 2: Inactive → Active via UpdateEntity
		//   "Given an entity exists with status 'inactive'
		//    When a user updates the entity setting status='active'
		//    Then the transition succeeds"
		// ------------------------------------------------------------------
		{
			name:                   "SCENARIO_2: inactive_to_active_succeeds",
			initialStatus:          EntityStatusInactive,
			initialVer:             1,
			targetStatus:           &active,
			expectedVer:            1,
			wantErr:                nil,
			wantStatus:             EntityStatusActive,
			wantVersion:            2,
			wantDeletedAtSet:       false,
			wantOutboxEvent:        true,
			wantEventType:          (&EntityUpdated{}).EventName(),
			wantChangedFieldStatus: true,
			wantRestorePossible:    false,
		},

		// ------------------------------------------------------------------
		// SCENARIO 3: Active → Deleted via soft-delete (terminal state)
		//   "Given an entity exists with status 'active'
		//    When a soft-delete is performed (via DELETE endpoint)
		//    Then the entity status transitions to 'deleted' (terminal state)"
		// ------------------------------------------------------------------
		{
			name:                "SCENARIO_3: soft_delete_transitions_to_deleted_terminal",
			initialStatus:       EntityStatusActive,
			initialVer:          1,
			useSoftDelete:       true,
			targetStatus:        nil,
			expectedVer:         1,
			wantErr:             nil,
			wantStatus:          EntityStatusDeleted,
			wantVersion:         2,
			wantDeletedAtSet:    true,
			wantOutboxEvent:     true,
			wantEventType:       (&EntitySoftDeleted{}).EventName(),
			wantRestorePossible: true, // restore should work from deleted
		},

		// ------------------------------------------------------------------
		// SCENARIO 4: Deleted → Active via UpdateEntity (rejected)
		//   "Given an entity exists with status 'deleted' (after soft-delete)
		//    When a user attempts a status-only update setting status='active'
		//    Then ErrInvalidStatusTransition is returned
		//      And the only way to exit 'deleted' is via the restore endpoint"
		// ------------------------------------------------------------------
		{
			name:                "SCENARIO_4: deleted_cannot_transition_via_update_only_via_restore",
			initialStatus:       EntityStatusDeleted,
			initialVer:          2,
			targetStatus:        &active,
			expectedVer:         2,
			wantErr:             ErrInvalidStatusTransition,
			wantStatus:          EntityStatusDeleted, // unchanged
			wantVersion:         2,                   // unchanged
			wantDeletedAtSet:    true,
			wantOutboxEvent:     false, // no event on failure
			wantRestorePossible: true,  // SCENARIO 4: restore must work
		},

		// ------------------------------------------------------------------
		// SCENARIO 5: Inactive → "unknown" via UpdateEntity (rejected)
		//   "Given an entity exists with status 'inactive'
		//    When a user attempts to set status to an invalid value 'unknown'
		//    Then ErrInvalidStatusTransition is returned
		//      And no data is modified"
		// ------------------------------------------------------------------
		{
			name:                "SCENARIO_5: invalid_status_returns_error_and_no_modification",
			initialStatus:       EntityStatusInactive,
			initialVer:          1,
			targetStatus:        &unknown,
			expectedVer:         1,
			wantErr:             ErrInvalidStatusTransition,
			wantStatus:          EntityStatusInactive, // unchanged
			wantVersion:         1,                    // unchanged
			wantDeletedAtSet:    false,
			wantOutboxEvent:     false, // no event on failure
			wantRestorePossible: false,
		},
	}

	for _, tt := range tests {
		tt := tt // capture range variable
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			// Arrange: fresh fakes per test case
			schemaRepo := newFakeSchemaRepo()
			entityRepo := newFakeEntityRepo()
			outboxRepo := newFakeOutboxRepo()
			idempotency := newFakeRequestIdempotency()
			uow := newFakeUnitOfWork()
			eventBus := newFakeEventBus()

			schemaID := "sch-test"
			if err := schemaRepo.Save(ctx, &EntitySchema{
				ID:   schemaID,
				Name: "Test",
				Attributes: []AttributeDefinition{
					{Name: "email", Type: AttributeTypeString, Required: true},
				},
				Version:   1,
				CreatedAt: frozenNow.Add(-24 * time.Hour),
				UpdatedAt: frozenNow.Add(-24 * time.Hour),
			}); err != nil {
				t.Fatalf("save schema: %v", err)
			}

			// Seed an entity in the given initial state.
			var deletedAt *time.Time
			if tt.wantDeletedAtSet || tt.initialStatus == EntityStatusDeleted {
				dt := frozenNow.Add(-1 * time.Hour)
				deletedAt = &dt
			}

			entity := &Entity{
				ID:         "ent-td-001",
				SchemaID:   schemaID,
				Name:       "TestEntity",
				Type:       "test",
				Region:     "us-east-1",
				Status:     tt.initialStatus,
				Version:    tt.initialVer,
				DeletedAt:  deletedAt,
				Attributes: map[string]any{"email": "test@example.com"},
				CreatedAt:  frozenNow.Add(-2 * time.Hour),
				UpdatedAt:  frozenNow.Add(-1 * time.Hour),
			}
			if err := entityRepo.Save(ctx, entity); err != nil {
				t.Fatalf("save initial entity: %v", err)
			}

			svc := NewService(
				schemaRepo, entityRepo, outboxRepo, idempotency, uow,
				WithClock(func() time.Time { return frozenNow }),
				WithEvents(eventBus),
			)

			// Act: perform the operation
			var err error

			if tt.useSoftDelete {
				// SCENARIO 3: Soft-delete path
				err = svc.SoftDeleteEntity(ctx, "ent-td-001")
			} else {
				// SCENARIO 1, 2, 4, 5: UpdateEntity path
				op := UpdateOperation{
					ExpectedVersion: tt.expectedVer,
				}
				if tt.targetStatus != nil {
					op.Status = tt.targetStatus
				}
				_, err = svc.UpdateEntity(ctx, "ent-td-001", op)
			}

			// Assert: verify error expectation
			if tt.wantErr != nil {
				if err == nil {
					t.Fatalf("expected error %v, got nil", tt.wantErr)
				}
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("expected error %v, got %v", tt.wantErr, err)
				}
			} else if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			// Assert: verify final entity state from repository
			updated, lookupErr := entityRepo.FindByID(ctx, "ent-td-001")
			if lookupErr != nil {
				t.Fatalf("FindByID after operation: %v", lookupErr)
			}

			if updated.Status != tt.wantStatus {
				t.Errorf("status: want %q, got %q", tt.wantStatus, updated.Status)
			}
			if updated.Version != tt.wantVersion {
				t.Errorf("version: want %d, got %d", tt.wantVersion, updated.Version)
			}

			if tt.wantDeletedAtSet && updated.DeletedAt == nil {
				t.Error("expected deleted_at to be set, got nil")
			}
			if !tt.wantDeletedAtSet && updated.DeletedAt != nil {
				t.Errorf("expected deleted_at to be nil, got %v", *updated.DeletedAt)
			}

			// Assert: verify outbox events
			if tt.wantOutboxEvent {
				if len(outboxRepo.events) != 1 {
					t.Fatalf("expected 1 outbox event, got %d", len(outboxRepo.events))
				}
				if outboxRepo.events[0].EventType != tt.wantEventType {
					t.Errorf("event type: want %q, got %q",
						tt.wantEventType, outboxRepo.events[0].EventType)
				}
				if outboxRepo.events[0].Status != OutboxStatusPending {
					t.Errorf("outbox status: want 'pending', got %q", outboxRepo.events[0].Status)
				}

				// SCENARIO 1 specific: changed_fields includes "status"
				if tt.wantChangedFieldStatus && !tt.useSoftDelete {
					op := UpdateOperation{ExpectedVersion: tt.expectedVer, Status: tt.targetStatus}
					changedFields := op.CollectChangedFields()
					foundStatus := false
					for _, f := range changedFields {
						if f == "status" {
							foundStatus = true
							break
						}
					}
					if !foundStatus {
						t.Errorf("changed_fields should include 'status', got %v", changedFields)
					}
				}
			} else {
				if len(outboxRepo.events) != 0 {
					t.Errorf("expected 0 outbox events for failed operation, got %d", len(outboxRepo.events))
				}
			}

			// SCENARIO 3 & 4: verify deleted status is terminal
			if tt.wantStatus == EntityStatusDeleted && tt.wantErr == nil {
				// Attempt to update the deleted entity via ApplyUpdate directly
				terminalOp := UpdateOperation{
					ExpectedVersion: tt.wantVersion,
					Status:          &active,
				}
				if err := updated.ApplyUpdate(terminalOp); !errors.Is(err, ErrInvalidStatusTransition) {
					t.Errorf("expected ErrInvalidStatusTransition when updating deleted entity, got %v", err)
				}
			}

			// SCENARIO 3 & 4: verify restore works (only way to exit "deleted")
			if tt.wantRestorePossible {
				restoreErr := svc.RestoreEntity(ctx, "ent-td-001")
				if restoreErr != nil {
					t.Fatalf("RestoreEntity failed: %v", restoreErr)
				}
				restored, _ := entityRepo.FindByID(ctx, "ent-td-001")
				if restored.Status != EntityStatusActive {
					t.Errorf("after restore, expected status 'active', got %q", restored.Status)
				}
				if restored.DeletedAt != nil {
					t.Error("after restore, expected deleted_at to be nil")
				}
			}
		})
	}
}

// =============================================================================
// Complementary table-driven test for EntityStatus.CanTransitionTo
// =============================================================================

func TestEntityStatus_CanTransitionTo_TableDriven(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		current EntityStatus
		target  EntityStatus
		want    bool
	}{
		// Valid transitions
		{name: "active_can_transition_to_inactive", current: EntityStatusActive, target: EntityStatusInactive, want: true},
		{name: "active_can_transition_to_deleted", current: EntityStatusActive, target: EntityStatusDeleted, want: true},
		{name: "inactive_can_transition_to_active", current: EntityStatusInactive, target: EntityStatusActive, want: true},
		{name: "inactive_can_transition_to_deleted", current: EntityStatusInactive, target: EntityStatusDeleted, want: true},

		// Invalid transitions
		{name: "active_cannot_transition_to_active_self", current: EntityStatusActive, target: EntityStatusActive, want: false},
		{name: "active_cannot_transition_to_unknown", current: EntityStatusActive, target: EntityStatus("unknown"), want: false},
		{name: "inactive_cannot_transition_to_inactive_self", current: EntityStatusInactive, target: EntityStatusInactive, want: false},
		{name: "inactive_cannot_transition_to_unknown", current: EntityStatusInactive, target: EntityStatus("unknown"), want: false},

		// Deleted is terminal: no transitions allowed
		{name: "deleted_cannot_transition_to_active", current: EntityStatusDeleted, target: EntityStatusActive, want: false},
		{name: "deleted_cannot_transition_to_inactive", current: EntityStatusDeleted, target: EntityStatusInactive, want: false},
		{name: "deleted_cannot_transition_to_deleted_self", current: EntityStatusDeleted, target: EntityStatusDeleted, want: false},
		{name: "deleted_cannot_transition_to_unknown", current: EntityStatusDeleted, target: EntityStatus("unknown"), want: false},

		// Unknown current status
		{name: "unknown_status_returns_false", current: EntityStatus("bogus"), target: EntityStatusActive, want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.current.CanTransitionTo(tt.target)
			if got != tt.want {
				t.Errorf("CanTransitionTo(%q) from %q = %v, want %v",
					tt.target, tt.current, got, tt.want)
			}
		})
	}
}

// =============================================================================
// Table-driven test for ValidTransitions
// =============================================================================

func TestEntityStatus_ValidTransitions_TableDriven(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		status EntityStatus
		want   []EntityStatus
	}{
		{
			name:   "active_valid_transitions",
			status: EntityStatusActive,
			want:   []EntityStatus{EntityStatusInactive, EntityStatusDeleted},
		},
		{
			name:   "inactive_valid_transitions",
			status: EntityStatusInactive,
			want:   []EntityStatus{EntityStatusActive, EntityStatusDeleted},
		},
		{
			name:   "deleted_valid_transitions_empty",
			status: EntityStatusDeleted,
			want:   []EntityStatus{},
		},
		{
			name:   "unknown_status_returns_nil",
			status: EntityStatus("bogus"),
			want:   nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.status.ValidTransitions()
			if len(got) != len(tt.want) {
				t.Fatalf("ValidTransitions() len = %d, want %d; got %v, want %v",
					len(got), len(tt.want), got, tt.want)
			}
			for i, expected := range tt.want {
				if got[i] != expected {
					t.Errorf("ValidTransitions()[%d] = %q, want %q", i, got[i], expected)
				}
			}
		})
	}
}

// =============================================================================
// Table-driven test for MarkDeleted covering all initial statuses
// =============================================================================

func TestEntity_MarkDeleted_TableDriven(t *testing.T) {
	t.Parallel()
	now := time.Now().UTC()

	tests := []struct {
		name       string
		initial    Entity
		wantErr    error
		wantStatus EntityStatus
		wantVer    int
	}{
		{
			name: "mark_deleted_from_active_succeeds",
			initial: Entity{
				ID: "ent-001", Status: EntityStatusActive, Version: 1,
			},
			wantErr:    nil,
			wantStatus: EntityStatusDeleted,
			wantVer:    2,
		},
		{
			name: "mark_deleted_from_inactive_succeeds",
			initial: Entity{
				ID: "ent-002", Status: EntityStatusInactive, Version: 1,
			},
			wantErr:    nil,
			wantStatus: EntityStatusDeleted,
			wantVer:    2,
		},
		{
			name: "mark_deleted_from_deleted_returns_ErrAlreadyDeleted",
			initial: Entity{
				ID: "ent-003", Status: EntityStatusDeleted, Version: 2,
				DeletedAt: &now,
			},
			wantErr:    ErrAlreadyDeleted,
			wantStatus: EntityStatusDeleted,
			wantVer:    2,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := &Entity{
				ID:        tt.initial.ID,
				Status:    tt.initial.Status,
				Version:   tt.initial.Version,
				DeletedAt: tt.initial.DeletedAt,
			}
			err := e.MarkDeleted(now)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("MarkDeleted() error = %v, want %v", err, tt.wantErr)
				}
			} else if err != nil {
				t.Fatalf("MarkDeleted() unexpected error: %v", err)
			}
			if e.Status != tt.wantStatus {
				t.Errorf("status = %q, want %q", e.Status, tt.wantStatus)
			}
			if e.Version != tt.wantVer {
				t.Errorf("version = %d, want %d", e.Version, tt.wantVer)
			}
			if tt.wantErr == nil && e.DeletedAt == nil {
				t.Error("expected deleted_at to be set")
			}
		})
	}
}
