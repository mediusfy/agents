// Package github implements the GitHub API adapter for PR creation.
package github

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"github.com/drewjocham/agents/ux-designer/cmd/pr-bridge"
)

var tracer = otel.Tracer("pr-bridge.github")

const githubAPIBase = "https://api.github.com"

// Client handles GitHub API interactions.
type Client struct {
	token   string
	baseURL string
	http    *http.Client
	logger  *slog.Logger
}

// NewClient creates a new GitHub client.
// Token is read from GITHUB_TOKEN environment variable.
func NewClient(logger *slog.Logger) (*Client, error) {
	token := os.Getenv("GITHUB_TOKEN")
	if token == "" {
		// Also check GH_TOKEN for compatibility
		token = os.Getenv("GH_TOKEN")
	}
	if token == "" {
		return nil, prbridge.ErrGitHubAuth
	}

	return &Client{
		token:   token,
		baseURL: githubAPIBase,
		http: &http.Client{
			Timeout: 30 * time.Second,
		},
		logger: logger,
	}, nil
}

// GitHubRef represents a git reference.
type GitHubRef struct {
	Ref    string     `json:"ref"`
	NodeID string     `json:"node_id"`
	URL    string     `json:"url"`
	Object GitHubObject `json:"object"`
}

// GitHubObject represents a git object.
type GitHubObject struct {
	SHA  string `json:"sha"`
	Type string `json:"type"`
	URL  string `json:"url"`
}

// GitHubTree represents a git tree.
type GitHubTree struct {
	SHA  string        `json:"sha"`
	URL  string        `json:"url"`
	Tree []GitHubTreeNode `json:"tree"`
	Truncated bool     `json:"truncated"`
}

// GitHubTreeNode represents a single entry in a git tree.
type GitHubTreeNode struct {
	Path string `json:"path"`
	Mode string `json:"mode"`
	Type string `json:"type"`
	SHA  string `json:"sha"`
}

// GitHubCommit represents a git commit.
type GitHubCommit struct {
	SHA    string `json:"sha"`
	URL    string `json:"url"`
	HTMLURL string `json:"html_url"`
}

// GitHubPR represents a pull request.
type GitHubPR struct {
	Number    int        `json:"number"`
	Title     string     `json:"title"`
	HTMLURL   string     `json:"html_url"`
	State     string     `json:"state"`
	Head      GitHubRef `json:"head"`
	CreatedAt time.Time `json:"created_at"`
}

// CreatePR creates a GitHub PR through the API:
// 1. Fork or verify access to the repo
// 2. Create a new branch from base
// 3. Create blobs for each file
// 4. Create a tree with the new blobs
// 5. Create a commit
// 6. Update the branch reference
// 7. Open a PR
func (c *Client) CreatePR(ctx context.Context, req prbridge.PRRequest) (*prbridge.PRResponse, error) {
	ctx, span := tracer.Start(ctx, "GitHubClient.CreatePR",
		trace.WithAttributes(
			attribute.String("repo", req.Repo),
			attribute.String("base_branch", req.BaseBranch),
			attribute.String("new_branch", req.NewBranch),
			attribute.Int("file_count", len(req.Files)),
		))
	defer span.End()

	// Check if branch already exists (idempotency)
	existingPR, err := c.findExistingPR(ctx, req.Repo, req.NewBranch)
	if err == nil && existingPR != nil {
		c.logger.InfoContext(ctx, "PR already exists, returning existing",
			slog.Int("pr_number", existingPR.Number),
			slog.String("pr_url", existingPR.HTMLURL),
		)
		return &prbridge.PRResponse{
			PRURL:    existingPR.HTMLURL,
			PRNumber: existingPR.Number,
			Existing: true,
		}, nil
	}

	// Get the base branch reference
	baseRef, err := c.getRef(ctx, req.Repo, "heads/"+req.BaseBranch)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("get base ref: %w", err)
	}

	// Create blobs for each file
	blobSHAs := make(map[string]string)
	for _, file := range req.Files {
		sha, err := c.createBlob(ctx, req.Repo, file.Content)
		if err != nil {
			span.RecordError(err)
			return nil, fmt.Errorf("create blob %s: %w", file.Path, err)
		}
		blobSHAs[file.Path] = sha
	}

	// Get the base tree
	baseTree, err := c.getTree(ctx, req.Repo, baseRef.Object.SHA)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("get base tree: %w", err)
	}

	// Build new tree with updated files
	treeNodes := make([]GitHubTreeNode, 0)
	for _, file := range req.Files {
		treeNodes = append(treeNodes, GitHubTreeNode{
			Path: file.Path,
			Mode: "100644",
			Type: "blob",
			SHA:  blobSHAs[file.Path],
		})
	}

	newTree, err := c.createTree(ctx, req.Repo, treeNodes, baseTree.SHA)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("create tree: %w", err)
	}

	// Create commit
	commitSHA, err := c.createCommit(ctx, req.Repo, req.Title+"\n\n"+req.Body, newTree.SHA, baseRef.Object.SHA)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("create commit: %w", err)
	}

	// Create branch
	if err := c.createRef(ctx, req.Repo, "refs/heads/"+req.NewBranch, commitSHA); err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("create branch: %w", err)
	}

	// Open PR
	pr, err := c.createPullRequest(ctx, req.Repo, req.Title, req.Body, req.NewBranch, req.BaseBranch)
	if err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("create PR: %w", err)
	}

	c.logger.InfoContext(ctx, "PR created",
		slog.Int("pr_number", pr.Number),
		slog.String("pr_url", pr.HTMLURL),
	)

	return &prbridge.PRResponse{
		PRURL:    pr.HTMLURL,
		PRNumber: pr.Number,
		Existing: false,
	}, nil
}

