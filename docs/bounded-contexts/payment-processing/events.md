# Event Triggers — Payment Processing Bounded Context

## EVT-001: PaymentSucceeded
- **Trigger**: Payment successfully authorized and captured by upstream gateway
- **Payload**: payment_id, amount, currency, gateway_status, region_identifier, timestamp
- **Consumers**: Ordering Context (mark order paid), Audit Context (record transaction)
- **User Stories**: US-001

## EVT-002: PaymentFailed
- **Trigger (A)**: Gateway declined the payment (US-002)
- **Trigger (B)**: All retry attempts exhausted due to network latency (US-005)
- **Trigger (C)**: Data residency violation — cross-region payment rejected (US-004)
- **Trigger (D)**: Circuit breaker open state rejects payment (edge case)
- **Payload**: payment_id, reason, gateway_status, gateway_message, attempt_count, region_identifier
- **Consumers**: Notification Context (alert user), Ordering Context (rollback order)
- **User Stories**: US-002, US-005

## Internal Events (not exposed externally)

| Event | Trigger | Description |
|-------|---------|-------------|
| PaymentInitiated | Payment aggregate created | Internal state transition |
| PaymentValidated | Validation passed | Internal state transition |
| PaymentGatewayTimedOut | Gateway timeout > threshold | Triggers retry logic |
| PaymentRetryAttempted | Retry initiated | Tracks retry count for observability |
