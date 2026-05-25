

# Cross-Context Recommendations from MESSAGE-03 & NotificationDetailsEvent Review

## Findings

1. **MESSAGE-03** emits **both** `NotificationDetailsEvent` + `NotificationStatus 'Processed'` — this is architecturally correct per the event catalog and downstream consumer contracts.

2. **NotificationDetailsEvent Schema** (from event-triggers.md):
   - Event name: `messaging.NotificationDetailsEvent`
   - Version: `1.0`
   - Fields: `messageId`, `notificationType` (email|sms|push), `recipient`, `subject`, `body`, `metadata` (processingLatencyMs, originalReceivedAt, processedAt)

3. **Architecture Review Recommendation**: The `region_of_origin` field should be added to `NotificationDetails.v1` since it contains recipient PII, to comply with multi-cloud data residency constraints.

4. **MESSAGE-01 Gap**: Currently no event is emitted on message rejection. Recommendation is to emit `NotificationStatus 'Received'` immediately upon queue acceptance (MESSAGE-01), not only after processing (MESSAGE-03).
