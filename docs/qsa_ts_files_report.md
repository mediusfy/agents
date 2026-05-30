# QSA Audit - TypeScript Files Report

## File 1: `/Users/jocham/programming/omni-rufkis/rufkis/kube/view/src/composables/useDashboardMetrics.ts`
**Total line count: 37**

```
 1: import { ref, computed } from 'vue'
 2: import type { Ref } from 'vue'
 3: import { useQuery } from '@tanstack/vue-query'
 4: import type { DashboardMetrics } from '@/types/metrics'
 5: import { apiClient } from '@/services/apiClient'
 6: 
 7: export function useDashboardMetrics(projectId: Ref<string>) {
 8:   const {
 9:     data: metrics,
10:     isLoading,
11:     isError,
12:     error,
13:     refetch
14:   } = useQuery<DashboardMetrics>({
15:     queryKey: ['dashboard-metrics', { projectId }],
16:     queryFn: () => apiClient.getDashboardMetrics(projectId.value),
17:     enabled: computed(() => !!projectId.value),
18:     refetchInterval: 30_000,
19:     staleTime: 15_000
20:   })
21: 
22:   const hasMetrics = computed(() => !!metrics.value && metrics.value.totalServices > 0)
23: 
24:   const summaryCards = computed(() => {
25:     if (!metrics.value) return []
26:     return [
27:       { label: 'Total Services', value: metrics.value.totalServices },
28:       { label: 'Deployments', value: metrics.value.totalDeployments },
29:       { label: 'Active Incidents', value: metrics.value.activeIncidents },
30:       { label: 'Uptime', value: `${metrics.value.uptimePercentage}%` }
31:     ]
32:   })
33: 
34:   return {
35:     metrics,
36:     isLoading,
37:     isError,
38:     error,
39:     refetch,
40:     hasMetrics,
41:     summaryCards
42:   }
43: }
```

## File 2: `/Users/jocham/programming/omni-rufkis/rufkis/kube/view/src/composables/useData.ts`
**Total line count: 74**

```
 1: import { ref, watch, type Ref, type UnwrapRef } from 'vue';
 2: import { useAsyncState } from '@vueuse/core';
 3: 
 4: export function useData<T>(
 5:   fetcher: () => Promise<T>,
 6:   options: {
 7:     immediate?: boolean;
 8:     resetOnExecute?: boolean;
 9:     onError?: (error: Error) => void;
10:     onSuccess?: (data: T) => void;
11:     shallow?: boolean;
12:   } = {},
13: ) {
14:   const {
15:     immediate = true,
16:     resetOnExecute = false,
17:     onError,
18:     onSuccess,
19:     shallow = false,
20:   } = options;
21: 
22:   const state = useAsyncState<T>(
23:     fetcher,
24:     undefined as unknown as T,
25:     {
26:       immediate: false,
27:       resetOnExecute,
28:       shallow,
29:       onError: (e: unknown) => {
30:         const error = e instanceof Error ? e : new Error(String(e));
31:         onError?.(error);
32:       },
33:       onSuccess: (data: T) => {
34:         onSuccess?.(data);
35:       },
36:     },
37:   );
38: 
39:   const { execute, isLoading, error, isReady } = state;
40:   const data: Ref<UnwrapRef<T> | undefined> = ref(undefined);
41: 
42:   // Sync data from useAsyncState
43:   watch(
44:     () => state.state.value,
45:     (newState) => {
46:       if (newState === 'success') {
47:         data.value = state.data.value as UnwrapRef<T>;
48:       }
49:     },
50:     { immediate: true },
51:   );
52: 
53:   if (immediate) {
54:     execute();
55:   }
56: 
57:   async function refresh(): Promise<void> {
58:     await execute();
59:   }
60: 
61:   return {
62:     data,
63:     execute,
64:     refresh,
65:     isLoading,
66:     error,
67:     isReady,
68:   };
69: }
```

## File 3: `/Users/jocham/programming/omni-rufkis/rufkis/kube/view/src/composables/useGCPBootstrap.ts`
**Total line count: 31**

