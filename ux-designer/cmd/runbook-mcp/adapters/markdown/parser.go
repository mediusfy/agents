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
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/text"
)

var (
	fencePattern       = regexp.MustCompile("^```(\\w+)?\\s*$")
	frontmatterPattern = regexp.MustCompile(`^---\s*$`)

	// tooltipMarker matches the Kramdown-style {: .tooltip} annotation.
	tooltipMarker = regexp.MustCompile(`\{:?\s*\.tooltip\}`)

	// actionPrefixes match code block language annotations that indicate actions.
	actionPrefixes = []string{"action:", "command:"}
)

// Tooltip represents an inline annotation extracted from a runbook.
type Tooltip struct {
	Content string `json:"content"`
	BlockID int    `json:"block_id"`
}

// Action represents an executable action extracted from a runbook.
type Action struct {
	Type     string `json:"type"` // "shell", "kubectl", "runbook"
	Language string `json:"language"`
	Content  string `json:"content"`
	BlockID  int    `json:"block_id"`
}

// Parser parses Markdown files into Runbook structures.
type Parser struct {
	RunbookDir     string
	blockIDCounter int
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
				p.blockIDCounter++
				if currentBlock.ID == "" {
					currentBlock.ID = fmt.Sprintf("block-%d", p.blockIDCounter)
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

// ExtractTooltips walks the AST and finds paragraphs annotated with {: .tooltip}
// markers. Returns the text content of annotated paragraphs.
func (p *Parser) ExtractTooltips(content string) ([]Tooltip, error) {
	if content == "" {
		return nil, nil
	}

	source := []byte(content)
	reader := text.NewReader(source)
	doc := goldmark.DefaultParser().Parse(reader)

	var tooltips []Tooltip
	blockID := 0
	err := ast.Walk(doc, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}

		paragraph, ok := n.(*ast.Paragraph)
		if !ok {
			return ast.WalkContinue, nil
		}

		// Collect the paragraph text from first child Text nodes.
		// goldmark stores the raw segment in the Text node's Line field,
		// but we need to walk child text nodes. Use Value(source) for
		// inline-level Text nodes.
		var paraText strings.Builder
		for c := paragraph.FirstChild(); c != nil; c = c.NextSibling() {
			tn, ok := c.(*ast.Text)
			if !ok {
				// Raw renders or autolinks; skip
				continue
			}
			paraText.Write(tn.Value(source))
		}

		raw := paraText.String()
		if tooltipMarker.MatchString(raw) {
			blockID++
			tooltips = append(tooltips, Tooltip{
				Content: strings.TrimSpace(strings.ReplaceAll(raw, "{: .tooltip}", "")),
				BlockID: blockID,
			})
		}

		return ast.WalkContinue, nil
	})

	if err != nil {
		return nil, fmt.Errorf("walk AST for tooltips: %w", err)
	}

	return tooltips, nil
}

// ExtractActions walks the AST and finds fenced code blocks whose language
// annotation starts with "action:" or "command:". Returns the extracted actions.
func (p *Parser) ExtractActions(content string) ([]Action, error) {
	if content == "" {
		return nil, nil
	}

	source := []byte(content)
	reader := text.NewReader(source)
	doc := goldmark.DefaultParser().Parse(reader)

	var actions []Action
	blockID := 0
	err := ast.Walk(doc, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}

		fence, ok := n.(*ast.FencedCodeBlock)
		if !ok {
			return ast.WalkContinue, nil
		}

		language := string(fence.Info.Text(source))
		isAction := false
		actionType := ""
		for _, prefix := range actionPrefixes {
			if strings.HasPrefix(language, prefix) {
				isAction = true
				rest := strings.TrimPrefix(language, prefix)
				switch prefix {
				case "action:":
					parts := strings.SplitN(rest, " ", 2)
					actionType = strings.TrimSpace(parts[0])
					if len(parts) > 1 {
						language = strings.TrimSpace(parts[1])
					} else {
						language = ""
					}
				case "command:":
					actionType = "shell"
					language = strings.TrimSpace(rest)
				}
				break
			}
		}

		if !isAction {
			return ast.WalkContinue, nil
		}

		blockID++
		var contentBuilder strings.Builder
		for i := 0; i < fence.Lines().Len(); i++ {
			line := fence.Lines().At(i)
			contentBuilder.Write(line.Value(source))
		}

		actions = append(actions, Action{
			Type:     actionType,
			Language: language,
			Content:  strings.TrimRight(contentBuilder.String(), "\n"),
			BlockID:  blockID,
		})

		return ast.WalkContinue, nil
	})

	if err != nil {
		return nil, fmt.Errorf("walk AST for actions: %w", err)
	}

	return actions, nil
}
