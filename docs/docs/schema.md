

# Rufkis Database Schema

**Platform:** PostgreSQL 16+
**Generated:** 2026-06-02

## Overview

Rufkis uses six core tables spanning five bounded contexts for Kubernetes deployment management, collaboration, and observability.

---

## 1. `clusters` — Cluster Management Context

Stores registered Kubernetes clusters with encrypted kubeconfigs and health tracking.

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | UUID | PK, default `gen_random_uuid()` |
| `name` | VARCHAR(255) | **UNIQUE** NOT NULL |
| `encrypted_kubeconfig` | BYTEA | NOT NULL |
| `key_id` | VARCHAR(255) | NOT NULL (references external KMS key) |
| `kubeconfig_fingerprint` | VARCHAR(64) | **UNIQUE** NOT NULL |
| `server_version` | VARCHAR(64) | nullable (Kubernetes semver) |
| `status` | VARCHAR(32) | DEFAULT 'unknown' |
| `status_changed_at` | TIMESTAMPTZ | nullable |
| `last_health_check_at` | TIMESTAMPTZ | nullable |
| `consecutive_failures` | INTEGER | DEFAULT 0 |
| `health_status` | VARCHAR(32) | DEFAULT 'unknown' |
| `metadata` | JSONB | DEFAULT '{}' |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() |
| `updated_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW(), auto-updated |

**Trigger:** `trg_clusters_updated_at` — sets `updated_at = NOW()` on every UPDATE.

---

## 2. `outbox_events` — Transactional Outbox Context

Implements the transactional outbox pattern for reliable event publishing.

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | UUID | PK, default `gen_random_uuid()` |
| `event_type` | VARCHAR(255) | NOT NULL |
| `source` | VARCHAR(255) | NOT NULL |
| `specversion` | VARCHAR(8) | DEFAULT '1.0' (CloudEvents spec) |
| `datacontenttype` | VARCHAR(64) | DEFAULT 'application/json' |
| `subject` | VARCHAR(255) | nullable |
| `payload` | JSONB | NOT NULL |
| `dedup_key` | VARCHAR(64) | UNIQUE (partial, nullable) |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() |
| `published_at` | TIMESTAMPTZ | nullable (set after dispatch) |

**Index:** `idx_outbox_events_published_at` — for polling unpublished events.

---

## 3. `board_members` — Board Collaboration Context

Composite-key table mapping users to boards with role-based access.

| Column | Type | Constraints |
|--------|------|-------------|
| `board_id` | UUID | NOT NULL, part of composite PK |
| `user_id` | UUID | NOT NULL, part of composite PK |
| `role` | VARCHAR(16) | NOT NULL, CHECK IN ('viewer','editor','admin') |
| `invited_by` | UUID | NOT NULL |
| `invited_at` | TIMESTAMPTZ | DEFAULT NOW() |

**PK:** `(board_id, user_id)`

---

## 4. `comments` — Board Collaboration Context

Threaded comments on a board + resource combination.

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | UUID | PK, default `gen_random_uuid()` |
| `resource_type` | VARCHAR(64) | NOT NULL |
| `resource_fingerprint` | VARCHAR(255) | NOT NULL |
| `board_id` | UUID | NOT NULL |
| `author_id` | UUID | NOT NULL |
| `body` | TEXT | NOT NULL |
| `parent_comment_id` | UUID | nullable, FK → comments(id) ON DELETE SET NULL |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() |

**Index:** `idx_comments_board_resource(board_id, resource_fingerprint)`.

---

## 5. `notifications` — Notification Context

Per-user notifications driven by platform events.

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | UUID | PK, default `gen_random_uuid()` |
| `user_id` | UUID | NOT NULL |
| `event_type` | VARCHAR(255) | NOT NULL |
| `title` | VARCHAR(255) | NOT NULL |
| `body` | TEXT | nullable |
| `board_id` | UUID | nullable |
| `resource_fingerprint` | VARCHAR(255) | nullable |
| `is_read` | BOOLEAN | DEFAULT FALSE |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() |

**Index:** `idx_notifications_user_unread(user_id, is_read)`.

---

## 6. `audit_events` — Audit / Observability Context

Immutable audit trail for all significant platform actions.

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | UUID | PK, default `gen_random_uuid()` |
| `user_id` | UUID | nullable (system actions) |
| `action` | VARCHAR(64) | NOT NULL |
| `resource_type` | VARCHAR(64) | nullable |
| `resource_id` | VARCHAR(255) | nullable |
| `cluster_id` | UUID | nullable |
| `board_id` | UUID | nullable |
| `details` | JSONB | nullable |
| `severity` | VARCHAR(16) | DEFAULT 'info', CHECK IN ('info','warning','high','critical') |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT NOW() |

**Indexes:** `idx_audit_events_cluster_id`, `idx_audit_events_created_at`.

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| **UUID PKs everywhere** | Enables distributed ID generation without collisions; avoids sequential enumeration. |
| **`encrypted_kubeconfig` as BYTEA** | Kubeconfigs are sensitive; stored encrypted at rest. `key_id` references the external KMS key. |
| **`kubeconfig_fingerprint`** | SHA-256 fingerprint for fast dedup without decrypting. |
| **Partial unique index on `dedup_key`** | `WHERE dedup_key IS NOT NULL` — only non-null dedup keys must be unique. |
| **`parent_comment_id` self-FK** | Supports arbitrary-depth threaded replies. `ON DELETE SET NULL` preserves the thread. |
| **Composite PK on `board_members`** | Natural key for a join/mapping table; no surrogate needed. |
| **No FKs on `user_id`, `board_id`, `cluster_id`** | These reference aggregates in other bounded contexts. FKs would couple schema migrations. Referential integrity enforced at application layer. |
| **Check constraints** | Enforce domain values (`role`, `severity`) at database level as a safety net. |