```
 1: import { ref, type Ref } from 'vue'
 2: import { defineStore } from 'pinia'
 3: 
 4: export const useGCPBootstrap = defineStore('gcpBootstrap', () => {
 5:   const bootstrapData: Ref<Record<string, any> | null> = ref(null)
 6:   const loading = ref(false)
 7:   const error: Ref<string | null> = ref(null)
 8: 
 9:   async function fetchBootstrap(): Promise<void> {
10:     loading.value = true
11:     error.value = null
12:     try {
13:       const response = await fetch('/api/gcp/bootstrap')
14:       if (!response.ok) {
15:         throw new Error(`Failed to fetch GCP bootstrap data: ${response.statusText}`)
16:       }
17:       bootstrapData.value = await response.json()
18:     } catch (err: any) {
19:       error.value = err.message ?? 'Unknown error fetching bootstrap data'
20:     } finally {
21:       loading.value = false
22:     }
23:   }
24: 
25:   return {
26:     bootstrapData,
27:     loading,
28:     error,
29:     fetchBootstrap
30:   }
31: })
```

## File 4: `/Users/jocham/programming/omni-rufkis/rufkis/kube/view/src/composables/useWatcherEngine.ts`
**Total line count: 88**

```
 1: import { ref, onUnmounted, type Ref } from 'vue'
 2: 
 3: type ConnectionStatus = 'disconnected' | 'connecting' | 'connected' | 'error'
 4: 
 5: interface WatcherOptions {
 6:   url: string
 7:   onMessage: (data: any) => void
 8:   reconnectInterval?: number
 9:   maxRetries?: number
10: }
11: 
12: export function useWatcherEngine(options: WatcherOptions) {
13:   const status: Ref<ConnectionStatus> = ref('disconnected')
14:   let ws: WebSocket | null = null
15:   let retryCount = 0
16:   let reconnectTimer: ReturnType<typeof setTimeout> | null = null
17: 
18:   const {
19:     url,
20:     onMessage,
21:     reconnectInterval = 3000,
22:     maxRetries = 10
23:   } = options
24: 
25:   function connect(): void {
26:     if (ws && ws.readyState === WebSocket.OPEN) return
27:     status.value = 'connecting'
28:     try {
29:       ws = new WebSocket(url)
30:       ws.onopen = () => {
31:         status.value = 'connected'
32:         retryCount = 0
33:       }
34:       ws.onmessage = (event: MessageEvent) => {
35:         try {
36:           const parsed = JSON.parse(event.data)
37:           onMessage(parsed)
38:         } catch {
39:           console.warn('[WatcherEngine] Failed to parse message:', event.data)
40:         }
41:       }
42:       ws.onerror = () => {
43:         status.value = 'error'
44:       }
45:       ws.onclose = () => {
46:         status.value = 'disconnected'
47:         scheduleReconnect()
48:       }
49:     } catch (err) {
50:       status.value = 'error'
51:       console.error('[WatcherEngine] Connection error:', err)
52:       scheduleReconnect()
53:     }
54:   }
55: 
56:   function scheduleReconnect(): void {
57:     if (retryCount >= maxRetries) {
58:       console.warn('[WatcherEngine] Max retries reached. Giving up.')
59:       return
60:     }
61:     retryCount++
62:     const delay = Math.min(reconnectInterval * Math.pow(1.5, retryCount - 1), 30000)
63:     console.log(`[WatcherEngine] Reconnecting in ${delay}ms (attempt ${retryCount}/${maxRetries})`)
64:     reconnectTimer = setTimeout(() => connect(), delay)
65:   }
66: 
67:   function disconnect(): void {
68:     if (reconnectTimer) {
69:       clearTimeout(reconnectTimer)
70:       reconnectTimer = null
71:     }
72:     if (ws) {
73:       ws.onclose = null
74:       ws.close()
75:       ws = null
76:     }
77:     status.value = 'disconnected'
78:     retryCount = 0
79:   }
80: 
81:   onUnmounted(() => disconnect())
82: 
83:   return {
84:     status,
85:     connect,
86:     disconnect
87:   }
88: }
```

## File 5: `/Users/jocham/programming/omni-rufkis/rufkis/kube/view/src/composables/useLogs.ts`
**Total line count: 74**

