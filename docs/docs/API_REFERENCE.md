

# API Reference — Notification Ingestion API

> **Version:** 1.0.0  
> **Base URL (production):** `https://api.example.com/v1`  
> **Base URL (development):** `http://localhost:3000`  
> **OpenAPI Spec:** [`openapi.yaml`](openapi.yaml)

---

## Table of Contents

1. [Authentication](#authentication)
2. [Endpoints](#endpoints)
   - [POST /api/notify](#post-apinotify)
   - [GET /health](#get-health)
3. [Request & Response Schemas](#request--response-schemas)
4. [Error Codes Reference](#error-codes-reference)
5. [HTTP Status Code Summary](#http-status-code-summary)
6. [FAQ / Troubleshooting](#faq--troubleshooting)
7. [Changelog](#changelog)

---

## Authentication

> **Note:** This version of the API does not require authentication.  
> Future versions may introduce API keys via the `Authorization: Bearer <token>` header.

---

## Endpoints

---

### POST /api/notify

**Description:** Ingests a new notification. Validates the input, persists it to the database, and returns the created resource.

**Operation ID:** `ingestNotification`

#### Headers

| Header         | Required | Accepted Value           | Description                    |
|----------------|----------|--------------------------|--------------------------------|
| `Content-Type` | ✅ Yes   | `application/json`       | Request body format            |
| `Accept`       | ❌ No    | `application/json`       | Response format (default)      |

#### Request Body

```json
{
  "message": "Payment of $150.00 received from Client A",
  "priority": "high"
}
```

| Field      | Type   | Required | Default  | Constraints                      | Validation Rule                    |
|------------|--------|----------|----------|----------------------------------|------------------------------------|
| `message`  | string | ✅ Yes   | —        | 1 ≤ length ≤ 1000                | Must be present and non-empty      |
| `priority` | string | ❌ No    | `medium` | Must be `low`, `medium`, or `high` | Case-sensitive enum match        |

> ⚠️ `additionalProperties` is disabled — any extra fields cause a **400 Validation Error**.

#### Successful Response (201 Created)

```json
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "message": "Payment of $150.00 received from Client A",
  "priority": "high",
  "created_at": "2026-06-02T20:45:00.123456Z"
}
```

| Field        | Type   | Description                                    |
|--------------|--------|------------------------------------------------|
| `id`         | UUID   | RFC 4122 UUID v4 assigned by the database      |
| `message`    | string | The notification message as submitted          |
| `priority`   | string | The resolved priority (submitted or default)   |
| `created_at` | string | ISO 8601 / RFC 3339 UTC timestamp              |

#### Error Responses

##### 400 Bad Request — Missing Message

```json
{
  "code": "VALIDATION_ERROR",
  "message": "The field 'message' is required.",
  "details": {
    "field": "message",
    "reason": "required"
  }
}
```

##### 400 Bad Request — Empty Message

```json
{
  "code": "VALIDATION_ERROR",
  "message": "The field 'message' must not be empty.",
  "details": {
    "field": "message",
    "reason": "minLength",
    "constraint": 1
  }
}
```

##### 400 Bad Request — Invalid Priority

```json
{
  "code": "VALIDATION_ERROR",
  "message": "The field 'priority' must be one of: low, medium, high.",
  "details": {
    "field": "priority",
    "reason": "enum",
    "allowed_values": ["low", "medium", "high"]
  }
}
```

##### 400 Bad Request — Malformed JSON

```json
{
  "code": "PARSE_ERROR",
  "message": "Request body contains invalid JSON.",
  "details": {
    "reason": "syntax_error"
  }
}
```

##### 400 Bad Request — Extra Fields (additionalProperties)

```json
{
  "code": "VALIDATION_ERROR",
  "message": "Unexpected field 'extraField' is not allowed.",
  "details": {
    "field": "extraField",
    "reason": "additional_properties_not_allowed"
  }
}
```

##### 413 Payload Too Large

```json
{
  "code": "PAYLOAD_TOO_LARGE",
  "message": "The 'message' field exceeds the maximum length of 1000 characters.",
  "details": {
    "field": "message",
    "reason": "maxLength",
    "constraint": 1000
  }
}
```

##### 415 Unsupported Media Type

```json
{
  "code": "UNSUPPORTED_MEDIA_TYPE",
  "message": "Content-Type must be application/json.",
  "details": {
    "reason": "invalid_content_type",
    "supported_types": ["application/json"]
  }
}
```

##### 429 Too Many Requests

```json
{
  "code": "RATE_LIMIT_EXCEEDED",
  "message": "Rate limit exceeded. Please retry after the specified delay.",
  "details": {
    "retry_after_seconds": 30,
    "limit": 100,
    "window": "1 minute"
  }
}
```

> **Header:** `Retry-After: 30`

##### 500 Internal Server Error

```json
{
  "code": "INTERNAL_ERROR",
  "message": "An unexpected error occurred. Please try again later.",
  "details": {
    "reason": "internal_failure"
  }
}
```

##### 503 Service Unavailable

```json
{
  "code": "SERVICE_UNAVAILABLE",
  "message": "The service is temporarily unavailable. Please retry later.",
  "details": {
    "reason": "database_connection_failed"
  }
}
```

---

### GET /health

**Description:** Returns the current health status of the API, including uptime and database connectivity. Useful for load balancer health checks and monitoring.

**Operation ID:** `checkHealth`

#### Successful Response (200 OK)

```json
{
  "status": "healthy",
  "timestamp": "2026-06-02T20:45:00.123456Z",
  "uptime_seconds": 84321,
  "database": "connected"
}
```

| Field            | Type    | Description                                    |
|------------------|---------|------------------------------------------------|
| `status`         | string  | Always `"healthy"` when the service is up      |
| `timestamp`      | string  | Current UTC time (RFC 3339)                    |
| `uptime_seconds` | integer | Seconds since the process started              |
| `database`       | string  | `"connected"` or `"disconnected"`              |

> **503 Service Unavailable** is returned if the database is unreachable.

---

## Request & Response Schemas

### NotificationRequest

```json
{
  "type": "object",
  "required": ["message"],
  "additionalProperties": false,
  "properties": {
    "message": {
      "type": "string",
      "minLength": 1,
      "maxLength": 1000,
      "description": "The notification message content"
    },
    "priority": {
      "type": "string",
      "enum": ["low", "medium", "high"],
      "default": "medium",
      "description": "Priority level of the notification"
    }
  }
}
```

### NotificationResponse

```json
{
  "type": "object",
  "required": ["id", "message", "priority", "created_at"],
  "properties": {
    "id": { "type": "string", "format": "uuid" },
    "message": { "type": "string" },
    "priority": { "type": "string", "enum": ["low", "medium", "high"] },
    "created_at": { "type": "string", "format": "date-time" }
  }
}
```

### ApiError

```json
{
  "type": "object",
  "required": ["code", "message"],
  "properties": {
    "code": {
      "type": "string",
      "description": "Machine-readable error code"
    },
    "message": {
      "type": "string",
      "description": "Human-readable error description"
    },
    "details": {
      "type": "object",
      "description": "Additional context (field, reason, constraints, etc.)"
    }
  }
}
```

---

## Error Codes Reference

| HTTP Status | `code`                   | Meaning                                        | Typical `details.reason`             |
|-------------|---------------------------|------------------------------------------------|--------------------------------------|
| 400         | `VALIDATION_ERROR`        | A request field failed validation              | `required`, `minLength`, `enum`, `additional_properties_not_allowed` |
| 400         | `PARSE_ERROR`             | The JSON body could not be parsed              | `syntax_error`                       |
| 413         | `PAYLOAD_TOO_LARGE`       | A field exceeds its maximum allowed length     | `maxLength`                          |
| 415         | `UNSUPPORTED_MEDIA_TYPE`  | `Content-Type` is not `application/json`       | `invalid_content_type`               |
| 429         | `RATE_LIMIT_EXCEEDED`     | Client has sent too many requests              | `rate_limit`                         |
| 500         | `INTERNAL_ERROR`          | Unexpected server-side failure                 | `internal_failure`                   |
| 503         | `SERVICE_UNAVAILABLE`     | Downstream dependency (DB) is unavailable      | `database_connection_failed`         |

---

## HTTP Status Code Summary

| Code | Name                  | When Used                                         |
|------|-----------------------|---------------------------------------------------|
| 200  | OK                    | Health check succeeds                             |
| 201  | Created               | Notification successfully persisted               |
| 400  | Bad Request           | Validation or parse error on the request body     |
| 413  | Payload Too Large     | Message exceeds 1000 characters                   |
| 415  | Unsupported Media Type| Wrong or missing `Content-Type` header            |
| 429  | Too Many Requests     | Rate limit exceeded                               |
| 500  | Internal Server Error | Unexpected error on the server                    |
| 503  | Service Unavailable   | Database or dependency is unreachable             |

---

## FAQ / Troubleshooting

### Q: Why am I getting a 415 error?

**A:** Ensure your request includes the header `Content-Type: application/json`. If you're using `curl`, add `-H "Content-Type: application/json"`.

### Q: Can I send extra fields in the JSON body?

**A:** No. The schema uses `additionalProperties: false`. Any extra fields will result in a **400 Validation Error**.

### Q: What happens if the database is down?

**A:** The endpoint will return a **503 Service Unavailable** error. The error response includes a `details.reason` of `database_connection_failed`.

### Q: Is the API idempotent?

**A:** No, each `POST` request creates a new notification. The caller should expect a new UUID in each response. Clients should implement retry logic with duplicate detection if needed.

### Q: What timezone is `created_at` in?

**A:** All timestamps are in **UTC** and formatted per RFC 3339 (e.g., `2026-06-02T20:45:00.123456Z`).

### Q: How do I handle rate limiting in my client?

**A:** When you receive a **429** response, check the `Retry-After` header (value in seconds) and wait before retrying. Implement exponential backoff for robustness.

---

## Changelog

### v1.0.0 (2026-06-02)

- Initial release
- `POST /api/notify` endpoint with validation
- `GET /health` endpoint
- PostgreSQL persistence with UUID primary keys
- Rate limiting (100 req/min per IP)
- Standardized error responses
