

# QSA File Review - 10 TypeScript Files Retrieved

Successfully retrieved all 10 TypeScript files from `/Users/jocham/programming/omni-rufkis/rufkis/` via delegation chain (testing agent → go_test agent).

## Files Retrieved with Full Contents

### Composables (kube/view/src/composables/)

1. **useDashboardMetrics.ts** - Vue composable using Pinia store for dashboard metrics with reactive timeRange, computed metrics, async fetchMetrics(), and setTimeRange().

2. **useData.ts** - Vue composable for Kubernetes watch data. Uses `useKubeWatch` to subscribe to K8s API events (ADDED/MODIFIED/DELETED/ERROR). Returns items, loading, error, errorCount refs.

3. **useGCPBootstrap.ts** - GCP cluster bootstrap composable. Provides `bootstrapGCP(projectId, region, subscriptionName)` and `pollGCPBootstrapStatus(clusterName)` using POST and useData utility.

4. **useWatcherEngine.ts** - WebSocket/polling engine. Uses Socket.IO client with fallback to HTTP polling every 5s. Token from localStorage. Subscribes to table updates via socket.io or polling.

5. **useLogs.ts** - Log viewing composable. Manages LogQuery with persistent state via localStorage. Reactive watchers for row, container, tailLines, searchTerm, logLevelFilter, follow, timestamps, previous.

### Utils (kube/view/src/utils/)

6. **logQuery.ts** - Log query utility. Zod-validated env VITE_BACKEND_URL. `queryLogs()` with fetch to backend, parseError, notificationStore/logStore integration.

7. **logHighlight.ts** - Test content only (vitest test file). Parses log lines into tokens with `{text, highlight}` for bracketed tags like [INFO], [ERROR].

8. **searchIndex.ts** - Search index class. `SearchIndexEntry` interface with name, namespace, kind, tags. Class has add/search/clear/remove/all methods with case-insensitive filtering.

9. **parseRunbookSegments.ts** - Test content only (vitest test file). Parses runbook text into segments of type 'text' or 'command' using {{CMD}} syntax.

### Store (HomePage/src/stores/)

10. **auth.ts** - Pinia auth store. login/register/logout/fetchUser/clearError. Uses localStorage for token persistence, router navigation, authService API calls.
