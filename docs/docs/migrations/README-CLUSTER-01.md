

# Migration: 006 CLUSTER-01 — Cluster Connection Management

## Migration Number
**006** (follows 001-005 from earlier stories)

## Bounded Context
ClusterConnect

## Description
Creates the foundational schema for the ClusterConnect bounded context. This migration enables SREs to register and manage Kubernetes cluster connections across multiple cloud providers and regions from a single board.

## Tables Created
1. `cloud_providers` — Supported cloud provider types
2. `cluster_connections` — Cluster registration and metadata
3. `cluster_credentials` — Encrypted kubeconfig storage
4. `cluster_tags` — Key-value tag system
5. `cluster_groups` — Logical cluster groupings
6. `cluster_group_members` — M2M between clusters and groups
7. `cluster_health_history` — Time-series health checks
8. `connection_audit_log` — Immutable audit trail

## Rollback
Full `DROP TABLE` cascade is provided in the DOWN section.

## Dependencies
- Requires `pgcrypto` extension (for `gen_random_uuid()`)

## Applied
YYYY-MM-DD
