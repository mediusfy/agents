package domain

import (
	"errors"
	"testing"
)

// ============================================================================
// Gherkin SCENARIO 2: ResolveZone function — region-to-zone mapping
//
//   Given region "eu-west-1" maps to DataResidencyZone "eu-west-1"
//     And region "us-east-1" maps to DataResidencyZone "us-east-1"
//   When the ResolveZone function is called
//   Then it correctly maps known regions to their residency zones
//     And unknown regions pass through as-is (default behavior)
// ============================================================================

func TestGherkin_ResolveZone_KnownRegions(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		region string
		want   DataResidencyZone
	}{
		// Given: known us-east mappings
		{name: "us-east-1 maps to ZoneUSEast1", region: "us-east-1", want: ZoneUSEast1},
		{name: "us-west-2 maps to ZoneUSEast1", region: "us-west-2", want: ZoneUSEast1},

		// Given: known eu-west mappings
		{name: "eu-west-1 maps to ZoneEUWest1", region: "eu-west-1", want: ZoneEUWest1},
		{name: "eu-central-1 maps to ZoneEUWest1", region: "eu-central-1", want: ZoneEUWest1},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			// When the ResolveZone function is called
			got := ResolveZone(tt.region)

			// Then it correctly maps the region to its residency zone
			if got != tt.want {
				t.Errorf("ResolveZone(%q) = %q, want %q", tt.region, got, tt.want)
			}
		})
	}
}

func TestGherkin_ResolveZone_UnknownRegions_PassThrough(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		region string
	}{
		{name: "ap-southeast-1 passes through as-is", region: "ap-southeast-1"},
		{name: "ap-northeast-1 passes through as-is", region: "ap-northeast-1"},
		{name: "sa-east-1 passes through as-is", region: "sa-east-1"},
		{name: "me-south-1 passes through as-is", region: "me-south-1"},
		{name: "af-south-1 passes through as-is", region: "af-south-1"},
		{name: "empty string passes through as-is", region: ""},
		{name: "custom-region passes through as-is", region: "custom-region"},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			// When the ResolveZone function is called
			got := ResolveZone(tt.region)

			// Then unknown regions pass through as-is (default behavior)
			want := DataResidencyZone(tt.region)
			if got != want {
				t.Errorf("ResolveZone(%q) = %q, want %q (pass-through)", tt.region, got, want)
			}
		})
	}
}

// ============================================================================
// Gherkin SCENARIO 3: Immutable data_residency_zone field
//
//   Given an entity's data_residency_zone is set to "eu-west-1"
//   When a user attempts to update the data_residency_zone field via the update
//        endpoint
//   Then ErrImmutableField is returned because "data_residency_zone" is in the
//        ImmutableFields list
//     And no data modification occurs
// ============================================================================

func TestGherkin_ImmutableFields_ContainsDataResidencyZone(t *testing.T) {
	t.Parallel()

	// Then "data_residency_zone" is in the ImmutableFields list.
	found := false
	for _, field := range ImmutableFields {
		if field == "data_residency_zone" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("ImmutableFields = %v, does not contain %q",
			ImmutableFields, "data_residency_zone")
	}

	// Also verify related immutable fields are present.
	expectedImmutable := []string{"id", "region", "data_residency_zone", "type", "created_at"}
	if len(ImmutableFields) != len(expectedImmutable) {
		t.Logf("ImmutableFields length = %d, expected length = %d",
			len(ImmutableFields), len(expectedImmutable))
	}
	for _, exp := range expectedImmutable {
		found := false
		for _, f := range ImmutableFields {
			if f == exp {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("Expected %q in ImmutableFields = %v", exp, ImmutableFields)
		}
	}
}

func TestGherkin_IsImmutableField_ReturnsTrueForDataResidencyZone(t *testing.T) {
	t.Parallel()

	tests := []struct {
		field string
		want  bool
	}{
		{field: "data_residency_zone", want: true},
		{field: "region", want: true},
		{field: "id", want: true},
		{field: "type", want: true},
		{field: "created_at", want: true},
		{field: "name", want: false},
		{field: "status", want: false},
		{field: "attributes", want: false},
		{field: "metadata", want: false},
		{field: "version", want: false},
		{field: "updated_at", want: false},
		{field: "deleted_at", want: false},
		{field: "schema_id", want: false},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.field, func(t *testing.T) {
			t.Parallel()
			got := IsImmutableField(tt.field)
			if got != tt.want {
				t.Errorf("IsImmutableField(%q) = %v, want %v", tt.field, got, tt.want)
			}
		})
	}
}

// ============================================================================
// Gherkin SCENARIO 3 (extended): Verify that attempting to modify the
// data_residency_zone-derived field (region) via UpdateOperation is rejected.
//
// The data_residency_zone is computed from region at creation time. Since
// updating the region field is already blocked (ValidateMutable returns
// ErrImmutableField), the data_residency_zone is indirectly immutable.
//
// We also verify that setting data_residency_zone directly on the Entity
// struct (if attempted via a future code path) would be blocked by
// IsImmutableField and that the ApplyUpdate flow correctly prevents it.
// ============================================================================

