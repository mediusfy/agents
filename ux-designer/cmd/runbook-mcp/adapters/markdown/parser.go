// Package markdown parses Markdown runbooks and extracts executable code blocks.
package markdown

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/drewjocham/agents/ux-designer/cmd/runbook-mcp"
)

var (
	fencePattern     = regexp.MustCompile("^```(\\w+)?\\s*$")
	frontmatterPattern = regexp.MustCompile(`^---\s*$`)
	blockIDCounter   int
)

// Parser parses Markdown files into Runbook structures.
type Parser struct {
	RunbookDir string
}

// NewParser creates a Parser that looks for runbooks in the given directory.
func NewParser(runbookDir string) *Parser {
	return &Parser{RunbookDir: runbookDir}
}

// ListRunbooks discovers all Markdown runbook files in the runbook directory.
func (p *Parser) ListRunbooks() ([]runbook.Runbook, error) {
	entries, err := os.ReadDir(p.RunbookDir)
	if err != nil {
		return nil, fmt.Errorf("read runbook dir %s: %w", p.RunbookDir, runbook.ErrRunbookNotFound)
	}

	var runbooks []runbook.Runbook
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".md") {
			continue
		}
		rb, err := p.ParseFile(filepath.Join(p.RunbookDir, entry.Name()))
		if err != nil {
			continue
		}
		runbooks = append(runbooks, *rb)
	}

	return runbooks, nil
}

// GetRunbook returns a single runbook by path.
func (p *Parser) GetRunbook(path string) (*runbook.Runbook, error) {
	fullPath := path
	if !filepath.IsAbs(path) {
		fullPath = filepath.Join(p.RunbookDir, path)
	}
	return p.ParseFile(fullPath)
}

// ParseFile parses a single Markdown file into a Runbook.
func (p *Parser) ParseFile(path string) (*runbook.Runbook, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, runbook.ErrRunbookNotFound)
	}
	defer f.Close()

	rb := &runbook.Runbook{
		Path:   path,
		Blocks: make([]runbook.RunbookBlock, 0),
	}

	scanner := bufio.NewScanner(f)
	inFrontmatter := false
	inFence := false
	var currentBlock runbook.RunbookBlock
	var currentContent []string

	for scanner.Scan() {
		line := scanner.Text()

		// Detect YAML frontmatter
		if frontmatterPattern.MatchString(line) {
			if inFrontmatter {
				inFrontmatter = false
			} else if !inFence {
				inFrontmatter = true
			}
			continue
		}

		if inFrontmatter {
			continue
		}

		// Detect code fence
		if matches := fencePattern.FindStringSubmatch(line); matches != nil {
			if inFence {
				// Closing fence
				currentBlock.Content = strings.Join(currentContent, "\n")
				blockIDCounter++
				if currentBlock.ID == "" {
					currentBlock.ID = fmt.Sprintf("block-%d", blockIDCounter)
				}
				rb.Blocks = append(rb.Blocks, currentBlock)
				currentBlock = runbook.RunbookBlock{}
				currentContent = nil
				inFence = false
			} else {
				// Opening fence
				inFence = true
				currentBlock.Language = matches[1]
			}
			continue
		}

		if inFence {
			currentContent = append(currentContent, line)
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan %s: %w", path, err)
	}

	// Extract title from first heading
	rb.Title = p.extractTitle(path)

	return rb, nil
}

func (p *Parser) extractTitle(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return filepath.Base(path)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "# ") {
			return strings.TrimPrefix(line, "# ")
		}
	}

	return strings.TrimSuffix(filepath.Base(path), ".md")
}

// GetBlock returns a specific block from a runbook.
func (p *Parser) GetBlock(runbookPath, blockID string) (*runbook.RunbookBlock, error) {
	rb, err := p.GetRunbook(runbookPath)
	if err != nil {
		return nil, err
	}

	for _, block := range rb.Blocks {
		if block.ID == blockID {
			return &block, nil
		}
	}

	return nil, runbook.ErrBlockNotFound
}
