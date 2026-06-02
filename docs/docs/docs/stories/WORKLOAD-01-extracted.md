# WORKLOAD-01: View Pods, Deployments, and Services with Inline Detail Sheets

## User Story
As a Kubernetes operator, I want to view all pods, deployments, and services in my cluster with inline detail sheets, so that I can quickly inspect resource status without navigating away.

## Domain Analysis
This story belongs to the **WorkloadView** bounded context in the Rufkis Kubernetes Operations Console. The core entities are:

- **Cluster**: A registered Kubernetes cluster (supports multi-cloud/data-residency constraints)
- **Pod**: The smallest deployable unit of computing in Kubernetes
- **Deployment**: Declarative updates for Pods and ReplicaSets  
- **Service**: An abstraction that defines a logical set of Pods and a policy to access them
- **Event**: Kubernetes events associated with workload resources for troubleshooting

## Architectural Decision
The system uses a **CQRS pattern** with a local PostgreSQL cache:
- **Command side**: Background sync workers poll the Kubernetes API and update local tables
- **Query side**: The frontend calls REST endpoints that read from cached tables for fast, inline detail sheets
- **Why not live API calls?** Multi-cloud constraints require latency isolation; caching ensures the UI remains responsive even if a remote cluster API is slow

## Acceptance Criteria (Derived)
1. Operator can see a paginated list of all pods across namespaces
2. Operator can see a paginated list of all deployments across namespaces
3. Operator can see a paginated list of all services across namespaces
4. Clicking a resource row opens an inline detail sheet (sliding drawer) without full-page navigation
5. Detail sheet shows: status, age, labels, annotations, container images, events, conditions
6. Data is updated periodically via background sync (configurable TTL)
7. Supports multiple clusters (cluster selector in the toolbar)
