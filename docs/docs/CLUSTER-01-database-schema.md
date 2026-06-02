

# CLUSTER-01 Database Schema — ClusterConnect Bounded Context

## Overview

**Story**: CLUSTER-01 — As an SRE, I want to connect to multiple Kubernetes clusters across different cloud providers and regions from a single board.

**Bounded Context**: ClusterConnect

This schema provides the foundational data layer for registering, authenticating, and managing Kubernetes cluster connections across multiple cloud providers (AWS EKS, GCP GKE, Azure AKS, on-prem) and regions.

## Tables

| # | Table | Description |
|---|-------|-------------|
| 1 | `cloud_providers` | Reference table of supported cloud providers (AWS, GCP, Azure, on-prem) |
| 2 | `cluster_connections` | Core aggregate root — each row represents a registered K8s cluster |
| 3 | `cluster_credentials` | Encrypted kubeconfig / service account tokens (1:1 with cluster_connections) |
| 4 | `cluster_tags` | Flexible key-value tag system for organizing clusters |
| 5 | `cluster_groups` | Logical groupings of clusters (e.g., production, staging, EU-West) |
| 6 | `cluster_group_members` | Many-to-many link between clusters and groups |
| 7 | `cluster_health_history` | Time-series health check results per cluster |
| 8 | `connection_audit_log` | Immutable audit trail for all connection events |

## Domain Events

- `ClusterRegistered` — when an SRE adds a new cluster
- `ClusterConnectionStatusChanged` — when connectivity status transitions
- `ClusterCredentialsRotated` — when credentials are updated
- `ClusterRemoved` — when a cluster is soft-deleted
- `ClusterGroupAssigned` — when cluster is added to a group
- `ClusterHealthChecked` — periodic health check result recorded

## Indexing Strategy

- Composite indexes on `cluster_connections(cloud_provider, region)` for provider-scoped queries
- Partial index on `cluster_connections WHERE deleted_at IS NULL` for active clusters
- Unique index on `cluster_connections(cluster_name, cloud_provider)` for uniqueness
- GIN index on `cluster_tags` for flexible tag-based search
- Time-series index on `cluster_health_history(cluster_id, checked_at DESC)`
- Audit log index on `connection_audit_log(cluster_id, occurred_at DESC)`

## Data Residency

The `region` column on `cluster_connections` and `cluster_groups` supports multi-region filtering. Data residency constraints are applied at the application layer per the multi-cloud constraints document.
