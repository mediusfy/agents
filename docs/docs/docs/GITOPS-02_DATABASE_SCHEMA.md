# GITOPS-02: Declarative Runbook Definitions Stored in Git
## Database Schema Documentation

### Overview
This migration adds the `gitops` schema to support the **Declarative Runbook Definitions** feature. It provides all the database infrastructure needed to store, version, validate, and discover runbook definitions that are authored as YAML files in a Git repository.

### Story Requirements Mapping

| Gherkin Requirement | Database Component | Events |
|---|---|---|
| Runbook defined in YAML | `runbook_definitions.yaml_definition` (JSONB) | |
| Committed to runbooks repo | `runbook_commits` table | gitops.RunbookCommitted |
| Validated against schema | `runbook_validation_results` table | gitops.RunbookValidated |
| Contains triggers | `runbook_triggers` table | |
| Contains steps | `runbook_steps` table | |
| Contains rollback commands | `runbook_rollback_commands` table | |
| Contains approval requirements | `runbook_approval_requirements` table | |
| Versioned with semver tags | `runbook_versions` table | gitops.RunbookVersionTagged |
| Discoverable via registry API | `runbook_registry` table | gitops.RunbookRegistered |
| PR workflow for changes | `runbook_commits` (PR fields) | |

### Entity-Relationship Diagram (Text)

```
runbook_definitions (1) ---< (N) runbook_versions
                   (1) ---< (N) runbook_triggers
                   (1) ---< (N) runbook_steps
                   (1) ---< (N) runbook_approval_requirements
                   (1) ---< (N) runbook_commits
                   (1) ---< (N) runbook_validation_results
                   (1) ---< (1) runbook_registry

runbook_steps (1) ---< (N) runbook_rollback_commands
runbook_steps (1) ---< (N) runbook_approval_requirements (via target_step_id)
```

### Tables

#### `gitops.runbook_definitions` (Core)
- **Purpose**: Central table storing each runbook's metadata and parsed YAML definition.
- **Key Columns**: `name`, `slug` (unique), `yaml_definition` (JSONB), `status`, `validation_status`, `git_repository`, `git_path`, `current_git_commit_sha`, `author`
- **Indexes**: Status, category, author, GIN on tags, GIN on yaml_definition (jsonb_path_ops), created_at DESC
- **Slug**: URL-safe unique identifier used in API paths and registry lookups
- **Status Lifecycle**: `draft` → `validated` → `active` → `deprecated` → `archived`

#### `gitops.runbook_versions` (Versioning)
- **Purpose**: Tracks every semver-tagged version of a runbook.
- **Key Columns**: `semver_major/minor/patch`, `semver_string` (e.g., "1.2.3-rc.1"), `git_tag` (e.g., "v1.2.3"), `yaml_snapshot` (immutable), `is_current`
- **Constraints**: Unique per (runbook_id, git_tag), Regex validation on semver format
- **Trigger**: When `is_current` is set to TRUE, all other versions of the same runbook are set to FALSE, and the runbook's `current_semver` is updated.

#### `gitops.runbook_triggers` (Triggers)
- **Purpose**: Defines what invokes a runbook.
- **Types**: `event`, `schedule`, `manual`, `webhook`
- **Key Columns**: `trigger_type`, `trigger_config` (JSONB — type-specific schema), `condition_expression`, `cooldown_seconds`, `max_concurrent_executions`
- **Indexes**: By type, by enabled status, GIN on trigger_config

#### `gitops.runbook_steps` (Steps)
- **Purpose**: Ordered steps comprising a runbook.
- **Key Columns**: `step_order`, `step_group`, `action_type`, `action_config` (JSONB), `timeout_seconds`, `on_failure`, `depends_on` (UUID[] for DAG), `parallel_group`
- **Action Types**: `command`, `script`, `api_call`, `approval`, `sub_runbook`, `notification`
- **Ordering**: Steps execute in ascending `step_order`. Steps in the same `parallel_group` execute concurrently.

#### `gitops.runbook_rollback_commands` (Rollbacks)
- **Purpose**: Rollback actions for a step when it fails with `on_failure = 'rollback'`.
- **Key Columns**: `rollback_order`, `command_type`, `command_config` (JSONB), `ignore_failure`, `critical`
- **Execution**: Rollbacks execute in ascending order when a step's on_failure policy is 'rollback'.

