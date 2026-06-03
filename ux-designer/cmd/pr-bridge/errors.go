// Package prbridge implements the GitOps PR creation bridge service.
// Strategy Theme 1: GitOps-Native Remediation.
//
// Converts AI-generated YAML patches into GitHub PRs so fixes go through
// the standard code review pipeline and GitOps source of truth.
package prbridge

import (
	"errors"
	"fmt"
)

// PRRequest is the input for creating a new PR.
type PRRequest struct {
	Repo       string       `json:"repo"`
	BaseBranch string       `json:"base_branch"`
	NewBranch  string       `json:"new_branch"`
	Title      string       `json:"title"`
	Body       string       `json:"body"`
	Files      []FileChange `json:"files"`
}

// FileChange represents a single file to add/modify in the PR.
type FileChange struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

// PRResponse is returned after creating a PR.
type PRResponse struct {
	PRURL    string `json:"pr_url"`
	PRNumber int    `json:"pr_number"`
	Existing bool   `json:"existing"` // true if this PR already existed (idempotency)
}

// Sentinel errors
var (
	ErrPRCreationFailed = errors.New("PR creation failed")
	ErrBranchExists     = errors.New("branch already exists")
	ErrNoChanges        = errors.New("no changes to commit")
	ErrGitHubAuth       = errors.New("GitHub authentication failed")
	ErrRepoNotFound     = errors.New("repository not found")
	ErrInvalidRequest   = errors.New("invalid PR request")
)

// PRBridgeError wraps a sentinel error with context.
type PRBridgeError struct {
	Op    string
	Repo  string
	PRNum int
	Err   error
}

func (e *PRBridgeError) Error() string {
	return fmt.Sprintf("pr-bridge: %s repo=%s pr=%d: %v", e.Op, e.Repo, e.PRNum, e.Err)
}

func (e *PRBridgeError) Unwrap() error {
	return e.Err
}