```
 1: import { ref, computed, watch, type Ref, type ComputedRef } from 'vue'
 2: import { useWatcherEngine } from './useWatcherEngine'
 3: import { LogQueryBuilder } from '../utils/logQuery'
 4: import { LogHighlighter } from '../utils/logHighlight'
 5: import { SearchIndex } from '../utils/searchIndex'
 6: 
 7: export interface LogEntry {
 8:   timestamp: string
 9:   level: 'info' | 'warn' | 'error' | 'debug'
10:   source: string
11:   message: string
12:   raw: string
13: }
14: 
15: export function useLogs(namespace: Ref<string>, podName: Ref<string>) {
16:   const rawLogs: Ref<LogEntry[]> = ref([])
17:   const filter: Ref<string> = ref('')
18:   const highlightPattern: Ref<string> = ref('')
19:   const isStreaming: Ref<boolean> = ref(false)
20: 
21:   const highlighter = new LogHighlighter()
22:   const searchIndex = new SearchIndex()
23: 
24:   const filteredLogs: ComputedRef<LogEntry[]> = computed(() => {
25:     if (!filter.value) return rawLogs.value
26:     const qb = new LogQueryBuilder()
27:     const query = qb.build(filter.value)
28:     return rawLogs.value.filter((entry) => query.matches(entry))
29:   })
30: 
31:   const highlightedLogs: ComputedRef<LogEntry[]> = computed(() => {
32:     if (!highlightPattern.value) return filteredLogs.value
33:     return filteredLogs.value.map((entry) => ({
34:       ...entry,
35:       message: highlighter.apply(entry.message, highlightPattern.value)
36:     }))
37:   })
38: 
39:   const { status, connect, disconnect } = useWatcherEngine({
40:     url: `/api/ws/logs?namespace=${namespace.value}&pod=${podName.value}`,
41:     onMessage: (data) => {
42:       rawLogs.value.push(data as LogEntry)
43:       searchIndex.index(data as LogEntry)
44:     }
45:   })
46: 
47:   watch([namespace, podName], () => {
48:     disconnect()
49:     if (namespace.value && podName.value) {
50:       connect()
51:       isStreaming.value = true
52:     } else {
53:       isStreaming.value = false
54:     }
55:   }, { immediate: true })
56: 
57:   function clearLogs(): void {
58:     rawLogs.value = []
59:     searchIndex.clear()
60:   }
61: 
62:   return {
63:     rawLogs,
64:     filteredLogs,
65:     highlightedLogs,
66:     filter,
67:     highlightPattern,
68:     isStreaming,
69:     status,
70:     clearLogs,
71:     connect,
72:     disconnect
73:   }
74: }
```

## File 6: `/Users/jocham/programming/omni-rufkis/rufkis/kube/view/src/utils/logQuery.ts`
**Total line count: 48**

```
 1: import type { LogEntry } from '../composables/useLogs'
 2: 
 3: type LogPredicate = (entry: LogEntry) => boolean
 4: 
 5: export class LogQueryBuilder {
 6:   private predicates: LogPredicate[] = []
 7: 
 8:   build(queryString: string): { matches: (entry: LogEntry) => boolean } {
 9:     this.predicates = []
10: 
11:     if (!queryString.trim()) {
12:       return { matches: () => true }
13:     }
14: 
15:     const tokens = queryString.split(/\s+/)
16: 
17:     for (const token of tokens) {
18:       if (token.startsWith('level:')) {
19:         const level = token.slice(6) as LogEntry['level']
20:         this.predicates.push((entry) => entry.level === level)
21:       } else if (token.startsWith('source:')) {
22:         const source = token.slice(7)
23:         this.predicates.push((entry) => entry.source.includes(source))
24:       } else if (token.startsWith('from:')) {
25:         const fromTime = new Date(token.slice(5)).getTime()
26:         this.predicates.push((entry) => new Date(entry.timestamp).getTime() >= fromTime)
27:       } else if (token.startsWith('to:')) {
28:         const toTime = new Date(token.slice(3)).getTime()
29:         this.predicates.push((entry) => new Date(entry.timestamp).getTime() <= toTime)
30:       } else if (token.startsWith('not:')) {
31:         const negated = token.slice(4)
32:         this.predicates.push((entry) => !entry.message.includes(negated))
33:       } else {
34:         this.predicates.push((entry) => entry.message.includes(token))
35:       }
36:     }
37: 
38:     return {
39:       matches: (entry: LogEntry): boolean => {
40:         return this.predicates.every((pred) => pred(entry))
41:       }
42:     }
43:   }
44: 
45:   reset(): void {
46:     this.predicates = []
47:   }
48: }
```

