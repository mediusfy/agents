// Package ports defines abstract interfaces for the FinOps analyzer.
package ports

import (
	"context"

	"github.com/drewjocham/agents/ux-designer/cmd/finops-analyzer"
)

// MetricProvider provides Prometheus metrics for waste analysis.
type MetricProvider interface {
	// QueryWorkloadMetrics returns actual vs requested usage for a given namespace/workload.
	QueryWorkloadMetrics(ctx context.Context, namespace, workload, container string) (*WorkloadMetrics, error)

	// ListWorkloads returns all workloads (deployments, statefulsets) in a namespace.
	ListWorkloads(ctx context.Context, cluster, namespace string) ([]string, error)

	// ListClusters returns all known clusters.
	ListClusters(ctx context.Context) ([]string, error)
}

// WorkloadMetrics contains actual vs requested resource usage.
type WorkloadMetrics struct {
	WorkloadName    string  `json:"workload_name"`
	ContainerName   string  `json:"container_name"`
	CPURequestCores float64 `json:"cpu_request_cores"`
	CPULimitCores   float64 `json:"cpu_limit_cores"`
	CPUActualCores  float64 `json:"cpu_actual_cores"`
	MemRequestBytes float64 `json:"mem_request_bytes"`
	MemLimitBytes   float64 `json:"mem_limit_bytes"`
	MemActualBytes  float64 `json:"mem_actual_bytes"`
}

// WasteStore provides persistence for waste observations and actions.
type WasteStore interface {
	// UpsertObservation inserts or updates a waste observation.
	UpsertObservation(ctx context.Context, obs *finops.WasteObservation) error

	// ListOpenObservations returns all open waste observations.
	ListOpenObservations(ctx context.Context) ([]*finops.WasteObservation, error)

	// GetTopWaste returns the top-N waste observations by monthly cost.
	GetTopWaste(ctx context.Context, limit int) ([]*finops.WasteObservation, error)

	// GetObservation returns a single observation by ID.
	GetObservation(ctx context.Context, id string) (*finops.WasteObservation, error)

	// UpdateObservationStatus changes the status of an observation.
	UpdateObservationStatus(ctx context.Context, id, status string) error

	// CreateAction records a new cost-saving action.
	CreateAction(ctx context.Context, action *finops.CostSavingAction) error

	// GetActionsByObservation returns all actions for a given observation.
	GetActionsByObservation(ctx context.Context, observationID string) ([]*finops.CostSavingAction, error)
}

// PRService generates Git remediation PRs via the pr-bridge.
type PRService interface {
	// GenerateRightSizePR creates a PR to right-size a deployment.
	GenerateRightSizePR(ctx context.Context, obs *finops.WasteObservation) (string, int, error)
}
