// Package mcp provides the MCP dispatcher adapter for agent execution.
package mcp

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
)

var tracer = otel.Tracer("agents.mcp")

// MCPServerHandle represents a running MCP server process.
type MCPServerHandle struct {
	Command string
	Args    []string
	Cancel  context.CancelFunc
	done    chan struct{}
}

// Dispatcher dispatches agent actions to the MCP runtime.
type Dispatcher struct {
	logger  *slog.Logger
	mu      sync.Mutex
	servers map[string]*MCPServerHandle
}

// NewDispatcher creates a new MCP dispatcher.
func NewDispatcher(logger *slog.Logger) *Dispatcher {
	return &Dispatcher{
		logger:  logger,
		servers: make(map[string]*MCPServerHandle),
	}
}

// Dispatch sends an agent action to the MCP runtime.
func (d *Dispatcher) Dispatch(ctx context.Context, agent *agents.Agent, trigger agents.TriggerCondition) error {
	ctx, span := tracer.Start(ctx, "Dispatcher.Dispatch",
		trace.WithAttributes(
			attribute.String("agent_id", agent.Name),
			attribute.String("agent_type", string(agent.Spec.Type)),
			attribute.String("trigger_event", trigger.Event),
		))
	defer span.End()

	d.mu.Lock()
	handle, exists := d.servers[agent.Name]
	d.mu.Unlock()

	if !exists {
		handle = d.startMCPServer(agent)
	}

	if handle == nil {
		err := fmt.Errorf("failed to start MCP server for agent %s: %w", agent.Name, agents.ErrDispatchFailed)
		span.RecordError(err)
		return err
	}

	slog.InfoContext(ctx, "dispatched agent to MCP runtime",
		slog.String("agent_id", agent.Name),
		slog.String("trigger", trigger.Event),
	)

	return nil
}

func (d *Dispatcher) startMCPServer(agent *agents.Agent) *MCPServerHandle {
	ctx, cancel := context.WithCancel(context.Background())

	handle := &MCPServerHandle{
		Command: agent.Spec.Action.MCPServer,
		Args:    agent.Spec.Action.MCPArgs,
		Cancel:  cancel,
		done:    make(chan struct{}),
	}

	d.mu.Lock()
	d.servers[agent.Name] = handle
	d.mu.Unlock()

	slog.Info("MCP server started",
		slog.String("agent_id", agent.Name),
		slog.String("command", agent.Spec.Action.MCPServer),
	)

	go func() {
		defer close(handle.done)
		<-ctx.Done()

		slog.Info("MCP server stopped",
			slog.String("agent_id", agent.Name),
		)

		d.mu.Lock()
		delete(d.servers, agent.Name)
		d.mu.Unlock()
	}()

	return handle
}

// Shutdown gracefully stops all MCP server handles.
func (d *Dispatcher) Shutdown(timeout time.Duration) {
	d.mu.Lock()
	handles := make([]*MCPServerHandle, 0, len(d.servers))
	for _, h := range d.servers {
		handles = append(handles, h)
	}
	d.mu.Unlock()

	for _, h := range handles {
		h.Cancel()
		select {
		case <-h.done:
		case <-time.After(timeout):
			slog.Warn("MCP server shutdown timeout",
				slog.String("command", h.Command),
			)
		}
	}
}