#### `gitops.runbook_approval_requirements` (Approvals)
- **Purpose**: Approval gates before/during/after runbook execution.
- **Key Columns**: `approval_stage` (pre_execution, step_gate, post_execution), `min_approvals`, `allowed_approvers` (TEXT[]), `allowed_approver_roles` (TEXT[]), `timeout_minutes`, `target_step_id`
- **Auto-approval**: Configurable via `auto_approve_after_minutes`

#### `gitops.runbook_registry` (Registry)
- **Purpose**: Makes validated runbooks discoverable via the Registry API.
- **Key Columns**: `is_discoverable`, `search_tags` (TEXT[]), `search_vector` (TSVECTOR for full-text search), `category`, `popularity_score`
- **Auto-registration**: A trigger on `runbook_definitions.validation_status` automatically registers runbooks when they pass validation.

#### `gitops.runbook_validation_results` (Validation)
- **Purpose**: Records validation results when a runbook is committed.
- **Key Columns**: `validation_status`, `validation_errors` (JSONB array), `validation_warnings` (JSONB array), `schema_version`, `git_commit_sha`, `execution_time_ms`

#### `gitops.runbook_commits` (Git Commits)
- **Purpose**: Audit trail of git commits and PRs for each runbook.
- **Key Columns**: `commit_sha`, `commit_message`, `committed_by`, `pr_number`, `pr_url`, `pr_status`, `version_tag`, `version_id`, `validation_result_id`
- **PR Workflow**: Tracks source/target branches and PR status through the workflow.

### Indexing Strategy

| Table | Index Type | Columns | Purpose |
|---|---|---|---|
| runbook_definitions | B-tree | status, validation_status | Filtering active/validated runbooks |
| runbook_definitions | GIN | tags, yaml_definition | Search & discovery |
| runbook_versions | B-tree | (runbook_id, is_current) WHERE is_current | Fast current version lookup |
| runbook_triggers | GIN | trigger_config | JSON querying for event matching |
| runbook_steps | B-tree | (runbook_id, step_order) | Ordered step retrieval |
| runbook_registry | GIN | search_vector, search_tags | Full-text search |
| runbook_registry | B-tree | popularity_score DESC | Popularity-based sorting |

### Event-Driven Triggers

1. **Auto-Registration**: When a runbook's `validation_status` transitions to `'passed'`, the `auto_register_runbook()` trigger upserts a record into `runbook_registry`.
2. **Current Version Management**: When `runbook_versions.is_current` is set to TRUE, the trigger clears the flag on all other versions and updates `runbook_definitions.current_semver`.
3. **Search Vector Updates**: Before insert/update on `runbook_registry`, the search vector is recomputed from the runbook name, description, and tags.

### Migration Files

| File | Direction | Description |
|---|---|---|
| `GITOPS-02_000_schema_setup.up.sql` | UP | Creates `gitops` schema |
| `GITOPS-02_000_schema_setup.down.sql` | DOWN | Drops `gitops` schema (no-op if other objects exist) |
| `GITOPS-02_001_runbook_definitions.up.sql` | UP | Creates all tables, enums, indexes, and triggers |
| `GITOPS-02_001_runbook_definitions.down.sql` | DOWN | Drops all tables, enums, functions, and triggers |
| `GITOPS-02_001_runbook_definitions_seed.sql` | Seed | Sample runbooks for development/testing |

### Redis Caching

See `config/redis/runbook-registry-cache.conf` for caching configuration.

### Usage Examples

**Find all active database runbooks:**
```sql
SELECT slug, display_name, current_semver
FROM gitops.runbook_definitions
WHERE status = 'active' AND category = 'database'
ORDER BY created_at DESC;
```

**Search for runbooks by text:**
```sql
SELECT rd.slug, rd.display_name, rd.current_semver, rr.popularity_score
FROM gitops.runbook_registry rr
JOIN gitops.runbook_definitions rd ON rd.id = rr.runbook_id
WHERE rr.search_vector @@ to_tsquery('english', 'failover & database')
ORDER BY rr.popularity_score DESC;
```

**Get version history for a runbook:**
```sql
SELECT semver_string, git_tag, changelog, published_at, is_current
FROM gitops.runbook_versions
WHERE runbook_id = (SELECT id FROM gitops.runbook_definitions WHERE slug = 'database-failover')
ORDER BY semver_major DESC, semver_minor DESC, semver_patch DESC;
```

**Find all runbooks with pending PRs:**
```sql
SELECT rd.slug, rc.pr_number, rc.pr_url, rc.pr_status, rc.committed_at
FROM gitops.runbook_commits rc
JOIN gitops.runbook_definitions rd ON rd.id = rc.runbook_id
WHERE rc.pr_status = 'open'
ORDER BY rc.committed_at DESC;
```
