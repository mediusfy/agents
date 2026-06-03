// Package agents defines the Agent CRD types for the Rufkis Agent sub-agent layer.
// Strategy Theme 3: Autonomous Agent Sub-Agent Layer.
//
// Each Agent resource describes:
//   - AgentType: categorization (watcher, scheduler, analyzer, integrator)
//   - TriggerConditions: when the agent activates (cron, event, manual)
//   - ActionConfig: what the agent does (MCP server, capabilities)
//   - WatchScope: where the agent operates (namespaces, resources, labels)
package agents

import (
	"fmt"
	"time"
)

// AgentType categorizes the kind of autonomous agent.
type AgentType string

const (
	AgentTypeWatcher    AgentType = "watcher"
	AgentTypeScheduler  AgentType = "scheduler"
	AgentTypeAnalyzer   AgentType = "analyzer"
	AgentTypeIntegrator AgentType = "integrator"
)

// TriggerCondition defines when an agent should activate.
type TriggerCondition struct {
	// Cron schedule (e.g. "*/5 * * * *") for periodic agents.
	Cron string `json:"cron,omitempty" yaml:"cron,omitempty"`
	// Event source (e.g. "anomstack.alerts", "argocd.sync") for event-driven agents.
	Event string `json:"event,omitempty" yaml:"event,omitempty"`
	// Manual allows on-demand invocation.
	Manual bool `json:"manual,omitempty" yaml:"manual,omitempty"`
}

// ActionConfig defines what the agent does when triggered.
type ActionConfig struct {
	// MCPServer is the command to start the MCP server for this agent.
	MCPServer string `json:"mcp_server,omitempty" yaml:"mcp_server,omitempty"`
	// MCPArgs are additional arguments for the MCP server.
	MCPArgs []string `json:"mcp_args,omitempty" yaml:"mcp_args,omitempty"`
	// Capabilities this agent supports.
	Capabilities []Capability `json:"capabilities,omitempty" yaml:"capabilities,omitempty"`
}

// Capability is a named ability the agent can perform.
type Capability string

const (
	CapabilityDescribe Capability = "describe"
	CapabilityDiagnose Capability = "diagnose"
	CapabilityAct      Capability = "act"
	CapabilitySummarize Capability = "summarize"
)

// WatchScope defines the Kubernetes resources an agent monitors.
type WatchScope struct {
	// Namespaces to watch (empty = all namespaces).
	Namespaces []string `json:"namespaces,omitempty" yaml:"namespaces,omitempty"`
	// Resource kinds to watch (e.g. "Pod", "Deployment", "Service").
	Resources []string `json:"resources,omitempty" yaml:"resources,omitempty"`
	// Label selectors to filter resources.
	Labels map[string]string `json:"labels,omitempty" yaml:"labels,omitempty"`
}

// AgentSpec is the full specification for an Agent resource.
type AgentSpec struct {
	Type       AgentType         `json:"type" yaml:"type"`
	Triggers   []TriggerCondition `json:"triggers,omitempty" yaml:"triggers,omitempty"`
	Action     ActionConfig      `json:"action" yaml:"action"`
	WatchScope WatchScope        `json:"watch_scope,omitempty" yaml:"watch_scope,omitempty"`
	// MaxRetries is the number of automatic retries on failure.
	MaxRetries int `json:"max_retries,omitempty" yaml:"max_retries,omitempty"`
	// TimeoutSeconds is the maximum execution time per trigger.
	TimeoutSeconds int `json:"timeout_seconds,omitempty" yaml:"timeout_seconds,omitempty"`
}

// AgentStatus represents the current state of an Agent resource.
type AgentStatus struct {
	Phase           AgentPhase `json:"phase" yaml:"phase"`
	LastTriggeredAt *time.Time `json:"last_triggered_at,omitempty" yaml:"last_triggered_at,omitempty"`
	LastError       string     `json:"last_error,omitempty" yaml:"last_error,omitempty"`
	ExecutionCount  int64      `json:"execution_count" yaml:"execution_count"`
	FailureCount    int64      `json:"failure_count" yaml:"failure_count"`
}

// AgentPhase represents the lifecycle phase of an agent.
type AgentPhase string

const (
	AgentPhaseIdle     AgentPhase = "idle"
	AgentPhaseRunning  AgentPhase = "running"
	AgentPhaseFailed   AgentPhase = "failed"
	AgentPhaseDisabled AgentPhase = "disabled"
)

// Agent is the top-level resource representing an autonomous agent.
type Agent struct {
	// Name is the unique identifier for this agent.
	Name string `json:"name" yaml:"name"`
	// Namespace the agent operates in.
	Namespace string `json:"namespace,omitempty" yaml:"namespace,omitempty"`
	// Spec is the agent specification.
	Spec AgentSpec `json:"spec" yaml:"spec"`
	// Status is the current agent status.
	Status AgentStatus `json:"status,omitempty" yaml:"status,omitempty"`
	// Labels attached to this agent.
	Labels map[string]string `json:"labels,omitempty" yaml:"labels,omitempty"`
}

// Validate performs structural validation on the Agent spec.
func (a *Agent) Validate() error {
	if a.Name == "" {
		return ErrInvalidConfig
	}
	if a.Spec.Type == "" {
		return ErrInvalidConfig
	}
	if len(a.Spec.Triggers) == 0 {
		return fmt.Errorf("at least one trigger is required: %w", ErrInvalidConfig)
	}
	return nil
}
