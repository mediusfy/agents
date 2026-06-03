// Package service contains the business logic for the Agent lifecycle.
package service

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"github.com/drewjocham/agents/ux-designer/internal/agents"
)

var tracer = otel.Tracer("agents.service")

// AgentStore is the persistence interface for agents.
type AgentStore interface {
	Get(ctx context.Context, id string) (*agents.Agent, error)
	List(ctx context.Context) ([]*agents.Agent, error)
	Save(ctx context.Context, agent *agents.Agent) error
	Delete(ctx context.Context, id string) error
}

// AgentDispatcher handles dispatch of agent actions to the MCP runtime.
type AgentDispatcher interface {
	Dispatch(ctx context.Context, agent *agents.Agent, trigger agents.TriggerCondition) error
}

// AgentService provides business logic for agent lifecycle management.
type AgentService struct {
	store      AgentStore
	dispatcher AgentDispatcher
	logger     *slog.Logger
}

// NewAgentService creates a new AgentService.
func NewAgentService(store AgentStore, dispatcher AgentDispatcher, logger *slog.Logger) *AgentService {
	return &AgentService{
		store:      store,
		dispatcher: dispatcher,
		logger:     logger,
	}
}

// Register validates and persists a new Agent.
func (s *AgentService) Register(ctx context.Context, agent *agents.Agent) error {
	ctx, span := tracer.Start(ctx, "AgentService.Register",
		trace.WithAttributes(attribute.String("agent_id", agent.Name)))
	defer span.End()

	if err := agent.Validate(); err != nil {
		span.RecordError(err)
		return fmt.Errorf("register: %w", err)
	}

	if err := s.store.Save(ctx, agent); err != nil {
		span.RecordError(err)
		return fmt.Errorf("register: save: %w", err)
	}

	s.logger.InfoContext(ctx, "agent registered",
		slog.String("agent_id", agent.Name),
		slog.String("type", string(agent.Spec.Type)),
	)
	return nil
}

// Trigger evaluates trigger conditions and dispatches the agent.
func (s *AgentService) Trigger(ctx context.Context, agentID string) error {
	ctx, span := tracer.Start(ctx, "AgentService.Trigger",
		trace.WithAttributes(attribute.String("agent_id", agentID)))
	defer span.End()

	agent, err := s.store.Get(ctx, agentID)
	if err != nil {
		span.RecordError(err)
		return fmt.Errorf("trigger: get: %w", err)
	}

	if agent.Status.Phase == agents.AgentPhaseDisabled {
		return agents.ErrAgentDisabled
	}

	for _, trigger := range agent.Spec.Triggers {
		if err := s.dispatcher.Dispatch(ctx, agent, trigger); err != nil {
			agent.Status.FailureCount++
			agent.Status.LastError = err.Error()
			agent.Status.Phase = agents.AgentPhaseFailed

			if saveErr := s.store.Save(ctx, agent); saveErr != nil {
				s.logger.ErrorContext(ctx, "failed to persist agent failure",
					slog.String("agent_id", agentID),
					slog.Any("error", saveErr),
				)
			}

			span.RecordError(err)
			return fmt.Errorf("trigger: dispatch: %w", err)
		}
	}

	now := time.Now()
	agent.Status.Phase = agents.AgentPhaseRunning
	agent.Status.LastTriggeredAt = &now
	agent.Status.ExecutionCount++

	if err := s.store.Save(ctx, agent); err != nil {
		s.logger.ErrorContext(ctx, "failed to persist agent state",
			slog.String("agent_id", agentID),
			slog.Any("error", err),
		)
	}

	return nil
}

// List returns all registered agents.
func (s *AgentService) List(ctx context.Context) ([]*agents.Agent, error) {
	ctx, span := tracer.Start(ctx, "AgentService.List")
	defer span.End()

	agents, err := s.store.List(ctx)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("list: %w", err)
	}
	return agents, nil
}

// Get returns a single agent by ID.
func (s *AgentService) Get(ctx context.Context, id string) (*agents.Agent, error) {
	ctx, span := tracer.Start(ctx, "AgentService.Get",
		trace.WithAttributes(attribute.String("agent_id", id)))
	defer span.End()

	agent, err := s.store.Get(ctx, id)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("get: %w", err)
	}
	return agent, nil
}

// Delete removes an agent from the store.
func (s *AgentService) Delete(ctx context.Context, id string) error {
	ctx, span := tracer.Start(ctx, "AgentService.Delete",
		trace.WithAttributes(attribute.String("agent_id", id)))
	defer span.End()

	if err := s.store.Delete(ctx, id); err != nil {
		span.RecordError(err)
		return fmt.Errorf("delete: %w", err)
	}
	return nil
}
