// API types for all four strategy themes
export interface WasteObservation {
  id: string;
  cluster: string;
  namespace: string;
  resource_type: string;
  workload_name: string;
  container_name?: string;
  current_requests_cpu: string;
  current_requests_memory: string;
  current_limits_cpu: string;
  current_limits_memory: string;
  recommended_requests_cpu: string;
  recommended_requests_memory: string;
  recommended_limits_cpu: string;
  recommended_limits_memory: string;
  monthly_waste_usd_cents: number;
  detected_at: string;
  status: 'open' | 'actioned' | 'dismissed' | 'resolved';
}

export interface CostSavingAction {
  id: string;
  waste_observation_id: string;
  action_type: 'pr_rightsize' | 'pr_remove' | 'pr_scaledown' | 'dismiss' | 'manual';
  target_kind: string;
  target_name: string;
  recommended_savings_cents: number;
  pr_url?: string;
  pr_status: 'pending' | 'open' | 'merged' | 'closed' | 'failed';
  applied_at?: string;
}

export interface PRRequest {
  repo: string;
  base_branch: string;
  new_branch: string;
  title: string;
  body: string;
  files: FileChange[];
}

export interface FileChange {
  path: string;
  content: string;
}

export interface PRResponse {
  pr_url: string;
  pr_number: number;
  existing: boolean;
}

export interface Runbook {
  path: string;
  title: string;
  blocks: RunbookBlock[];
}

export interface RunbookBlock {
  id: string;
  language: string;
  content: string;
  expected_output_pattern?: string;
  validation_rules?: string;
  description?: string;
}

export interface ExecutionResult {
  stdout: string;
  stderr: string;
  exit_code: number;
  validated: boolean;
  explanation?: string;
}

export interface Agent {
  name: string;
  namespace: string;
  spec: AgentSpec;
  status: AgentStatus;
}

export interface AgentSpec {
  type: 'watcher' | 'scheduler' | 'analyzer' | 'integrator';
  triggers: TriggerCondition[];
  action: ActionConfig;
  watch_scope: WatchScope;
  max_retries: number;
  timeout_seconds: number;
}

export interface TriggerCondition {
  cron?: string;
  event?: string;
  manual: boolean;
}

export interface ActionConfig {
  mcp_server: string;
  capabilities: string[];
}

export interface WatchScope {
  namespaces: string[];
  resources: string[];
  labels: Record<string, string>;
}

export interface AgentStatus {
  phase: 'idle' | 'running' | 'failed' | 'disabled';
  last_triggered_at?: string;
  last_error?: string;
  execution_count: number;
  failure_count: number;
}

export interface AnomstackEvent {
  alert_id: string;
  cluster: string;
  namespace: string;
  resource_kind: string;
  name: string;
  severity: string;
  summary: string;
  timestamp: string;
}

// ──────────────────────────────────────────
// ENTITY Types (ENTITY-03: List Entities)
// ──────────────────────────────────────────

export interface Entity {
  id: string;
  name: string;
  kind: string;
  namespace: string;
  cluster: string;
  status: string;
  labels: Record<string, string>;
  annotations: Record<string, string>;
  created_at: string;
  updated_at: string;
  resource_version: string;
}

export interface PaginationMeta {
  total: number;
  page: number;
  limit: number;
  next: string | null;
  prev: string | null;
}

export interface PaginatedResponse<T> {
  items: T[];
  pagination: PaginationMeta;
}

export type EntityListResponse = PaginatedResponse<Entity>;

// ──────────────────────────────────────────
// EVENT CONSUMPTION Types (EVENT-02)
// ──────────────────────────────────────────

export type SolaceMessageDisposition = 'ack' | 'bad_request' | 'retry' | 'dead_letter';

export type SubscriptionStatus = 'disconnected' | 'connecting' | 'connected' | 'error';

export interface SolaceMessage {
  id: string;
  topic: string;
  payload: string;
  parsedPayload: Record<string, unknown> | null;
  parseError: string | null;
  disposition: SolaceMessageDisposition | null;
  dispositionReason: string | null;
  retryCount: number;
  maxRetries: number;
  receivedAt: string;
  latencyMs: number | null;
  traceId: string | null;
  spanId: string | null;
}

export interface TopicSubscription {
  id: string;
  topicPattern: string;
  status: SubscriptionStatus;
  error: string | null;
  messages: SolaceMessage[];
  connectedAt: string | null;
  disconnectedAt: string | null;
  messageCount: number;
}

export interface EventBusConfig {
  solaceHost: string;
  solaceVpn: string;
  solaceUsername: string;
  solacePasswordMasked: string;
  autoReconnect: boolean;
  maxReconnectAttempts: number;
}

export interface EventBusHealth {
  status: 'up' | 'down' | 'degraded';
  connected: boolean;
  subscriptions: number;
  uptimeSeconds: number;
  lastError: string | null;
}
