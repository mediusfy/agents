// Package ports defines the abstract interfaces for agent capabilities.
package ports

import (
	"context"
)

// Capability defines a single action an agent can perform.
type Capability interface {
	// Name returns the capability identifier.
	Name() string

	// Execute runs the capability with the given input and returns a result.
	Execute(ctx context.Context, input map[string]interface{}) (map[string]interface{}, error)
}

// AgentCapabilities groups all capabilities an agent exposes.
type AgentCapabilities struct {
	Describe   Capability
	Diagnose   Capability
	Act        Capability
	Summarize  Capability
}

// Describable agents can describe their state and purpose.
type Describable interface {
	Describe(ctx context.Context) (string, error)
}

// Diagnosable agents can diagnose issues in their watch scope.
type Diagnosable interface {
	Diagnose(ctx context.Context, resource string) ([]Diagnosis, error)
}

// Diagnosis represents the result of an agent's diagnostic analysis.
type Diagnosis struct {
	Resource  string `json:"resource"`
	Issue     string `json:"issue"`
	Severity  string `json:"severity"`
	Evidence  string `json:"evidence"`
	Remediation string `json:"remediation"`
}

// Actable agents can perform actions in their watch scope.
type Actable interface {
	Act(ctx context.Context, action Action) (ActionResult, error)
}

// Action describes a remediation action an agent can take.
type Action struct {
	Type       string                 `json:"type"`
	Target     string                 `json:"target"`
	Parameters map[string]interface{} `json:"parameters,omitempty"`
}

// ActionResult describes the outcome of an agent action.
type ActionResult struct {
	Success   bool                   `json:"success"`
	Output    string                 `json:"output"`
	Error     string                 `json:"error,omitempty"`
	Metadata  map[string]interface{} `json:"metadata,omitempty"`
}

// Summarizable agents can produce summaries of their findings.
type Summarizable interface {
	Summarize(ctx context.Context, scope string) (string, error)
}
