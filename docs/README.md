

# Notification Ingestion API

[![OpenAPI Specification](https://img.shields.io/badge/OpenAPI-3.0.3-blue)](docs/openapi.yaml)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

A lightweight, production-ready REST API for ingesting and persisting notifications. Built with **Node.js (Express)** and **PostgreSQL**, it validates incoming JSON payloads and returns structured, consistent responses.

## Table of Contents

- [Features](#features)
- [Architecture Overview](#architecture-overview)
- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Configuration](#configuration)
  - [Database Setup](#database-setup)
- [API Reference](#api-reference)
  - [POST /api/notify](#post-apinotify)
  - [GET /health](#get-health)
- [Usage Examples](#usage-examples)
  - [cURL](#curl)
  - [JavaScript / TypeScript](#javascript--typescript)
  - [Python](#python)
- [Error Handling](#error-handling)
- [PostgreSQL Schema](#postgresql-schema)
- [Rate Limiting](#rate-limiting)
- [Testing](#testing)
- [Deployment](#deployment)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- ✅ **Single intuitive endpoint** – `POST /api/notify` for all notification ingestion
- ✅ **Input validation** – Well-defined error responses for every invalid input scenario
- ✅ **PostgreSQL persistence** – Reliable storage with UUID primary keys and status tracking
- ✅ **Priority classification** – Low / Medium / High (defaults to Medium)
- ✅ **Health check** – `GET /health` with database connectivity status
- ✅ **Standardized error responses** – Machine-readable `code` + human-readable `message`
- ✅ **Rate limiting** – Configurable per-IP rate limiting (default: 100 req/min)
- ✅ **CORS enabled** – Ready for cross-origin clients

## Architecture Overview

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Client    │────▶│    API      │────▶│  PostgreSQL │
│ (cURL, App) │     │  (Express)  │     │             │
└─────────────┘     │             │     │  notify_db  │
                    │  Validation │     └─────────────┘
                    │  Rate Limit │
                    └─────────────┘
```

## Getting Started

### Prerequisites

- **Node.js** >= 18.x (recommended: 20 LTS)
- **PostgreSQL** >= 14.x
- **npm** or **yarn**

### Installation

```bash
git clone https://github.com/your-org/notification-ingestion-api.git
cd notification-ingestion-api
npm install
```

### Configuration

The API uses environment variables. Copy the example file and adjust:

```bash
cp .env.example .env
```

| Variable             | Default                     | Description                            |
|----------------------|-----------------------------|----------------------------------------|
| `PORT`               | `3000`                      | Server port                            |
| `DATABASE_URL`       | `postgresql://localhost:5432/notify_db` | PostgreSQL connection string |
| `RATE_LIMIT_WINDOW_MS` | `60000`                  | Rate-limit window in milliseconds      |
| `RATE_LIMIT_MAX`     | `100`                       | Max requests per window per IP         |
| `NODE_ENV`           | `development`               | Environment (`development`, `production`, `test`) |
| `LOG_LEVEL`          | `info`                      | Winston log level                      |

### Database Setup

```bash
# Create the database
createdb notify_db

# Run migrations
npx knex migrate:latest

# (Optional) Seed test data
npx knex seed:run
```

#### Migration SQL (for reference)

```sql
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS notifications (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message    TEXT NOT NULL CHECK (char_length(message) >= 1 AND char_length(message) <= 1000),
    priority   VARCHAR(10) NOT NULL DEFAULT 'medium'
               CHECK (priority IN ('low', 'medium', 'high')),
    status     VARCHAR(20) NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'processed', 'failed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_notifications_created_at ON notifications (created_at DESC);
CREATE INDEX idx_notifications_status ON notifications (status);
```

---

## API Reference

### POST /api/notify

**Endpoint:** `POST /api/notify`  
**Content-Type:** `application/json`

Ingests a new notification. The request must include a `message` field (1–1000 characters). An optional `priority` field can be set to `low`, `medium` (default), or `high`.

#### Request Body

| Field      | Type   | Required | Default  | Constraints              | Description                  |
|------------|--------|----------|----------|--------------------------|------------------------------|
| `message`  | string | ✅ Yes   | —        | 1–1000 characters        | The notification message     |
| `priority` | string | ❌ No    | `medium` | One of: `low`, `medium`, `high` | Priority level          |

#### Response: 201 Created

```json
{
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "message": "Payment of $150.00 received from Client A",
  "priority": "high",
  "created_at": "2026-06-02T20:45:00.123456Z"
}
```

#### Error Responses

| Status | Description                | Example `code`                |
|--------|----------------------------|-------------------------------|
| 400    | Validation / parse error   | `VALIDATION_ERROR`, `PARSE_ERROR` |
| 413    | Message exceeds 1000 chars | `PAYLOAD_TOO_LARGE`           |
| 415    | Wrong Content-Type         | `UNSUPPORTED_MEDIA_TYPE`      |
| 429    | Rate limit exceeded        | `RATE_LIMIT_EXCEEDED`         |
| 500    | Internal server error      | `INTERNAL_ERROR`              |
| 503    | Database unavailable       | `SERVICE_UNAVAILABLE`         |

### GET /health

Returns service health, including database connectivity.

**Response: 200 OK**

```json
{
  "status": "healthy",
  "timestamp": "2026-06-02T20:45:00.123456Z",
  "uptime_seconds": 84321,
  "database": "connected"
}
```

---

## Usage Examples

### cURL

```bash
# Successful notification (default priority)
curl -X POST http://localhost:3000/api/notify \
  -H "Content-Type: application/json" \
  -d '{"message": "User registered successfully"}'

# High-priority notification
curl -X POST http://localhost:3000/api/notify \
  -H "Content-Type: application/json" \
  -d '{"message": "Server CPU > 90%", "priority": "high"}'

# Validation error (missing message)
curl -X POST http://localhost:3000/api/notify \
  -H "Content-Type: application/json" \
  -d '{"priority": "high"}'

# Health check
curl http://localhost:3000/health
```

### JavaScript / TypeScript

```typescript
const response = await fetch("http://localhost:3000/api/notify", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    message: "Deployment completed successfully",
    priority: "low"
  })
});

const notification = await response.json();
console.log(notification.id); // "a1b2c3d4-..."
```

### Python

```python
import requests

resp = requests.post(
    "http://localhost:3000/api/notify",
    json={"message": "Payment received", "priority": "high"}
)
resp.raise_for_status()
data = resp.json()
print(data["id"])
```

---

## Error Handling

All errors follow a consistent JSON envelope:

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

| HTTP Status | Error `code`                  | When it occurs                                  |
|-------------|-------------------------------|-------------------------------------------------|
| 400         | `VALIDATION_ERROR`            | Missing/empty `message`, invalid `priority`     |
| 400         | `PARSE_ERROR`                 | Malformed JSON in request body                  |
| 413         | `PAYLOAD_TOO_LARGE`           | `message` exceeds 1000 characters               |
| 415         | `UNSUPPORTED_MEDIA_TYPE`      | `Content-Type` is not `application/json`        |
| 429         | `RATE_LIMIT_EXCEEDED`         | Client exceeded rate limit                      |
| 500         | `INTERNAL_ERROR`              | Unexpected server error                         |
| 503         | `SERVICE_UNAVAILABLE`         | Database connection failure                     |

---

## PostgreSQL Schema

### Table: `notifications`

| Column       | Type         | Constraints                                   | Description                          |
|--------------|--------------|-----------------------------------------------|--------------------------------------|
| `id`         | `UUID`       | `PRIMARY KEY DEFAULT gen_random_uuid()`       | Unique notification identifier       |
| `message`    | `TEXT`       | `NOT NULL`, `CHECK(1–1000 chars)`             | Notification content                 |
| `priority`   | `VARCHAR(10)`| `NOT NULL DEFAULT 'medium'`, `CHECK IN (...)` | Priority level                       |
| `status`     | `VARCHAR(20)`| `NOT NULL DEFAULT 'pending'`, `CHECK IN (...)`| Processing status                    |
| `created_at` | `TIMESTAMPTZ`| `NOT NULL DEFAULT NOW()`                      | Creation timestamp (UTC)             |

> 💡 **Indexes** are created on `created_at DESC` (for time-based queries) and `status` (for filtering by processing state).

---

## Rate Limiting

Rate limiting is enforced per IP address using a sliding window algorithm.

| Parameter       | Default | Description                            |
|-----------------|---------|----------------------------------------|
| Window          | 60 s    | Time window for rate counting          |
| Max requests    | 100     | Maximum requests per window per IP     |
| Response header | `Retry-After` | Seconds until the client can retry |

When the limit is exceeded, the endpoint returns `429 Too Many Requests`.

---

## Testing

```bash
# Unit & integration tests
npm test

# Test with coverage
npm run test:coverage

# Lint
npm run lint
```

The test suite validates:
- Successful notification creation (201)
- Missing message (400)
- Empty message (400)
- Invalid priority (400)
- Malformed JSON (400)
- Wrong Content-Type (415)
- Oversized message (413)
- Rate limiting (429)
- Database failure handling (503)
- Health check endpoint (200)

---

## Deployment

### Docker (recommended)

```bash
docker-compose up --build
```

### Manual

```bash
npm run build
npm start
```

**Important for production:**
- Set `NODE_ENV=production`
- Use a managed PostgreSQL instance (RDS, Cloud SQL, etc.)
- Enable HTTPS via a reverse proxy (nginx, Caddy, or a cloud load balancer)
- Configure proper logging and monitoring (e.g., Winston + Datadog/Prometheus)
- Set up auto-scaling based on CPU/memory and rate-limit thresholds

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feat/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push (`git push origin feat/amazing-feature`)
5. Open a Pull Request

Please ensure all tests pass and coverage does not decrease.

---

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for more information.
