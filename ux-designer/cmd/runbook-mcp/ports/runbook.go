// Package ports defines the abstract interface for runbook operations.
package ports

import (
	"context"

	"github.com/drewjocham/agents/ux-designer/cmd/runbook-mcp"
)

// RunbookProvider defines the contract for runbook storage and retrieval.
type RunbookProvider interface {
	// List returns all available runbooks.
	List(ctx context.Context) ([]runbook.Runbook, error)

	// Get returns a specific runbook by path.
	Get(ctx context.Context, path string) (*runbook.Runbook, error)

	// GetBlock returns a specific block from a runbook.
	GetBlock(ctx context.Context, runbookPath, blockID string) (*runbook.RunbookBlock, error)
}

// BlockExecutor executes runbook blocks and returns results.
type BlockExecutor interface {
	// Execute runs a runbook block and returns the result.
	Execute(ctx context.Context, block *runbook.RunbookBlock) (*runbook.ExecutionResult, error)

	// Validate checks if the execution output matches expected patterns.
	Validate(ctx context.Context, result *runbook.ExecutionResult, block *runbook.RunbookBlock) (bool, string)
}