func TestGherkin_UpdateEntity_DataResidencyZone_Immutable(t *testing.T) {
	t.Parallel()

	// Given an entity's data_residency_zone is set to "eu-west-1".
	entity := &Entity{
		ID:                "ent-res-001",
		Name:              "ResidencyTest",
		Region:            "eu-west-1",
		DataResidencyZone: ZoneEUWest1,
		Status:            EntityStatusActive,
		Version:           1,
	}

	// When a user attempts to change the region (which controls data_residency_zone).
	// The UpdateOperation only exposes Region, not DataResidencyZone directly.
	// Changing Region should be rejected by ValidateMutable.
	newRegion := "us-east-1"
	op := UpdateOperation{
		ExpectedVersion: 1,
		Region:          &newRegion,
	}

	// When applying the update (which calls ValidateMutable internally).
	err := entity.ApplyUpdate(op)

	// Then ErrImmutableField is returned.
	if err == nil {
		t.Fatal("ApplyUpdate: expected ErrImmutableField, got nil")
	}
	if !errors.Is(err, ErrImmutableField) {
		t.Errorf("ApplyUpdate: expected ErrImmutableField, got %v", err)
	}

	// And no data modification occurs.
	if entity.Region != "eu-west-1" {
		t.Errorf("Region was modified: got %q, want %q", entity.Region, "eu-west-1")
	}
	if entity.DataResidencyZone != ZoneEUWest1 {
		t.Errorf("DataResidencyZone was modified: got %q, want %q",
			entity.DataResidencyZone, ZoneEUWest1)
	}
	if entity.Version != 1 {
		t.Errorf("Version was incremented: got %d, want 1", entity.Version)
	}
}

// ============================================================================
// Additional: Verify ResolveZone is a pure function (no side effects)
// ============================================================================

func TestGherkin_ResolveZone_IsPureFunction(t *testing.T) {
	t.Parallel()

	// Calling ResolveZone multiple times with the same input must return
	// the same output (idempotency / determinism).
	inputs := []string{"us-east-1", "eu-west-1", "ap-southeast-1", "us-west-2", "eu-central-1"}
	for _, region := range inputs {
		region := region
		t.Run(region, func(t *testing.T) {
			t.Parallel()
			first := ResolveZone(region)
			second := ResolveZone(region)
			third := ResolveZone(region)
			if first != second || second != third {
				t.Errorf("ResolveZone(%q) not deterministic: %q, %q, %q",
					region, first, second, third)
			}
		})
	}
}

// ============================================================================
// Additional: Entity creation with region sets DataResidencyZone correctly
// ============================================================================

func TestGherkin_CreateEntity_ResolvesDataResidencyZone(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		region string
		want   DataResidencyZone
	}{
		{name: "eu-west-1 resolves to ZoneEUWest1", region: "eu-west-1", want: ZoneEUWest1},
		{name: "us-east-1 resolves to ZoneUSEast1", region: "us-east-1", want: ZoneUSEast1},
		{name: "unknown region passes through", region: "ap-southeast-1", want: DataResidencyZone("ap-southeast-1")},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			// Creating an entity with the given region directly (simulating what
			// the domain Service.CreateEntity does internally).
			entity := &Entity{
				ID:                "ent-dr-001",
				Region:            tt.region,
				DataResidencyZone: ResolveZone(tt.region),
				Status:            EntityStatusActive,
				Version:           1,
			}

			if entity.DataResidencyZone != tt.want {
				t.Errorf("Entity.DataResidencyZone = %q, want %q",
					entity.DataResidencyZone, tt.want)
			}
		})
	}
}

// ============================================================================
// Additional: ValidateMutable rejects region changes (which drives
// data_residency_zone)
// ============================================================================

func TestGherkin_ValidateMutable_RegionIsImmutable(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		op   UpdateOperation
		want bool // true if expected to be immutable (error)
	}{
		{
			name: "region change is immutable",
			op:   UpdateOperation{Region: strPtr("eu-west-1")},
			want: true,
		},
		{
			name: "name change is mutable",
			op:   UpdateOperation{Name: strPtr("New Name")},
			want: false,
		},
		{
			name: "status change is mutable",
			op:   UpdateOperation{Status: statusPtr(EntityStatusInactive)},
			want: false,
		},
		{
			name: "attributes change is mutable",
			op:   UpdateOperation{Attributes: map[string]any{"email": "new@test.com"}},
			want: false,
		},
		{
			name: "metadata change is mutable",
			op:   UpdateOperation{Metadata: map[string]any{"key": "value"}},
			want: false,
		},
		{
			name: "empty operation is valid",
			op:   UpdateOperation{ExpectedVersion: 1},
			want: false,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			err := tt.op.ValidateMutable()

			if tt.want {
				// Expected immutable field error
				if err == nil {
					t.Error("ValidateMutable: expected error, got nil")
				} else if !errors.Is(err, ErrImmutableField) {
					t.Errorf("ValidateMutable: expected ErrImmutableField, got %v", err)
				}
			} else {
				// Expected no error
				if err != nil {
					t.Errorf("ValidateMutable: unexpected error: %v", err)
				}
			}
		})
	}
}

// ============================================================================
// Helpers
// ============================================================================

// strPtr is already defined in update_entity_test.go, but we keep a local copy
// to avoid cross-file dependency issues depending on test execution order.
// We use the same name to be consistent. Since tests in the same package share
// these helpers, this should compile fine.

// Note: strPtr and statusPtr are defined in update_entity_test.go within the
// same package (domain), so they are available here too. We don't need to
// redefine them.
