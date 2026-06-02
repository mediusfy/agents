# Rufkis Database Schema

## Migrations Ordered By Dependency

001_init.sql - Initial schema (existing, contains base utilities)
002_workload_clusters.sql - Multi-cluster registration table
003_workload_namespaces.sql - Cached K8s namespaces
004_workload_pods.sql - Cached K8s pods with inline detail fields
005_workload_deployments.sql - Cached K8s deployments
006_workload_services.sql - Cached K8s services
007_workload_events.sql - K8s events linked to workload resources
008_workload_indexes.sql - Optimized indexes for workload queries