func (c *Client) getRef(ctx context.Context, repo, ref string) (*GitHubRef, error) {
	url := fmt.Sprintf("%s/repos/%s/git/%s", c.baseURL, repo, ref)
	var result GitHubRef
	if err := c.get(ctx, url, &result); err != nil {
		return nil, fmt.Errorf("get ref: %w", err)
	}
	return &result, nil
}

func (c *Client) createBlob(ctx context.Context, repo, content string) (string, error) {
	encoded := base64.StdEncoding.EncodeToString([]byte(content))
	body := map[string]interface{}{
		"content":           encoded,
		"encoding":          "base64",
	}

	url := fmt.Sprintf("%s/repos/%s/git/blobs", c.baseURL, repo)
	var result struct {
		SHA string `json:"sha"`
	}
	if err := c.post(ctx, url, body, &result); err != nil {
		return "", fmt.Errorf("create blob: %w", err)
	}
	return result.SHA, nil
}

func (c *Client) getTree(ctx context.Context, repo, commitSHA string) (*GitHubTree, error) {
	url := fmt.Sprintf("%s/repos/%s/git/commits/%s", c.baseURL, repo, commitSHA)
	var commit struct {
		Tree GitHubTree `json:"tree"`
	}
	if err := c.get(ctx, url, &commit); err != nil {
		return nil, fmt.Errorf("get commit: %w", err)
	}

	treeURL := fmt.Sprintf("%s/repos/%s/git/trees/%s?recursive=1", c.baseURL, repo, commit.Tree.SHA)
	var tree GitHubTree
	if err := c.get(ctx, treeURL, &tree); err != nil {
		return nil, fmt.Errorf("get tree: %w", err)
	}
	return &tree, nil
}

func (c *Client) createTree(ctx context.Context, repo string, tree []GitHubTreeNode, baseTreeSHA string) (*GitHubTree, error) {
	body := map[string]interface{}{
		"base_tree": baseTreeSHA,
		"tree":      tree,
	}

	url := fmt.Sprintf("%s/repos/%s/git/trees", c.baseURL, repo)
	var result GitHubTree
	if err := c.post(ctx, url, body, &result); err != nil {
		return nil, fmt.Errorf("create tree: %w", err)
	}
	return &result, nil
}

func (c *Client) createCommit(ctx context.Context, repo, message, treeSHA, parentSHA string) (string, error) {
	body := map[string]interface{}{
		"message": message,
		"tree":    treeSHA,
		"parents": []string{parentSHA},
	}

	url := fmt.Sprintf("%s/repos/%s/git/commits", c.baseURL, repo)
	var result struct {
		SHA string `json:"sha"`
	}
	if err := c.post(ctx, url, body, &result); err != nil {
		return "", fmt.Errorf("create commit: %w", err)
	}
	return result.SHA, nil
}

func (c *Client) createRef(ctx context.Context, repo, ref, sha string) error {
	body := map[string]interface{}{
		"ref": ref,
		"sha": sha,
	}

	url := fmt.Sprintf("%s/repos/%s/git/refs", c.baseURL, repo)
	var result struct{}
	if err := c.post(ctx, url, body, &result); err != nil {
		if strings.Contains(err.Error(), "Reference already exists") {
			return prbridge.ErrBranchExists
		}
		return err
	}
	return nil
}

func (c *Client) createPullRequest(ctx context.Context, repo, title, body, head, base string) (*GitHubPR, error) {
	reqBody := map[string]interface{}{
		"title": title,
		"head":  head,
		"base":  base,
		"body":  body,
	}

	url := fmt.Sprintf("%s/repos/%s/pulls", c.baseURL, repo)
	var result GitHubPR
	if err := c.post(ctx, url, reqBody, &result); err != nil {
		return nil, err
	}
	return &result, nil
}

func (c *Client) findExistingPR(ctx context.Context, repo, branch string) (*GitHubPR, error) {
	url := fmt.Sprintf("%s/repos/%s/pulls?head=%s&state=open", c.baseURL, repo, branch)
	var results []GitHubPR
	if err := c.get(ctx, url, &results); err != nil {
		return nil, err
	}
	if len(results) > 0 {
		return &results[0], nil
	}
	return nil, nil
}

func (c *Client) get(ctx context.Context, url string, result interface{}) error {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/vnd.github.v3+json")

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("github GET %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		if resp.StatusCode == 401 || resp.StatusCode == 403 {
			return prbridge.ErrGitHubAuth
		}
		return fmt.Errorf("github GET %s: %s", url, resp.Status)
	}

	return json.NewDecoder(resp.Body).Decode(result)
}

func (c *Client) post(ctx context.Context, url string, body, result interface{}) error {
	b, err := json.Marshal(body)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/vnd.github.v3+json")
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("github POST %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		if resp.StatusCode == 401 || resp.StatusCode == 403 {
			return prbridge.ErrGitHubAuth
		}
		return fmt.Errorf("github POST %s: %s", url, resp.Status)
	}

	return json.NewDecoder(resp.Body).Decode(result)
}
