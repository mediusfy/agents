// Package controller implements the CRD event controller for Agent resources.
package controller

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"github.com/drewjocham/agents/ux-designer/internal/agents"
	"github.com/drewjocham/agents/ux-designer/internal/agents/service"
)

var tracer = otel.Tracer("agents.controller")

// Watcher defines the interface for Kubernetes resource watching.
type Watcher interface {
	Watch(ctx context.Context) (<-chan Event, error)
	Stop()
}

// Event represents a CRD lifecycle event.
type Event struct {
	Type    EventType
	Agent   *agents.Agent
	OldSpec *agents.AgentSpec
}

// EventType categorizes CRD events.
type EventType string

const (
	EventAdded   EventType = "added"
	EventUpdated EventType = "updated"
	EventDeleted EventType = "deleted"
)

// Controller watches for Agent CRD events and dispatches them to the service layer.
type Controller struct {
	watcher  Watcher
	service  *service.AgentService
	logger   *slog.Logger
	mu       sync.Mutex
	stopCh   chan struct{}
}

// NewController creates a new agent CRD controller.
func NewController(watcher Watcher, svc *service.AgentService, logger *slog.Logger) *Controller {
	return &Controller{
		watcher: watcher,
		service: svc,
		logger:  logger,
		stopCh:  make(chan struct{}),
	}
}

// Run starts the controller event loop. Blocks until ctx is cancelled or an error occurs.
func (c *Controller) Run(ctx context.Context) error {
	ctx, span := tracer.Start(ctx, "Controller.Run")
	defer span.End()

	eventCh, err := c.watcher.Watch(ctx)
	if err != nil {
		return fmt.Errorf("controller: failed to start watcher: %w", err)
	}

	c.logger.InfoContext(ctx, "agent controller started")

	for {
		select {
		case <-ctx.Done():
			c.logger.InfoContext(ctx, "agent controller shutting down")
			c.watcher.Stop()
			return ctx.Err()

		case <-c.stopCh:
			c.logger.InfoContext(ctx, "agent controller stopped via stop channel")
			c.watcher.Stop()
			return nil

		case event, ok := <-eventCh:
			if !ok {
				c.logger.WarnContext(ctx, "agent controller: watcher channel closed")
				return nil
			}

			if err := c.handleEvent(ctx, event); err != nil {
				span.RecordError(err)
				c.logger.ErrorContext(ctx, "failed to handle event",
					slog.String("event_type", string(event.Type)),
					slog.String("agent_id", event.Agent.Name),
					slog.Any("error", err),
				)
			}
		}
	}
}

// Stop signals the controller to stop gracefully.
func (c *Controller) Stop() {
	close(c.stopCh)
}

func (c *Controller) handleEvent(ctx context.Context, event Event) error {
	ctx, span := tracer.Start(ctx, "Controller.handleEvent",
		trace.WithAttributes(
			attribute.String("event_type", string(event.Type)),
			attribute.String("agent_id", event.Agent.Name),
		))
	defer span.End()

	switch event.Type {
	case EventAdded:
		c.logger.InfoContext(ctx, "agent added",
			slog.String("agent_id", event.Agent.Name),
		)
		return c.service.Register(ctx, event.Agent)

	case EventUpdated:
		c.logger.InfoContext(ctx, "agent updated",
			slog.String("agent_id", event.Agent.Name),
		)
		return c.service.Register(ctx, event.Agent)

	case EventDeleted:
		c.logger.InfoContext(ctx, "agent deleted",
			slog.String("agent_id", event.Agent.Name),
		)
		return c.service.Delete(ctx, event.Agent.Name)

	default:
		return fmt.Errorf("unknown event type: %s", event.Type)
	}
}

// PeriodicTrigger fires periodic triggers for agents with cron schedules.
func (c *Controller) PeriodicTrigger(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			agents, err := c.service.List(ctx)
			if err != nil {
				c.logger.ErrorContext(ctx, "periodic trigger: failed to list agents",
					slog.Any("error", err),
				)
				continue
			}

			for _, agent := range agents {
				for _, trigger := range agent.Spec.Triggers {
					if trigger.Cron != "" {
						if err := c.service.Trigger(ctx, agent.Name); err != nil {
							c.logger.WarnContext(ctx, "periodic trigger failed",
								slog.String("agent_id", agent.Name),
								slog.Any("error", err),
							)
						}
					}
				}
			}
		}
	}
}
