# Multi-Cloud Constraints — Payment Processing

## Data Residency Requirements

| Region | Data Store | Gateway Endpoint | Max Timeout | Regulatory Constraints |
|--------|-----------|-----------------|-------------|----------------------|
| EU | eu-west-1 | gateway-eu.payments.com | 2s | GDPR — no PII leaves EU |
| US | us-east-1 | gateway-us.payments.com | 2s | PCI-DSS — card data encrypted at rest |
| APAC | ap-southeast-1 | gateway-apac.payments.com | 5s | Local data retention laws |

## Critical Rules

1. **Payer country determines region** — not merchant location
2. **No data transfer** between regional stores for sensitive fields (PAN, CVV)
3. **Logs and events** must never contain raw PAN or CVV values
4. **Cross-region payments** require saga orchestration via control plane (no PII)
5. **Region unavailability** → reject payment, do NOT fall back to another region

## Network Latency Profiles

- EU (eu-west-1): p99 < 500ms, timeout at 2s
- US (us-east-1): p99 < 300ms, timeout at 2s
- APAC (ap-southeast-1): p99 < 2s, timeout at 5s

## Retry Configuration

| Parameter | Value |
|-----------|-------|
| Base delay | 200ms |
| Cap | 10s |
| Jitter | 10% of base interval |
| Max retries | 3 (4 total attempts including initial) |
| Backoff type | Exponential |
