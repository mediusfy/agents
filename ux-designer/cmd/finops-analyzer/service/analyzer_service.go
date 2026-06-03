// Package service implements the FinOps waste analysis business logic.
package service

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"

	"github.com/drewjocham/agents/ux-designer/cmd/finops-analyzer"
	"github.com/drewjocham/agents/ux-designer/cmd/finops-analyzer/ports"
)

var (
	tracer       = otel.Tracer("finops.service")
	meter        = otel.Meter("finops.analyzer")
	wasteCounter metric.Int64Counter
)

func init() {
	var err error
	wasteCounter, err = meter.Int64Counter("finops.waste_detected",
		metric.WithDescription("Total waste observations detected"),
		metric.WithUnit("{observation}"),
	)
	if err != nil {
		panic(fmt.Sprintf("init meter: %v", err))
	}
}

// AnalyzerService provides FinOps waste analysis business logic.
type AnalyzerService struct {
	metrics         ports.MetricProvider
	store           ports.WasteStore
	prSvc           ports.PRService
	logger          *slog.Logger
	costPerCPUHour  float64 // hourly cost per CPU core
	costPerGBMemory float64 // hourly cost per GB memory
}

// NewAnalyzerService creates a new FinOps analyzer service.
func NewAnalyzerService(
	metrics ports.MetricProvider,
	store ports.WasteStore,
	prSvc ports.PRService,
	logger *slog.Logger,
) *AnalyzerService {
	return &AnalyzerService{
		metrics:         metrics,
		store:           store,
		prSvc:           prSvc,
		logger:          logger,
		costPerCPUHour:  0.10, // $0.10/hr per CPU core
		costPerGBMemory: 0.05, // $0.05/hr per GB
	}
}

// AnalyzeWorkload scans a workload's Prometheus metrics and detects waste.
func (s *AnalyzerService) AnalyzeWorkload(ctx context.Context, cluster, namespace, workload string) error {
	ctx, span := tracer.Start(ctx, "AnalyzerService.AnalyzeWorkload",
		trace.WithAttributes(
			attribute.String("cluster", cluster),
			attribute.String("namespace", namespace),
			attribute.String("workload", workload),
		))
	defer span.End()

	workloadMetrics, err := s.metrics.QueryWorkloadMetrics(ctx, namespace, workload, "")
	if err != nil {
		span.RecordError(err)
		return fmt.Errorf("analyze workload %s: %w", workload, err)
	}

	if workloadMetrics.CPUActualCores == 0 && workloadMetrics.MemActualBytes == 0 {
		return finops.ErrNoMetricsAvailable
	}

	// Compute waste: (requested - actual) * cost
	wasteCents := s.computeWaste(workloadMetrics)

	obs := &finops.WasteObservation{
		Cluster:                   cluster,
		Namespace:                 namespace,
		ResourceType:              "deployment",
		WorkloadName:              workload,
		CurrentRequestsCPU:        formatCPU(workloadMetrics.CPURequestCores),
		CurrentRequestsMemory:     formatMemory(workloadMetrics.MemRequestBytes),
		CurrentLimitsCPU:          formatCPU(workloadMetrics.CPULimitCores),
		CurrentLimitsMemory:       formatMemory(workloadMetrics.MemLimitBytes),
		RecommendedRequestsCPU:    formatCPU(workloadMetrics.CPUActualCores * 1.1),
		RecommendedRequestsMemory: formatMemory(workloadMetrics.MemActualBytes * 1.1),
		RecommendedLimitsCPU:      formatCPU(workloadMetrics.CPUActualCores * 1.5),
		RecommendedLimitsMemory:   formatMemory(workloadMetrics.MemActualBytes * 1.5),
		MonthlyWasteUSDCents:      wasteCents,
		DetectedAt:                time.Now(),
		Status:                    "open",
	}

	if err := s.store.UpsertObservation(ctx, obs); err != nil {
		span.RecordError(err)
		return fmt.Errorf("upsert observation: %w", err)
	}

	wasteCounter.Add(ctx, 1,
		metric.WithAttributes(
			attribute.String("workload", workload),
			attribute.String("cluster", cluster),
			attribute.Int64("waste_cents", wasteCents),
		),
	)

	s.logger.InfoContext(ctx, "waste detected",
		slog.String("workload", workload),
		slog.Int64("monthly_waste_cents", wasteCents),
	)

	return nil
}

