package markdown

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fenceOpen = "```"

// inDir creates a temporary directory containing markdown files for testing.
// Creates parent directories as needed.
func inDir(t *testing.T, files map[string]string) (string, func()) {
	t.Helper()
	dir, err := os.MkdirTemp("", "runbook-test-*")
	if err != nil {
		t.Fatalf("mkdir temp: %v", err)
	}
	for name, content := range files {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			os.RemoveAll(dir)
			t.Fatalf("mkdir for %s: %v", name, err)
		}
		if err := os.WriteFile(path, []byte(content), 0644); err != nil {
			os.RemoveAll(dir)
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return dir, func() { os.RemoveAll(dir) }
}

func TestListRunbooks(t *testing.T) {
	t.Parallel()

	t.Run("returns .md files in directory", func(t *testing.T) {
		dir, cleanup := inDir(t, map[string]string{
			"setup.md":    "# Setup\n\n" + fenceOpen + "sh\necho hello\n```\n",
			"rollback.md": "# Rollback\n\n" + fenceOpen + "bash\nkubectl rollout undo\n```\n",
			"README.txt":  "not a runbook",
		})
		defer cleanup()

		p := NewParser(dir)
		runbooks, err := p.ListRunbooks()
		if err != nil {
			t.Fatalf("ListRunbooks: %v", err)
		}
		if len(runbooks) != 2 {
			t.Errorf("expected 2 runbooks, got %d", len(runbooks))
		}
	})

	t.Run("subdirectory markdown files are skipped", func(t *testing.T) {
		dir, cleanup := inDir(t, map[string]string{
			"subdir/ignored.md": "# ignored\n\n" + fenceOpen + "sh\necho\n```\n",
		})
		defer cleanup()

		p := NewParser(dir)
		runbooks, err := p.ListRunbooks()
		if err != nil {
			t.Fatalf("ListRunbooks: %v", err)
		}
		if len(runbooks) != 0 {
			t.Errorf("expected 0 runbooks (subdir), got %d", len(runbooks))
		}
	})

	t.Run("empty directory returns empty slice", func(t *testing.T) {
		dir, cleanup := inDir(t, nil)
		defer cleanup()

		p := NewParser(dir)
		runbooks, err := p.ListRunbooks()
		if err != nil {
			t.Fatalf("ListRunbooks: %v", err)
		}
		if len(runbooks) != 0 {
			t.Errorf("expected 0 runbooks, got %d", len(runbooks))
		}
	})

	t.Run("non-existent directory returns error", func(t *testing.T) {
		p := NewParser("/nonexistent/path")
		_, err := p.ListRunbooks()
		if err == nil {
			t.Error("expected error for non-existent directory")
		}
	})
}

func TestGetRunbook(t *testing.T) {
	t.Parallel()

	t.Run("returns valid runbook by absolute path", func(t *testing.T) {
		dir, cleanup := inDir(t, map[string]string{
			"test.md": "# Test Runbook\n\n" + fenceOpen + "sh\necho hi\n```\n",
		})
		defer cleanup()

		path := filepath.Join(dir, "test.md")
		p := NewParser(dir)
		rb, err := p.GetRunbook(path)
		if err != nil {
			t.Fatalf("GetRunbook: %v", err)
		}
		if rb.Title != "Test Runbook" {
			t.Errorf("expected 'Test Runbook', got %q", rb.Title)
		}
	})

	t.Run("returns valid runbook by relative path", func(t *testing.T) {
		dir, cleanup := inDir(t, map[string]string{
			"test.md": "# Relative\n\n" + fenceOpen + "sh\necho hi\n```\n",
		})
		defer cleanup()

		p := NewParser(dir)
		rb, err := p.GetRunbook("test.md")
		if err != nil {
			t.Fatalf("GetRunbook: %v", err)
		}
		if rb.Title != "Relative" {
			t.Errorf("expected 'Relative', got %q", rb.Title)
		}
	})

	t.Run("non-existent runbook returns error", func(t *testing.T) {
		dir, cleanup := inDir(t, nil)
		defer cleanup()

		p := NewParser(dir)
		_, err := p.GetRunbook(filepath.Join(dir, "missing.md"))
		if err == nil {
			t.Error("expected error for missing runbook")
		}
	})
}

func TestParseFile(t *testing.T) {
	t.Parallel()

	t.Run("parses code blocks", func(t *testing.T) {
		content := "# My Runbook\n\n## Step 1\n\n" +
			fenceOpen + "sh\necho hello\necho world\n```\n\n## Step 2\n\n" +
			fenceOpen + "bash\nkubectl get pods\n```\n"
		dir, cleanup := inDir(t, map[string]string{
			"runbook.md": content,
		})
		defer cleanup()

		p := NewParser(dir)
		rb, err := p.ParseFile(filepath.Join(dir, "runbook.md"))
		if err != nil {
			t.Fatalf("ParseFile: %v", err)
		}
		if len(rb.Blocks) != 2 {
			t.Fatalf("expected 2 blocks, got %d", len(rb.Blocks))
		}
		if rb.Blocks[0].Language != "sh" {
			t.Errorf("expected language 'sh', got %q", rb.Blocks[0].Language)
		}
		if rb.Blocks[0].Content != "echo hello\necho world" {
			t.Errorf("unexpected content: %q", rb.Blocks[0].Content)
		}
		if rb.Blocks[1].Language != "bash" {
			t.Errorf("expected language 'bash', got %q", rb.Blocks[1].Language)
		}
	})

	t.Run("returns title from first heading", func(t *testing.T) {
		content := "# Disaster Recovery\n\nSome text\n\n" + fenceOpen + "sh\ntrue\n```\n"
		dir, cleanup := inDir(t, map[string]string{
			"dr.md": content,
		})
		defer cleanup()

		p := NewParser(dir)
		rb, err := p.ParseFile(filepath.Join(dir, "dr.md"))
		if err != nil {
			t.Fatalf("ParseFile: %v", err)
		}
		if rb.Title != "Disaster Recovery" {
			t.Errorf("expected 'Disaster Recovery', got %q", rb.Title)
		}
	})

	t.Run("title falls back to filename when no heading", func(t *testing.T) {
		dir, cleanup := inDir(t, map[string]string{
			"no-heading.md": "Some text without heading\n\n" + fenceOpen + "sh\necho hi\n```\n",
		})
		defer cleanup()

		p := NewParser(dir)
		rb, err := p.ParseFile(filepath.Join(dir, "no-heading.md"))
		if err != nil {
			t.Fatalf("ParseFile: %v", err)
		}
		if rb.Title != "no-heading" {
			t.Errorf("expected 'no-heading', got %q", rb.Title)
		}
	})

	t.Run("empty file has no blocks", func(t *testing.T) {
		dir, cleanup := inDir(t, map[string]string{
			"empty.md": "",
		})
		defer cleanup()

		p := NewParser(dir)
		rb, err := p.ParseFile(filepath.Join(dir, "empty.md"))
		if err != nil {
			t.Fatalf("ParseFile: %v", err)
		}
		if len(rb.Blocks) != 0 {
			t.Errorf("expected 0 blocks, got %d", len(rb.Blocks))
		}
	})

	t.Run("YAML frontmatter is skipped", func(t *testing.T) {
		content := "---\ntitle: My Runbook\nauthor: test\n---\n\n# Actual Title\n\n" +
			fenceOpen + "sh\necho frontmatter-test\n```\n"
		dir, cleanup := inDir(t, map[string]string{
			"fm.md": content,
		})
		defer cleanup()

		p := NewParser(dir)
		rb, err := p.ParseFile(filepath.Join(dir, "fm.md"))
		if err != nil {
			t.Fatalf("ParseFile: %v", err)
		}
		if rb.Title != "Actual Title" {
			t.Errorf("expected 'Actual Title', got %q", rb.Title)
		}
		if len(rb.Blocks) != 1 {
			t.Errorf("expected 1 block, got %d", len(rb.Blocks))
		}
	})

	// Known limitation: the parser only produces a block when the fence is
	// both opened and closed. An unclosed fence emits no block.
	t.Run("unclosed fence produces no block", func(t *testing.T) {
		content := "# Unclosed\n\n" + fenceOpen + "sh\necho unclosed\n"
		dir, cleanup := inDir(t, map[string]string{
			"unclosed.md": content,
		})
		defer cleanup()

		p := NewParser(dir)
		rb, err := p.ParseFile(filepath.Join(dir, "unclosed.md"))
		if err != nil {
			t.Fatalf("ParseFile: %v", err)
		}
		if len(rb.Blocks) != 0 {
			t.Errorf("expected 0 blocks for unclosed fence, got %d", len(rb.Blocks))
		}
	})

	t.Run("inline code is not a fence block", func(t *testing.T) {
		content := "# Inline\n\nRun `kubectl get pods` to list pods.\n"
		dir, cleanup := inDir(t, map[string]string{
			"inline.md": content,
		})
		defer cleanup()

		p := NewParser(dir)
		rb, err := p.ParseFile(filepath.Join(dir, "inline.md"))
		if err != nil {
			t.Fatalf("ParseFile: %v", err)
		}
		if len(rb.Blocks) != 0 {
			t.Errorf("expected 0 blocks for inline-only, got %d", len(rb.Blocks))
		}
	})
}

func TestGetBlock(t *testing.T) {
	t.Parallel()

	// GetBlock calls GetRunbook -> ParseFile. The parser's blockIDCounter
	// increments on each ParseFile call. Test with a fresh parser so the
	// first parse produces predictable IDs starting at block-1.
	t.Run("round-trips block lookup with fresh parser", func(t *testing.T) {
		dir, cleanup := inDir(t, map[string]string{
			"single.md": "# Single\n\n" + fenceOpen + "sh\necho hello\n```\n",
		})
		defer cleanup()

		p := NewParser(dir)
		block, err := p.GetBlock(filepath.Join(dir, "single.md"), "block-1")
		if err != nil {
			t.Fatalf("GetBlock: %v", err)
		}
		if block.ID != "block-1" {
			t.Errorf("expected block-1, got %q", block.ID)
		}
		if block.Language != "sh" {
			t.Errorf("expected 'sh', got %q", block.Language)
		}
		if block.Content != "echo hello" {
			t.Errorf("expected 'echo hello', got %q", block.Content)
		}
	})

	t.Run("missing block ID returns error", func(t *testing.T) {
		dir, cleanup := inDir(t, map[string]string{
			"simple.md": "# Simple\n\n" + fenceOpen + "sh\nls\n```\n",
		})
		defer cleanup()

		p := NewParser(dir)
		_, err := p.GetBlock(filepath.Join(dir, "simple.md"), "nonexistent")
		if err == nil {
			t.Error("expected error for missing block ID")
		}
	})

	t.Run("missing runbook returns error", func(t *testing.T) {
		dir, cleanup := inDir(t, nil)
		defer cleanup()

		p := NewParser(dir)
		_, err := p.GetBlock(filepath.Join(dir, "missing.md"), "block-1")
		if err == nil {
			t.Error("expected error for missing runbook")
		}
	})
}

func TestExtractTooltips(t *testing.T) {
	t.Parallel()

	t.Run("returns empty for unannotated content", func(t *testing.T) {
		content := "# Plain\n\nSome text without tooltips."

		p := NewParser("/tmp")
		tooltips, err := p.ExtractTooltips(content)
		if err != nil {
			t.Fatalf("ExtractTooltips: %v", err)
		}
		if len(tooltips) != 0 {
			t.Errorf("expected 0 tooltips, got %d", len(tooltips))
		}
	})

	t.Run("extracts {: .tooltip} annotated paragraph", func(t *testing.T) {
		content := "Some intro.\n\nThis is a tooltip paragraph {: .tooltip}\n\nMore text.\n"

		p := NewParser("/tmp")
		tooltips, err := p.ExtractTooltips(content)
		if err != nil {
			t.Fatalf("ExtractTooltips: %v", err)
		}
		if len(tooltips) != 1 {
			t.Fatalf("expected 1 tooltip, got %d", len(tooltips))
		}
		if !strings.Contains(tooltips[0].Content, "This is a tooltip paragraph") {
			t.Errorf("unexpected tooltip content: %q", tooltips[0].Content)
		}
	})

	t.Run("returns empty for empty content", func(t *testing.T) {
		p := NewParser("/tmp")
		tooltips, err := p.ExtractTooltips("")
		if err != nil {
			t.Fatalf("ExtractTooltips: %v", err)
		}
		if len(tooltips) != 0 {
			t.Errorf("expected 0 tooltips, got %d", len(tooltips))
		}
	})
}

func TestExtractActions(t *testing.T) {
	t.Parallel()

	t.Run("returns empty for content without actions", func(t *testing.T) {
		content := "# No Actions\n\nJust markdown, no action blocks."

		p := NewParser("/tmp")
		actions, err := p.ExtractActions(content)
		if err != nil {
			t.Fatalf("ExtractActions: %v", err)
		}
		if len(actions) != 0 {
			t.Errorf("expected 0 actions, got %d", len(actions))
		}
	})

	t.Run("extracts action:annotated code block", func(t *testing.T) {
		content := "Before\n\n" + fenceOpen + "action:deploy sh\necho deploying\n```\n\nAfter\n"

		p := NewParser("/tmp")
		actions, err := p.ExtractActions(content)
		if err != nil {
			t.Fatalf("ExtractActions: %v", err)
		}
		if len(actions) != 1 {
			t.Fatalf("expected 1 action, got %d", len(actions))
		}
		if actions[0].Type != "deploy" {
			t.Errorf("expected type 'deploy', got %q", actions[0].Type)
		}
		if actions[0].Language != "sh" {
			t.Errorf("expected language 'sh', got %q", actions[0].Language)
		}
	})

	t.Run("extracts command:annotated code block", func(t *testing.T) {
		content := fenceOpen + `command: bash
kubectl get pods
` + fenceOpen[0:3] + `
`

		p := NewParser("/tmp")
		actions, err := p.ExtractActions(content)
		if err != nil {
			t.Fatalf("ExtractActions: %v", err)
		}
		if len(actions) != 1 {
			t.Fatalf("expected 1 action, got %d", len(actions))
		}
		if actions[0].Type != "shell" {
			t.Errorf("expected type 'shell', got %q", actions[0].Type)
		}
	})

	t.Run("returns empty for empty content", func(t *testing.T) {
		p := NewParser("/tmp")
		actions, err := p.ExtractActions("")
		if err != nil {
			t.Fatalf("ExtractActions: %v", err)
		}
		if len(actions) != 0 {
			t.Errorf("expected 0 actions, got %d", len(actions))
		}
	})

	t.Run("regular code blocks are not actions", func(t *testing.T) {
		content := fenceOpen + "sh\necho hi\n" + fenceOpen[0:3] + "\n"

		p := NewParser("/tmp")
		actions, err := p.ExtractActions(content)
		if err != nil {
			t.Fatalf("ExtractActions: %v", err)
		}
		if len(actions) != 0 {
			t.Errorf("expected 0 actions for regular code block, got %d", len(actions))
		}
	})
}

func TestExtractTitleEdgeCases(t *testing.T) {
	t.Parallel()

	t.Run("title with leading spaces", func(t *testing.T) {
		dir, cleanup := inDir(t, map[string]string{
			"spaced.md": "  # Spaced Title\n\ncontent",
		})
		defer cleanup()

		p := NewParser(dir)
		rb, err := p.ParseFile(filepath.Join(dir, "spaced.md"))
		if err != nil {
			t.Fatalf("ParseFile: %v", err)
		}
		if rb.Title != "Spaced Title" {
			t.Errorf("expected 'Spaced Title', got %q", rb.Title)
		}
	})

	t.Run("multiple headings picks first h1", func(t *testing.T) {
		content := "# First\n\nsome text\n\n# Second\n\nmore text"
		dir, cleanup := inDir(t, map[string]string{
			"multi-h1.md": content,
		})
		defer cleanup()

		p := NewParser(dir)
		rb, err := p.ParseFile(filepath.Join(dir, "multi-h1.md"))
		if err != nil {
			t.Fatalf("ParseFile: %v", err)
		}
		if rb.Title != "First" {
			t.Errorf("expected 'First', got %q", rb.Title)
		}
	})

	t.Run("h2 is not treated as title", func(t *testing.T) {
		content := "## Not a Title\n\ncontent"
		dir, cleanup := inDir(t, map[string]string{
			"h2.md": content,
		})
		defer cleanup()

		p := NewParser(dir)
		rb, err := p.ParseFile(filepath.Join(dir, "h2.md"))
		if err != nil {
			t.Fatalf("ParseFile: %v", err)
		}
		if strings.Contains(rb.Title, "Not a Title") {
			t.Errorf("h2 should not be the title, got %q", rb.Title)
		}
	})
}