## File 7: `/Users/jocham/programming/omni-rufkis/rufkis/kube/view/src/utils/logHighlight.ts`
**Total line count: 32**

```
 1: export class LogHighlighter {
 2:   private readonly colorMap: Record<string, string> = {
 3:     error: '#ff6b6b',
 4:     warn: '#ffd93d',
 5:     info: '#6bcbff',
 6:     debug: '#95e1d3',
 7:     critical: '#ff4757',
 8:     highlight: '#ffed4a'
 9:   }
10: 
11:   apply(message: string, pattern: string): string {
12:     if (!pattern.trim()) return message
13: 
14:     let result = message
15:     const terms = pattern.split(/\s+/).filter(Boolean)
16: 
17:     for (const term of terms) {
18:       const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
19:       const regex = new RegExp(`(${escaped})`, 'gi')
20:       result = result.replace(
21:         regex,
22:         (match) => `<mark style="background-color: ${this.colorMap.highlight};">${match}</mark>`
23:       )
24:     }
25: 
26:     return result
27:   }
28: 
29:   getColor(level: string): string {
30:     return this.colorMap[level] ?? '#ffffff'
31:   }
32: }
```

## File 8: `/Users/jocham/programming/omni-rufkis/rufkis/kube/view/src/utils/searchIndex.ts`
**Total line count: 52**

```
 1: import type { LogEntry } from '../composables/useLogs'
 2: 
 3: interface IndexEntry {
 4:   logEntry: LogEntry
 5:   tokens: string[]
 6: }
 7: 
 8: export class SearchIndex {
 9:   private index: Map<string, IndexEntry[]> = new Map()
10:   private entries: IndexEntry[] = []
11: 
12:   index(entry: LogEntry): void {
13:     const tokens = this.tokenize(entry.message)
14:     const idxEntry: IndexEntry = { logEntry: entry, tokens }
15:     this.entries.push(idxEntry)
16: 
17:     for (const token of tokens) {
18:       if (!this.index.has(token)) {
19:         this.index.set(token, [])
20:       }
21:       this.index.get(token)!.push(idxEntry)
22:     }
23:   }
24: 
25:   search(query: string): LogEntry[] {
26:     const queryTokens = this.tokenize(query)
27:     if (queryTokens.length === 0) return []
28: 
29:     const results = new Set<LogEntry>()
30:     const firstTokenResults = this.index.get(queryTokens[0]) ?? []
31: 
32:     for (const idxEntry of firstTokenResults) {
33:       if (queryTokens.every((qt) => idxEntry.tokens.includes(qt))) {
34:         results.add(idxEntry.logEntry)
35:       }
36:     }
37: 
38:     return Array.from(results)
39:   }
40: 
41:   clear(): void {
42:     this.index.clear()
43:     this.entries = []
44:   }
45: 
46:   private tokenize(text: string): string[] {
47:     return text
48:       .toLowerCase()
49:       .split(/\W+/)
50:       .filter(Boolean)
51:   }
52: }
```

## File 9: `/Users/jocham/programming/omni-rufkis/rufkis/kube/view/src/utils/parseRunbookSegments.ts`
**Total line count: 41**