// GetTopWaste returns the top-N waste observations.
func (s *AnalyzerService) GetTopWaste(ctx context.Context, limit int) ([]*finops.WasteObservation, error) {
	ctx, span := tracer.Start(ctx, "AnalyzerService.GetTopWaste")
	defer span.End()

	results, err := s.store.GetTopWaste(ctx, limit)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("get top waste: %w", err)
	}
	return results, nil
}

// GenerateRecommendation creates a PR for a given waste observation.
func (s *AnalyzerService) GenerateRecommendation(ctx context.Context, observationID string) (*finops.CostSavingAction, error) {
	ctx, span := tracer.Start(ctx, "AnalyzerService.GenerateRecommendation",
		trace.WithAttributes(
			attribute.String("observation_id", observationID),
		))
	defer span.End()

	obs, err := s.store.GetObservation(ctx, observationID)
	if err != nil {
		return nil, fmt.Errorf("get observation: %w", err)
	}

	if obs.Status != "open" {
		return nil, finops.ErrAlreadyActioned
	}

	actions, err := s.store.GetActionsByObservation(ctx, observationID)
	if err == nil && len(actions) > 0 {
		return nil, finops.ErrAlreadyActioned
	}

	prURL, prNum, err := s.prSvc.GenerateRightSizePR(ctx, obs)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("generate PR: %w", err)
	}

	action := &finops.CostSavingAction{
		WasteObservationID: observationID,
		ActionType:         "pr_rightsize",
		TargetKind:         obs.ResourceType,
		TargetName:         obs.WorkloadName,
		RecommendedSavings: obs.MonthlyWasteUSDCents,
		PRURL:              prURL,
		PRStatus:           "open",
	}

	if err := s.store.CreateAction(ctx, action); err != nil {
		return nil, fmt.Errorf("create action: %w", err)
	}

	if err := s.store.UpdateObservationStatus(ctx, observationID, "actioned"); err != nil {
		s.logger.WarnContext(ctx, "failed to update observation status",
			slog.String("observation_id", observationID),
			slog.Any("error", err),
		)
	}

	s.logger.InfoContext(ctx, "recommendation generated",
		slog.String("observation_id", observationID),
		slog.String("pr_url", prURL),
		slog.Int("pr_number", prNum),
	)

	return action, nil
}

// DismissObservation marks a waste observation as dismissed.
func (s *AnalyzerService) DismissObservation(ctx context.Context, id, reason string) error {
	ctx, span := tracer.Start(ctx, "AnalyzerService.DismissObservation",
		trace.WithAttributes(attribute.String("observation_id", id)))
	defer span.End()

	return s.store.UpdateObservationStatus(ctx, id, "dismissed")
}

func (s *AnalyzerService) computeWaste(m *ports.WorkloadMetrics) int64 {
	// Waste = over-provisioned resources * cost
	cpuWaste := (m.CPURequestCores - m.CPUActualCores)
	if cpuWaste < 0 {
		cpuWaste = 0
	}
	memWasteGB := (m.MemRequestBytes - m.MemActualBytes) / (1024 * 1024 * 1024)
	if memWasteGB < 0 {
		memWasteGB = 0
	}

	// Monthly cost: waste * cost_per_hour * 730 hours
	cpuCost := cpuWaste * s.costPerCPUHour * 730 * 100 // in cents
	memCost := float64(memWasteGB) * s.costPerGBMemory * 730 * 100

	return int64(cpuCost + memCost)
}

func formatCPU(cores float64) string {
	return fmt.Sprintf("%dm", int(cores*1000))
}

func formatMemory(bytes float64) string {
	gib := bytes / (1024 * 1024 * 1024)
	return fmt.Sprintf("%.0fGi", gib)
}
