package residency

// DataResidencyZone represents the geographic boundary for entity data storage.
type DataResidencyZone string

const (
	ZoneUSEast1 DataResidencyZone = "us-east-1"
	ZoneEUWest1 DataResidencyZone = "eu-west-1"
)

// ResolveZone maps a cloud region string to its corresponding data residency zone.
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

// ImmutableFields lists entity fields that MUST NOT change after creation.
var ImmutableFields = []string{"id", "region", "data_residency_zone", "created_at"}

// IsImmutableField reports whether the given field name is immutable.
func IsImmutableField(field string) bool {
	for _, f := range ImmutableFields {
		if f == field {
			return true
		}
	}
	return false
}
