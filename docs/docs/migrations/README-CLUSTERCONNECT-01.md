

# CLUSTERCONNECT-01: Cluster Connection Management
# ===================================================
#
# Story: As an operations engineer, I want to connect to a Kubernetes cluster
#        by providing its API endpoint and kubeconfig credentials, so that I
#        can manage resources on that cluster through Rufkis.
#
# Migration: database/migrations/010_clusterconnect_01_cluster_connections.sql
# Seeds:     database/seeds/010_clusterconnect_01_seed.sql
# Redis:     infrastructure/redis/clusterconnect-cache.conf
#
# Bounded Context: ClusterConnect
#
# ## Tables
#
# | # | Table | Description |
# |---|-------|-------------|
# | 1 | `cloud_providers` | Reference: GKE, EKS, AKS, self-managed, etc. |
# | 2 | `cluster_connections` | Core: cluster metadata, endpoint, encrypted kubeconfig |
# | 3 | `cluster_tags` | Key/value tagging for cluster organization |
# | 4 | `cluster_groups` | Logical grouping of clusters |
# | 5 | `cluster_group_members` | Many-to-many: clusters ↔ groups |
# | 6 | `cluster_health_history` | Time-series connectivity health checks |
# | 7 | `cluster_connection_audit_log` | Immutable audit trail for all operations |
#
# ## Key Design Points
#
# - **Encryption**: kubeconfig stored with pgcrypto (pgp_sym_encrypt), key ID
#   stored separately for external KMS (HashiCorp Vault / AWS KMS).
# - **Multi-tenant**: All multi-tenant tables have a `tenant_id` column for
#   future RLS enforcement.
# - **Status tracking**: Connection status enum with strict transitions managed
#   at the application layer.
# - **Health monitoring**: Append-only health history table with latency tracking
#   for SRE dashboards and alerting.
# - **Audit**: Every CRUD operation is logged with actor, action, changes, and
#   source IP for compliance and debuggability.
#
# ## Redis Caching
#
# Cluster status and health are cached to reduce DB load:
#   - `cluster:status:{cluster_id}` → TTL 30s
#   - `cluster:health:{cluster_id}` → TTL 60s
#   - `cluster:summary:{tenant_id}` → TTL 60s
#
# ## Usage
#
# Apply migration:
#   psql -d rufkis -f database/migrations/010_clusterconnect_01_cluster_connections.sql
#
# Seed data:
#   psql -d rufkis -f database/seeds/010_clusterconnect_01_seed.sql
