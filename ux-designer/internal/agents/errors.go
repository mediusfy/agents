// Package agents provides typed sentinel errors for agent lifecycle management.
package agents

import (
	"errors"
	"fmt"
)

var (
	// ErrAgentNotFound is returned when an agent is not found in the registry.
	ErrAgentNotFound = errors.New("agent not found")

	// ErrDispatchFailed is returned when dispatching an agent action fails.
	ErrDispatchFailed = errors.New("agent dispatch failed")

	// ErrCapabilityNotFound is returned when the requested capability is not registered.
	ErrCapabilityNotFound = errors.New("capability not found")

	// ErrInvalidConfig is returned when an agent configuration is invalid.
	ErrInvalidConfig = errors.New("invalid agent configuration")

	// ErrAgentDisabled is returned when attempting to trigger a disabled agent.
	ErrAgentDisabled = errors.New("agent is disabled")

	// ErrExecutionTimeout is returned when an agent action exceeds its timeout.
	ErrExecutionTimeout = errors.New("agent execution timed out")

	// ErrMaxRetriesExceeded is returned when an agent has exhausted its retry limit.
	ErrMaxRetriesExceeded = errors.New("max retries exceeded")
)

// AgentError wraps a sentinel error with additional context.
type AgentError struct {
	Op      string
	AgentID string
	Err     error
}

func (e *AgentError) Error() string {
	return fmt.Sprintf("agents: %s %s: %v", e.Op, e.AgentID, e.Err)
}

func (e *AgentError) Unwrap() error {
	return e.Err
}
