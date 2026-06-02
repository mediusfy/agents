# RUFKIS-05: GitOps-Native Remediation via PRs

## Story
As a platform engineer, I want the system to automatically create pull requests against my GitOps repository to remediate infrastructure issues, so that infrastructure fixes are transparent, auditable, and follow my existing GitOps workflow.

## Status
✅ **Done** - All documentation, schema, API spec, and frontend implementation complete.

## Context
GitOps is the standard for managing Kubernetes infrastructure. When an incident triggers a need for remediation (scaling, config fixes, security patches), operators must fork, edit, and PR the GitOps repo manually. This is slow and error-prone.

RUFKIS-05 automates this by:
1. Detecting drift/anomalies via monitoring integration
2. Generating the required YAML/JSON changes programmatically
3. Creating a PR with those changes to the designated GitOps repository
4. Tracking PR status (open, merged, failed) through its lifecycle

## Acceptance Criteria

### AC-1: Remediation Plan Creation
- The system shall accept a remediation request containing:
  - `target_repo`: The GitOps repository URL (e.g., `github.com/org/gitops-infra`)
  - `branch`: The target branch (e.g., `main`, `production`)
  - `changes`: A list of file changes (path, content, action: add/modify/delete)
  - `title`: PR title
  - `description`: PR description/body
  - `source_branch`: (Optional) Custom source branch name, auto-generated if not provided
- The system shall create a new branch from the target branch
- The system shall apply all changes to the new branch
- The system shall create a PR from the new branch to the target branch
- The system shall return a `remediation_id` and the PR URL

### AC-2: Remediation Status Tracking
- The system shall store and expose:
  - `id`: UUID of the remediation
  - `status`: One of `pending`, `open`, `merged`, `closed`, `failed`
  - `pr_url`: URL to the PR on the Git provider
  - `pr_number`: PR number assigned by the Git provider
  - `created_at`, `updated_at`: Timestamps
  - `error_message`: If status is `failed`

### AC-3: Sync PR State
- The system shall periodically sync the PR state from the Git provider (webhook or polling)
- When a PR is merged externally, the status shall update to `merged`
- When a PR is closed without merge, the status shall update to `closed`

### AC-4: List & Filter Remediations
- The system shall support listing remediations with filters:
  - By status
  - By target repository
  - By date range
- Results shall be paginated

### AC-5: Get Single Remediation
- The system shall return full details of a single remediation by ID

### AC-6: Error Handling
- If the source branch already exists, the system shall return a 409 Conflict
- If the repo is unreachable or access is denied, the system shall return a 502 Bad Gateway
- If changes contain invalid paths (path traversal), the system shall return a 400 Bad Request

## Technical Notes
- Use `libgit2` or similar for Git operations (no shell commands)
- Store repository credentials securely (vault, env vars, or k8s secrets)
- PR creation uses provider API (GitHub, GitLab, BitBucket) - abstract via provider interface
- Source branch names should be prefixed with `remediation/` followed by a short UUID
- Rate limiting: max 10 concurrent PR creations per provider

## Database Schema

### Migration 002: Remediations Core Table

```sql
CREATE TABLE remediations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target_repo TEXT NOT NULL,
    branch TEXT NOT NULL DEFAULT 'main',
    source_branch TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    changes JSONB NOT NULL DEFAULT '[]'::jsonb,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'open', 'merged', 'closed', 'failed')),
    pr_url TEXT,
    pr_number INTEGER,
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_remediations_status ON remediations(status);
CREATE INDEX idx_remediations_target_repo ON remediations(target_repo);
CREATE INDEX idx_remediations_created_at ON remediations(created_at);
```

### Migration 003: Remediation Policies & Audit Trail

```sql
CREATE TABLE remediation_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    trigger_type TEXT NOT NULL CHECK (trigger_type IN (
        'anomaly', 'drift', 'security_scan', 'manual', 'scheduled'
    )),
    target_repo TEXT NOT NULL,
    target_branch TEXT NOT NULL DEFAULT 'main',
    template JSONB NOT NULL DEFAULT '{}'::jsonb,
    max_concurrent INTEGER NOT NULL DEFAULT 5,
    auto_approve BOOLEAN NOT NULL DEFAULT false,
    approval_required BOOLEAN NOT NULL DEFAULT true,
    enabled BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE remediation_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    remediation_id UUID NOT NULL REFERENCES remediations(id) ON DELETE CASCADE,
    action TEXT NOT NULL CHECK (action IN (
        'created', 'branch_created', 'changes_applied', 'pr_created',
        'pr_merged', 'pr_closed', 'sync_requested', 'sync_completed',
        'sync_failed', 'failed', 'deleted'
    )),
    actor TEXT NOT NULL DEFAULT 'system',
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_remediation_audit_remediation_id ON remediation_audit_log(remediation_id);
CREATE INDEX idx_remediation_audit_created_at ON remediation_audit_log(created_at);
```

### Migration 004: Git Provider Credentials & Secrets

```sql
CREATE TABLE git_provider_credentials (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider TEXT NOT NULL CHECK (provider IN ('github', 'gitlab', 'bitbucket')),
    provider_url TEXT NOT NULL,
    credential_type TEXT NOT NULL CHECK (credential_type IN ('token', 'ssh_key', 'basic_auth')),
    credential_key TEXT NOT NULL,
    credential_hint TEXT NOT NULL DEFAULT '',
    organization TEXT,
    enabled BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_git_provider_unique ON git_provider_credentials(provider, provider_url, organization) WHERE enabled = true;
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | /api/v1/remediations | Create a new remediation PR |
| GET | /api/v1/remediations | List all remediations (paginated, filterable) |
| GET | /api/v1/remediations/:id | Get a single remediation by ID |
| PATCH | /api/v1/remediations/:id/status | Update remediation status |
| POST | /api/v1/remediations/:id/sync | Force sync PR state from provider |
| GET | /api/v1/remediations/:id/changes | Get the file changes for a remediation |
| DELETE | /api/v1/remediations/:id | Delete a remediation record |
| GET | /api/v1/remediation-policies | List remediation policies |
| POST | /api/v1/remediation-policies | Create a remediation policy |
| PATCH | /api/v1/remediation-policies/:id | Update a remediation policy |
| DELETE | /api/v1/remediation-policies/:id | Delete a remediation policy |
| GET | /api/v1/git-providers | List configured Git providers |
| POST | /api/v1/git-providers | Register a Git provider credential |
| DELETE | /api/v1/git-providers/:id | Remove a Git provider credential |

## Backlog / Future Work
- [ ] Webhook receiver for real-time PR state sync
- [ ] Support for multiple Git providers (GitHub, GitLab, BitBucket)
- [ ] Template-based change generation
- [ ] Dry-run mode (validate without creating PR)
- [ ] Approval gate (require manual approval before PR creation)
- [ ] Rollback PR capability
- [ ] Audit log for all remediation actions
