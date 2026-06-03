// Package executor provides execution of runbook code blocks via pseudoterminal.
package executor

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"

	"github.com/drewjocham/agents/ux-designer/cmd/runbook-mcp"
)

var tracer = otel.Tracer("runbook.executor")

// Executor runs runbook code blocks.
type Executor struct {
	Timeout time.Duration
}

// New creates a new Executor with the given timeout.
func New(timeout time.Duration) *Executor {
	if timeout == 0 {
		timeout = 60 * time.Second
	}
	return &Executor{Timeout: timeout}
}

// Execute runs a runbook block and returns the result.
func (e *Executor) Execute(ctx context.Context, block *runbook.RunbookBlock) (*runbook.ExecutionResult, error) {
	ctx, span := tracer.Start(ctx, "Executor.Execute",
		trace.WithAttributes(
			attribute.String("block_id", block.ID),
			attribute.String("language", block.Language),
		))
	defer span.End()

	if block.Content == "" {
		return nil, runbook.ErrBlockNotExecutable
	}

	result := &runbook.ExecutionResult{}

	switch block.Language {
	case "sh", "bash", "zsh":
		stdout, stderr, exitCode, err := e.execShell(ctx, block.Content)
		if err != nil && exitCode == -1 {
			return nil, err
		}
		result.Stdout = stdout
		result.Stderr = stderr
		result.ExitCode = exitCode

	case "kubectl":
		// kubectl commands are shell commands
		stdout, stderr, exitCode, err := e.execShell(ctx, block.Content)
		if err != nil && exitCode == -1 {
			return nil, err
		}
		result.Stdout = stdout
		result.Stderr = stderr
		result.ExitCode = exitCode

	default:
		return nil, fmt.Errorf("unsupported language: %s: %w", block.Language, runbook.ErrExecutionFailed)
	}

	// Validate output against expected pattern
	if block.ExpectedOutputPattern != "" {
		valid, explanation := e.Validate(result, block)
		result.Validated = valid
		result.Explanation = explanation
	}

	return result, nil
}

func (e *Executor) execShell(ctx context.Context, content string) (string, string, int, error) {
	ctx, cancel := context.WithTimeout(ctx, e.Timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", content)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	exitCode := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			return "", "", -1, runbook.ErrExecutionFailed
		}
	}

	return stdout.String(), stderr.String(), exitCode, nil
}

// Validate checks if the execution output matches expected patterns.
func (e *Executor) Validate(result *runbook.ExecutionResult, block *runbook.RunbookBlock) (bool, string) {
	if block.ExpectedOutputPattern == "" {
		return true, "no validation pattern specified"
	}

	pattern := strings.ToLower(block.ExpectedOutputPattern)
	output := strings.ToLower(result.Stdout)

	if strings.Contains(output, pattern) {
		return true, "output matches expected pattern"
	}

	if result.ExitCode == 0 {
		return true, fmt.Sprintf("exit code 0 (pattern '%s' not found in output)", block.ExpectedOutputPattern)
	}

	return false, fmt.Sprintf("exit code %d and pattern '%s' not found", result.ExitCode, block.ExpectedOutputPattern)
}
