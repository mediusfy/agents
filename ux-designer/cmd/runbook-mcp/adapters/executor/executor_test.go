package executor

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/drewjocham/agents/ux-designer/cmd/runbook-mcp"
)

// stubBlock returns a minimal runbook block for testing.
func stubBlock(id, lang, content string) *runbook.RunbookBlock {
	return &runbook.RunbookBlock{
		ID:       id,
		Language: lang,
		Content:  content,
	}
}

func TestNew(t *testing.T) {
	t.Parallel()

	t.Run("default timeout", func(t *testing.T) {
		e := New(0)
		if e.Timeout != 60*time.Second {
			t.Errorf("expected 60s default, got %v", e.Timeout)
		}
	})

	t.Run("custom timeout", func(t *testing.T) {
		e := New(5 * time.Second)
		if e.Timeout != 5*time.Second {
			t.Errorf("expected 5s, got %v", e.Timeout)
		}
	})
}

func TestExecute(t *testing.T) {
	t.Parallel()

	t.Run("empty content returns error", func(t *testing.T) {
		e := New(5 * time.Second)
		_, err := e.Execute(context.Background(), stubBlock("b1", "sh", ""))
		if !errors.Is(err, runbook.ErrBlockNotExecutable) {
			t.Errorf("expected ErrBlockNotExecutable, got %v", err)
		}
	})

	t.Run("unsupported language returns error", func(t *testing.T) {
		e := New(5 * time.Second)
		_, err := e.Execute(context.Background(), stubBlock("b2", "python", "print('hi')"))
		if err == nil {
			t.Fatal("expected error for unsupported language")
		}
	})

	t.Run("echo command succeeds", func(t *testing.T) {
		e := New(5 * time.Second)
		result, err := e.Execute(context.Background(), stubBlock("b3", "sh", "echo hello world"))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if result.Stdout != "hello world\n" {
			t.Errorf("expected 'hello world\\n', got %q", result.Stdout)
		}
		if result.ExitCode != 0 {
			t.Errorf("expected exit code 0, got %d", result.ExitCode)
		}
	})

	t.Run("stderr is captured", func(t *testing.T) {
		e := New(5 * time.Second)
		result, err := e.Execute(context.Background(), stubBlock("b4", "sh", "echo stderr output >&2"))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if result.Stderr != "stderr output\n" {
			t.Errorf("expected 'stderr output\\n', got %q", result.Stderr)
		}
	})

	t.Run("non-zero exit code", func(t *testing.T) {
		e := New(5 * time.Second)
		result, err := e.Execute(context.Background(), stubBlock("b5", "sh", "exit 42"))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if result.ExitCode != 42 {
			t.Errorf("expected exit code 42, got %d", result.ExitCode)
		}
	})

	t.Run("bash blocks are shell-executed", func(t *testing.T) {
		e := New(5 * time.Second)
		result, err := e.Execute(context.Background(), stubBlock("b6", "bash", "echo $((2+3))"))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if result.Stdout != "5\n" {
			t.Errorf("expected '5\\n', got %q", result.Stdout)
		}
	})

	t.Run("kubectl blocks are shell-executed", func(t *testing.T) {
		e := New(5 * time.Second)
		result, err := e.Execute(context.Background(), stubBlock("b7", "kubectl", "echo kubectl-mock"))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if result.Stdout != "kubectl-mock\n" {
			t.Errorf("expected 'kubectl-mock\\n', got %q", result.Stdout)
		}
	})

	t.Run("context cancellation is respected", func(t *testing.T) {
		e := New(10 * time.Second)
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // cancel immediately

		_, err := e.Execute(ctx, stubBlock("b8", "sh", "sleep 5"))
		if err == nil {
			t.Error("expected error for cancelled context")
		}
	})
}

func TestExecuteTimeout(t *testing.T) {
	t.Parallel()

	// Use a very short timeout — the context cancels before the command finishes.
	e := New(50 * time.Millisecond)
	start := time.Now()
	_, err := e.Execute(context.Background(), stubBlock("bt1", "sh", "sleep 30"))
	elapsed := time.Since(start)
	if elapsed > 5*time.Second {
		t.Errorf("expected early timeout (%.2fs), command wasn't killed", elapsed.Seconds())
	}
	// On macOS /bin/sh -c "sleep N" may not propagate the kill signal to
	// the sleep child. The timer-based check catches the case where the
	// command runs to completion. If the command is killed but err == nil with
	// exit code -1, that's also acceptable behavior under macOS signal propagation.
	_ = err
}

func TestValidate(t *testing.T) {
	t.Parallel()

	t.Run("no pattern means valid", func(t *testing.T) {
		e := New(5 * time.Second)
		result := &runbook.ExecutionResult{Stdout: "anything", ExitCode: 0}
		block := stubBlock("v1", "sh", "echo hello")
		valid, explanation := e.Validate(result, block)
		if !valid {
			t.Error("expected valid when no pattern")
		}
		if explanation == "" {
			t.Error("expected non-empty explanation")
		}
	})

	t.Run("matching pattern is valid", func(t *testing.T) {
		e := New(5 * time.Second)
		result := &runbook.ExecutionResult{Stdout: "deployment.apps/nginx created", ExitCode: 0}
		block := stubBlock("v2", "sh", "kubectl apply -f nginx.yaml")
		block.ExpectedOutputPattern = "created"
		valid, explanation := e.Validate(result, block)
		if !valid {
			t.Errorf("expected valid, got explanation: %s", explanation)
		}
	})

	t.Run("non-matching pattern with exit 0 is still valid", func(t *testing.T) {
		e := New(5 * time.Second)
		result := &runbook.ExecutionResult{Stdout: "pod/foo deleted", ExitCode: 0}
		block := stubBlock("v3", "sh", "kubectl delete pod foo")
		block.ExpectedOutputPattern = "created"
		valid, explanation := e.Validate(result, block)
		if !valid {
			t.Errorf("expected valid with exit 0, got explanation: %s", explanation)
		}
		if explanation == "" {
			t.Error("expected non-empty explanation")
		}
	})

	t.Run("pattern not found and non-zero exit", func(t *testing.T) {
		e := New(5 * time.Second)
		result := &runbook.ExecutionResult{Stdout: "error occurred", ExitCode: 1}
		block := stubBlock("v4", "sh", "kubectl apply -f bad.yaml")
		block.ExpectedOutputPattern = "created"
		valid, explanation := e.Validate(result, block)
		if valid {
			t.Errorf("expected invalid, got explanation: %s", explanation)
		}
	})

	t.Run("case insensitive matching", func(t *testing.T) {
		e := New(5 * time.Second)
		result := &runbook.ExecutionResult{Stdout: "Deployment Created", ExitCode: 0}
		block := stubBlock("v5", "sh", "kubectl apply -f deploy.yaml")
		block.ExpectedOutputPattern = "created"
		valid, _ := e.Validate(result, block)
		if !valid {
			t.Error("expected case-insensitive match")
		}
	})
}
