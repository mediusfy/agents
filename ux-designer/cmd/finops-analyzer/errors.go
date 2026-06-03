// Package finops implements the FinOps waste analysis service.
// Strategy Theme 2: Automated FinOps ROI.
//
// Periodically scans Prometheus metrics for actual usage vs requests/limits,
// computes waste, and generates PRs via pr-bridge for remediation.
package finops

import (
	"errors"
	"fmt"
	"time"
)

// WasteObservation represents detected resource waste.
type WasteObservation struct {
	ID                     string    `json:"id"`
	Cluster                string    `json:"cluster"`
	Namespace              string    `json:"namespace"`
	ResourceType           string    `json:"resource_type"`
	WorkloadName           string    `json:"workload_name"`
	ContainerName          string    `json:"container_name,omitempty"`
	CurrentRequestsCPU     string    `json:"current_requests_cpu"`
	CurrentRequestsMemory  string    `json:"current_requests_memory"`
	CurrentLimitsCPU       string    `json:"current_limits_cpu"`
	CurrentLimitsMemory    string    `json:"current_limits_memory"`
	RecommendedRequestsCPU    string `json:"recommended_requests_cpu"`
	RecommendedRequestsMemory string `json:"recommended_requests_memory"`
	RecommendedLimitsCPU       string `json:"recommended_limits_cpu"`
	RecommendedLimitsMemory    string `json:"recommended_limits_memory"`
	MonthlyWasteUSDCents   int64     `json:"monthly_waste_usd_cents"`
	DetectedAt             time.Time `json:"detected_at"`
	Status                 string    `json:"status"`
}

// CostSavingAction represents a remediation action for a waste observation.
type CostSavingAction struct {
	ID                   string    `json:"id"`
	WasteObservationID   string    `json:"waste_observation_id"`
	ActionType           string    `json:"action_type"`
	TargetKind           string    `json:"target_kind"`
	TargetName           string    `json:"target_name"`
	RecommendedSavings   int64     `json:"recommended_savings_cents"`
	PRURL                string    `json:"pr_url,omitempty"`
	PRStatus             string    `json:"pr_status"`
	AppliedAt            *time.Time `json:"applied_at,omitempty"`
}

// Sentinel errors
var (
	ErrNoMetricsAvailable  = errors.New("no Prometheus metrics available")
	ErrAlreadyActioned     = errors.New("waste observation already has an action")
	ErrRecommendationFailed = errors.New("recommendation generation failed")
)

// AnalyzerError wraps sentinel errors with context.
type AnalyzerError struct {
	Op       string
	Workload string
	Err      error
}

func (e *AnalyzerError) Error() string {
	return fmt.Sprintf("finops: %s workload=%s: %v", e.Op, e.Workload, e.Err)
}

func (e *AnalyzerError) Unwrap() error {
	return e.Err
}