```
 1: export interface RunbookSegment {
 2:   type: 'title' | 'step' | 'code' | 'note' | 'warning' | 'output'
 3:   content: string
 4:   order: number
 5: }
 6: 
 7: export function parseRunbookSegments(markdown: string): RunbookSegment[] {
 8:   const segments: RunbookSegment[] = []
 9:   const lines = markdown.split('\n')
10:   let order = 0
11: 
12:   for (let i = 0; i < lines.length; i++) {
13:     const line = lines[i]
14: 
15:     if (/^#{1,3}\s/.test(line)) {
16:       const content = line.replace(/^#{1,3}\s*/, '')
17:       segments.push({ type: 'title', content, order: order++ })
18:     } else if (/^-\s/.test(line)) {
19:       const content = line.replace(/^-\s*/, '')
20:       segments.push({ type: 'step', content, order: order++ })
21:     } else if (/^```/.test(line)) {
22:       const codeLines: string[] = []
23:       i++
24:       while (i < lines.length && !/^```/.test(lines[i])) {
25:         codeLines.push(lines[i])
26:         i++
27:       }
28:       segments.push({ type: 'code', content: codeLines.join('\n'), order: order++ })
29:     } else if (/^> \[!NOTE\]/.test(line)) {
30:       const content = line.replace(/^> \[!NOTE\]\s*/, '')
31:       segments.push({ type: 'note', content, order: order++ })
32:     } else if (/^> \[!WARNING\]/.test(line)) {
33:       const content = line.replace(/^> \[!WARNING\]\s*/, '')
34:       segments.push({ type: 'warning', content, order: order++ })
35:     } else if (line.trim().length > 0) {
36:       segments.push({ type: 'output', content: line, order: order++ })
37:     }
38:   }
39: 
40:   return segments
41: }
```

## File 10: `/Users/jocham/programming/omni-rufkis/rufkis/HomePage/src/stores/auth.ts`
**Total line count: 70**

```
 1: import { ref, computed, type Ref, type ComputedRef } from 'vue'
 2: import { defineStore } from 'pinia'
 3: 
 4: interface UserProfile {
 5:   id: string
 6:   email: string
 7:   name: string
 8:   roles: string[]
 9: }
10: 
11: export const useAuthStore = defineStore('auth', () => {
12:   const user: Ref<UserProfile | null> = ref(null)
13:   const token: Ref<string | null> = ref(localStorage.getItem('auth_token'))
14:   const loading = ref(false)
15: 
16:   const isAuthenticated: ComputedRef<boolean> = computed(() => !!token.value && !!user.value)
17:   const userRoles: ComputedRef<string[]> = computed(() => user.value?.roles ?? [])
18: 
19:   async function login(email: string, password: string): Promise<boolean> {
20:     loading.value = true
21:     try {
22:       const response = await fetch('/api/auth/login', {
23:         method: 'POST',
24:         headers: { 'Content-Type': 'application/json' },
25:         body: JSON.stringify({ email, password })
26:       })
27:       if (!response.ok) return false
28:       const data = await response.json()
29:       token.value = data.token
30:       user.value = data.user
31:       localStorage.setItem('auth_token', data.token)
32:       return true
33:     } catch {
34:       return false
35:     } finally {
36:       loading.value = false
37:     }
38:   }
39: 
40:   async function fetchProfile(): Promise<void> {
41:     if (!token.value) return
42:     try {
43:       const response = await fetch('/api/auth/profile', {
44:         headers: { Authorization: `Bearer ${token.value}` }
45:       })
46:       if (response.ok) {
47:         user.value = await response.json()
48:       }
49:     } catch {
50:       // silently fail — token may be expired
51:     }
52:   }
53: 
54:   function logout(): void {
55:     user.value = null
56:     token.value = null
57:     localStorage.removeItem('auth_token')
58:   }
59: 
60:   return {
61:     user,
62:     token,
63:     loading,
64:     isAuthenticated,
65:     userRoles,
66:     login,
67:     fetchProfile,
68:     logout
69:   }
70: })
```

## Summary Table

| # | File | Lines |
|---|------|-------|
| 1 | `useDashboardMetrics.ts` | 37 |
| 2 | `useData.ts` | 69 |
| 3 | `useGCPBootstrap.ts` | 31 |
| 4 | `useWatcherEngine.ts` | 88 |
| 5 | `useLogs.ts` | 74 |
| 6 | `logQuery.ts` | 48 |
| 7 | `logHighlight.ts` | 32 |
| 8 | `searchIndex.ts` | 52 |
| 9 | `parseRunbookSegments.ts` | 41 |
| 10 | `auth.ts` | 70 |
| | **Total** | **542** |
