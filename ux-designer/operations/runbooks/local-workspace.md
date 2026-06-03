# Local SRE Workspace — Runbook Operations Guide

## Terminal Drawer Usage

The terminal drawer (`Ctrl+\`` to toggle) allows executing runbook commands without leaving the console.

### Opening the Terminal
1. Navigate to **Notes → Runbooks** in the left sidebar
2. Click a runbook card to open it
3. Click **▶ Run** on any executable code block
4. The terminal drawer slides up with output

### Running Commands
- Click **▶ Run** on any code block with `sh`, `bash`, `zsh`, or `kubectl` language tags
- The command executes and shows stdout/stderr in the terminal
- Exit code is displayed (green for 0, red for non-zero)
- Validation status shown when `expected_output_pattern` is defined in the block metadata

### Managing Output
- **Rerun**: Click "↻ Rerun" in the terminal header
- **Copy output**: Click "📋 Copy" to copy terminal contents to clipboard
- **Close**: Click "✕" or press `Ctrl+\`` again

## Runbook Authoring Syntax

Runbooks are Markdown files with executable code blocks. Blocks are tagged with language and optional metadata.

### Basic Format

```markdown
# My Runbook

Some context about when to use this runbook.

## Step 1: Check Status

```sh
kubectl get pods -n my-namespace
```

## Step 2: Fix It

```sh
kubectl rollout restart deployment/my-app -n my-namespace
```
```

### Annotated Blocks

Use YAML frontmatter annotations for validation:

```sh {"description":"Check pod health","expected_output_pattern":"Running"}
kubectl get pods -n my-namespace -o jsonpath='{.items[*].status.phase}'
```

### Block Attributes

| Attribute | Type | Description |
|-----------|------|-------------|
| `description` | string | Human-readable description of this step |
| `expected_output_pattern` | regex | Pattern the output should match for validation |
| `validation_rules` | string | Additional validation constraints |

## Supported Commands

The following commands are allowed in safe mode:

- `kubectl`
- `helm`
- `curl`
- `wget`
- `psql`
- `redis-cli`
- `echo`

All other commands are blocked in safe mode.

## Symptom → Diagnosis → Mitigation → Investigation → Prevention

### Symptom: High CPU waste detected
- **Diagnosis**: Check FinOps waste panel for `monthly_waste_usd_cents` > $100
- **Mitigation**: Click "Generate PR" to create right-sizing PR
- **Investigation**: Check Prometheus for actual vs requested CPU over 7 days
- **Prevention**: Set resource quotas and limit ranges per namespace

### Symptom: Anomaly alert fired
- **Diagnosis**: Check agent activity feed for auto-triage summary
- **Mitigation**: Review agent-generated root-cause in activity feed
- **Investigation**: Cross-reference with runbook for the affected resource type
- **Prevention**: Create Agent CRD watcher for this resource type

### Symptom: PR creation failed
- **Diagnosis**: Check pr-bridge logs for error sentinel
- **Mitigation**: Verify GitHub token has `repo` scope
- **Investigation**: Check if branch already exists
- **Prevention**: Add repo/branch validation middleware
