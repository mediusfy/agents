

# CLUSTERCONNECT-01 Database Schema

## Story
**CLUSTERCONNECT-01**: As an operations engineer, I want to connect to a Kubernetes cluster by providing its API endpoint and kubeconfig credentials, so that I can manage resources on that cluster through Rufkis.

## Schema Overview

The ClusterConnect bounded context consists of 7 tables:

| Table | Purpose |
|---|---|
| `cloud_providers` | Reference table for supported cloud providers (GKE, EKS, AKS, self-managed, etc.) |
| `cluster_connections` | Core table storing cluster metadata, API endpoint, and encrypted kubeconfig credentials |
| `cluster_tags` | Key/value tagging for organizing clusters |
| `cluster_groups` | Logical grouping of clusters |
| `cluster_group_members` | Many-to-many relationship between clusters and groups |
| `cluster_health_history` | Time-series tracking of connectivity health checks |
| `cluster_connection_audit_log` | Immutable audit trail for all connection CRUD operations |

## Key Design Decisions

### 1. Encrypted Kubeconfig Storage
- `cluster_connections.kubeconfig_encrypted` uses `pgcrypto` for encryption at rest
- The `kubeconfig_encryption_key_id` references an external KMS key (not stored in DB)
- A `has_valid_credentials` boolean flag allows quick filtering without decrypting

### 2. Connection Status as Enum
- `connection_status` enum: `connecting`, `connected`, `disconnected`, `error`, `unknown`
- Managed via application code with strict transitions

### 3. Audit Log Immutability
- The `cluster_connection_audit_log` table has no UPDATE or DELETE exposed via the API
- Uses a `NOT VALID` check constraint and application-layer enforcement

### 4. Health History Pruning
- `cluster_health_history` retains entries based on a configurable retention policy
- A `checked_at` index enables efficient time-range queries and pruning

### 5. Redis Caching
- Cluster connection status cached in Redis with TTL of 30 seconds
- Health check results cached with TTL of 60 seconds
- Full kubeconfig NOT cached — only metadata and status

## Indexing Strategy

| Table | Index | Type | Rationale |
|---|---|---|---|
| `cluster_connections` | `idx_cluster_connections_provider` | btree | Filter by cloud provider |
| `cluster_connections` | `idx_cluster_connections_status` | btree | Filter active/inactive connections |
| `cluster_connections` | `idx_cluster_connections_created_at` | btree | Sorting by creation date |
| `cluster_tags` | `idx_cluster_tags_cluster_id` | btree | Lookup all tags for a cluster |
| `cluster_tags` | `idx_cluster_tags_key_value` | btree | Find clusters by tag key/value |
| `cluster_group_members` | `idx_cluster_group_members_cluster` | btree | Find groups for a cluster |
| `cluster_group_members` | `idx_cluster_group_members_group` | btree | Find clusters in a group |
| `cluster_health_history` | `idx_cluster_health_history_lookup` | btree | Recent health checks per cluster |
| `cluster_connection_audit_log` | `idx_audit_log_cluster_id` | btree | All audit entries for a cluster |
| `cluster_connection_audit_log` | `idx_audit_log_timestamp` | btree | Time-based audit queries |

## Row-Level Security

- Multi-tenant: All tables have a `tenant_id` column (UUID)
- RLS policies will be applied via application middleware
- Future: PostgreSQL RLS policies based on `tenant_id`

## Encryption

Uses `pgcrypto` extension for:
- `kubeconfig_encrypted` field in `cluster_connections` (pgp_sym_encrypt / pgp_sym_decrypt)
- Encryption key managed externally (HashiCorp Vault or AWS KMS)

Migration file: `database/migrations/010_clusterconnect_01_cluster_connections.sql`
