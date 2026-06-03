// Package anomstack implements the event consumer that triggers autonomous agent triage.
// Strategy Theme 3: Autonomous Agent Sub-Agent Layer.
//
// Anomstack fires anomaly alerts → agent proactively pulls logs, checks PR guidelines,
// cross-references runbooks, places root-cause summary.
package anomstack

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("anomstack.consumer")

// AnomstackEvent represents a normalized anomaly alert from Anomstack.
type AnomstackEvent struct {
	AlertID      string `json:"alert_id"`
	Cluster      string `json:"cluster"`
	Namespace    string `json:"namespace"`
	ResourceKind string `json:"resource_kind"`
	Name         string `json:"name"`
	Severity     string `json:"severity"`
	Summary      string `json:"summary"`
	RawPayload   []byte `json:"raw_payload,omitempty"`
	Timestamp    time.Time `json:"timestamp"`
}

// EventHandler processes Anomstack events and dispatches them to the agent controller.
type EventHandler interface {
	// Handle processes a normalized Anomstack event.
	Handle(ctx context.Context, event AnomstackEvent) error
}

// Sentinel errors
var (
	ErrAlertAlreadyProcessing = errors.New("alert already being processed")
	ErrConsumerClosed         = errors.New("consumer is closed")
)

// Consumer receives Anomstack alerts via webhook or NATS/Kafka and normalizes them.
type Consumer struct {
	handler     EventHandler
	logger      *slog.Logger
	dedupWindow time.Duration
	mu          sync.Mutex
	closed      bool
	recentAlerts map[string]time.Time
}

// NewConsumer creates a new Anomstack event consumer.
func NewConsumer(handler EventHandler, logger *slog.Logger) *Consumer {
	return &Consumer{
		handler:      handler,
		logger:       logger,
		dedupWindow:  5 * time.Minute,
		recentAlerts: make(map[string]time.Time),
	}
}

// HandleWebhook handles an incoming webhook POST from Anomstack.
func (c *Consumer) HandleWebhook(ctx context.Context, raw []byte) error {
	ctx, span := tracer.Start(ctx, "Consumer.HandleWebhook")
	defer span.End()

	var rawEvent struct {
		AlertID      string `json:"alert_id"`
		Cluster      string `json:"cluster"`
		Namespace    string `json:"namespace"`
		ResourceKind string `json:"resource_kind"`
		Name         string `json:"name"`
		Severity     string `json:"severity"`
		Summary      string `json:"summary"`
		Timestamp    string `json:"timestamp"`
	}

	if err := json.Unmarshal(raw, &rawEvent); err != nil {
		return fmt.Errorf("parse webhook payload: %w", err)
	}

	ts, _ := time.Parse(time.RFC3339, rawEvent.Timestamp)
	if ts.IsZero() {
		ts = time.Now()
	}

	event := AnomstackEvent{
		AlertID:      rawEvent.AlertID,
		Cluster:      rawEvent.Cluster,
		Namespace:    rawEvent.Namespace,
		ResourceKind: rawEvent.ResourceKind,
		Name:         rawEvent.Name,
		Severity:     rawEvent.Severity,
		Summary:      rawEvent.Summary,
		RawPayload:   raw,
		Timestamp:    ts,
	}

	return c.process(ctx, event)
}

func (c *Consumer) process(ctx context.Context, event AnomstackEvent) error {
	ctx, span := tracer.Start(ctx, "Consumer.process",
		trace.WithAttributes(
			attribute.String("alert_id", event.AlertID),
			attribute.String("severity", event.Severity),
			attribute.String("resource", event.Name),
		))
	defer span.End()

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return ErrConsumerClosed
	}

	// Deduplication within dedupWindow
	if lastSeen, ok := c.recentAlerts[event.AlertID]; ok {
		if time.Since(lastSeen) < c.dedupWindow {
			c.mu.Unlock()
			span.AddEvent("alert_dedup", trace.WithAttributes(
				attribute.String("alert_id", event.AlertID),
			))
			return ErrAlertAlreadyProcessing
		}
	}
	c.recentAlerts[event.AlertID] = time.Now()
	c.mu.Unlock()

	slog.InfoContext(ctx, "processing anomaly alert",
		slog.String("alert_id", event.AlertID),
		slog.String("severity", event.Severity),
		slog.String("resource", event.Name),
		slog.String("namespace", event.Namespace),
	)

	// Cleanup old dedup entries
	go c.cleanup()

	return c.handler.Handle(ctx, event)
}

func (c *Consumer) cleanup() {
	c.mu.Lock()
	defer c.mu.Unlock()

	cutoff := time.Now().Add(-c.dedupWindow * 2)
	for id, ts := range c.recentAlerts {
		if ts.Before(cutoff) {
			delete(c.recentAlerts, id)
		}
	}
}

// Close stops the consumer.
func (c *Consumer) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	c.recentAlerts = nil
}
