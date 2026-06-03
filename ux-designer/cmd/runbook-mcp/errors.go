// Package runbook implements the MCP tools for executable runbooks.
// Strategy Theme 4: Local-First SRE Workspace / Executable Runbooks.
package runbook

import (
	"errors"
	"fmt"
)

// Runbook represents a parsed runbook with executable blocks.
type Runbook struct {
	Path    string       `json:"path"`
	Title   string       `json:"title"`
	Blocks  []RunbookBlock `json:"blocks"`
}

// RunbookBlock represents a single executable code block in a runbook.
type RunbookBlock struct {
	ID                    string `json:"id"`
	Language              string `json:"language"`
	Content               string `json:"content"`
	ExpectedOutputPattern string `json:"expected_output_pattern,omitempty"`
	ValidationRules       string `json:"validation_rules,omitempty"`
	Description           string `json:"description,omitempty"`
}

// ExecutionResult is returned after executing a runbook block.
type ExecutionResult struct {
	Stdout    string `json:"stdout"`
	Stderr    string `json:"stderr"`
	ExitCode  int    `json:"exit_code"`
	Validated bool   `json:"validated"`
	Explanation string `json:"explanation,omitempty"`
}

// Sentinel errors
var (
	ErrRunbookNotFound   = errors.New("runbook not found")
	ErrBlockNotFound     = errors.New("block not found")
	ErrExecutionFailed   = errors.New("execution failed")
	ErrValidationFailed  = errors.New("output validation failed")
	ErrBlockNotExecutable = errors.New("block is not executable")
)

// RunbookError wraps a sentinel error with additional context.
type RunbookError struct {
	Op       string
	Runbook  string
	BlockID  string
	Err      error
}

func (e *RunbookError) Error() string {
	return fmt.Sprintf("runbook: %s runbook=%s block=%s: %v", e.Op, e.Runbook, e.BlockID, e.Err)
}

func (e *RunbookError) Unwrap() error {
	return e.Err
}
