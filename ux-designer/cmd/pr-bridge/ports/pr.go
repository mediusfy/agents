// Package ports defines the abstract interface for the PR bridge.
package ports

import (
	"context"

	"github.com/drewjocham/agents/ux-designer/cmd/pr-bridge"
)

// PRService defines the contract for creating and managing PRs.
type PRService interface {
	// CreatePR creates a GitHub PR with the given files, or returns the existing PR URL.
	CreatePR(ctx context.Context, req prbridge.PRRequest) (*prbridge.PRResponse, error)

	// GetPRStatus returns the current status of a PR.
	GetPRStatus(ctx context.Context, repo string, prNumber int) (string, error)

	// ListPRs returns all open remediation PRs for a repo.
	ListPRs(ctx context.Context, repo string) ([]*prbridge.PRResponse, error)
}
