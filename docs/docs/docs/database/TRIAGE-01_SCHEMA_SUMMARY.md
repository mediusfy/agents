

# TRIAGE-01: AI-Powered Incident Triage — Schema Summary

## Overview

This schema supports the AI-powered incident triage system. When an alert or incident
notification arrives from any monitoring source, the triage agent classifies it with
severity (P0–P4), assigns ownership to the most likely SRE team/service based on
historical patterns and service topology, and extracts structured data (affected service,
error signature, time range, customer impact). Classifications with confidence < 80%
are flagged for human review.

## Events

| Event | Trigger | Description |
|-------|---------|-------------|
| `triage.IncidentClassified` | INSERT on `incident_classifications` | Published when AI triage agent classifies an incident |
| `triage.IncidentFlaggedForReview` | INSERT on `human_review_flags` | Published when confidence < 80% |

## Entity Relationship

```
monitoring_sources (1)───< (N) incidents
sre_teams (1)───< (N) incidents (assigned_team_id)
services (1)───< (N) incidents (affected_service_id)
services (1)───< (N) incidents (assigned_service_id)
services (1)───< (N) service_dependencies (source_service_id)
services (1)───< (N) service_dependencies (target_service_id)
incidents (1)───< (N) incident_classifications
incidents (1)───< (N) extracted_incident_data
incidents (1)───< (N) human_review_flags
```

## Tables

### `monitoring_sources`
Reference table of monitoring/alerting sources.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| name | VARCHAR(100) UNIQUE NOT NULL | Source name (e.g. Prometheus, Datadog, PagerDuty) |
| description | TEXT | Optional description |
| is_active | BOOLEAN DEFAULT true | Whether this source is active |
| created_at | TIMESTAMPTZ | Row creation timestamp |
| updated_at | TIMESTAMPTZ | Row update timestamp |

### `sre_teams`
Reference table of SRE teams that can own incidents.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| name | VARCHAR(100) UNIQUE NOT NULL | Team name (e.g. "Infra SRE", "Platform SRE") |
| slack_channel | VARCHAR(100) | Primary Slack channel for the team |
| pagerduty_escalation_policy | VARCHAR(100) | PagerDuty escalation policy ID |
| is_active | BOOLEAN DEFAULT true | Whether the team is active |
| created_at | TIMESTAMPTZ | Row creation timestamp |
| updated_at | TIMESTAMPTZ | Row update timestamp |

### `services`
Reference table of monitored services in the service topology.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| name | VARCHAR(200) UNIQUE NOT NULL | Service name |
| description | TEXT | Service description |
| team_id | UUID FK → sre_teams(id) | Owning SRE team |
| is_active | BOOLEAN DEFAULT true | Whether this service is active |
| created_at | TIMESTAMPTZ | Row creation timestamp |
| updated_at | TIMESTAMPTZ | Row update timestamp |

### `service_dependencies`
Service topology: directional dependency graph between services.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| source_service_id | UUID FK → services(id) NOT NULL | Upstream/dependent service |
| target_service_id | UUID FK → services(id) NOT NULL | Downstream/required service |
| dependency_type | VARCHAR(50) DEFAULT 'hard' | 'hard', 'soft', 'circuit_breaker' |
| is_active | BOOLEAN DEFAULT true | Whether this dependency is active |
| created_at | TIMESTAMPTZ | Row creation timestamp |
| updated_at | TIMESTAMPTZ | Row update timestamp |

**Unique constraint**: (source_service_id, target_service_id)

### `incidents`
Core table — each row represents an incoming alert/incident notification.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| external_id | VARCHAR(255) | ID from the monitoring source (e.g. Alertmanager alert ID) |
| monitoring_source_id | UUID FK → monitoring_sources(id) | Source of the alert |
| title | TEXT NOT NULL | Alert/incident title |
| raw_payload | JSONB | Full raw payload from the monitoring source |
| received_at | TIMESTAMPTZ NOT NULL DEFAULT NOW() | When the incident was received |
| status | incident_status NOT NULL DEFAULT 'new' | 'new', 'classified', 'flagged', 'resolved' |
| created_at | TIMESTAMPTZ | Row creation timestamp |
| updated_at | TIMESTAMPTZ | Row update timestamp |

**Indexes**: (external_id), (status), (received_at), (monitoring_source_id)

### `incident_classifications`
Each row represents a single classification event by the AI triage agent.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| incident_id | UUID FK → incidents(id) NOT NULL | The incident being classified |
| severity | severity_level NOT NULL | P0, P1, P2, P3, P4 |
| confidence_score | NUMERIC(5,2) NOT NULL CHECK (0 <= confidence_score AND confidence_score <= 100) | AI confidence percentage |
| assigned_team_id | UUID FK → sre_teams(id) | Most likely owning SRE team |
| assigned_service_id | UUID FK → services(id) | Most likely owning service |
| classification_reason | TEXT | LLM/Model reasoning for the classification |
| model_version | VARCHAR(100) | Version of the AI model used |
| is_low_confidence | BOOLEAN GENERATED ALWAYS AS (confidence_score < 80) STORED | Whether flagged for review |
| classified_at | TIMESTAMPTZ NOT NULL DEFAULT NOW() | When classification happened |
| created_at | TIMESTAMPTZ | Row creation timestamp |

**Indexes**: (incident_id), (severity), (confidence_score), (assigned_team_id), (assigned_service_id), (classified_at), (is_low_confidence) WHERE is_low_confidence = true

### `extracted_incident_data`
Structured data extracted from the incident by the AI triage agent.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| incident_id | UUID FK → incidents(id) NOT NULL | The incident |
| classification_id | UUID FK → incident_classifications(id) | The classification this extraction belongs to |
| affected_service | VARCHAR(200) | Extracted affected service name |
| error_signature | TEXT | Normalized error signature/keywords |
| time_range_start | TIMESTAMPTZ | Start of the impact time window |
| time_range_end | TIMESTAMPTZ | End of the impact time window |
| customer_impact | TEXT | Description of customer impact |
| additional_context | JSONB | Any other extracted structured data |
| created_at | TIMESTAMPTZ | Row creation timestamp |

**Indexes**: (incident_id), (classification_id)

### `human_review_flags`
Records incidents flagged for human review due to low confidence.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| incident_id | UUID FK → incidents(id) NOT NULL | The flagged incident |
| classification_id | UUID FK → incident_classifications(id) NOT NULL | The low-confidence classification |
| confidence_score | NUMERIC(5,2) NOT NULL | The confidence that triggered the flag |
| review_status | review_status NOT NULL DEFAULT 'pending' | 'pending', 'in_review', 'approved', 'overridden' |
| reviewed_by | VARCHAR(100) | Human reviewer identifier |
| reviewed_at | TIMESTAMPTZ | When the review was completed |
| reviewer_notes | TEXT | Notes from the human reviewer |
| corrected_severity | severity_level | Corrected severity if overridden |
| corrected_team_id | UUID FK → sre_teams(id) | Corrected team if overridden |
| corrected_service_id | UUID FK → services(id) | Corrected service if overridden |
| created_at | TIMESTAMPTZ | Row creation timestamp |
| updated_at | TIMESTAMPTZ | Row update timestamp |

**Indexes**: (incident_id), (classification_id), (review_status), (confidence_score)

### `classification_outbox`
Transactional outbox pattern for publishing `triage.IncidentClassified` and `triage.IncidentFlaggedForReview` events.

| Column | Type | Description |
|--------|------|-------------|
| id | UUID PK | Primary key |
| aggregate_id | UUID NOT NULL | ID of the aggregate (incident_id) |
| event_type | VARCHAR(100) NOT NULL | 'triage.IncidentClassified' or 'triage.IncidentFlaggedForReview' |
| payload | JSONB NOT NULL | Full event payload |
| published | BOOLEAN NOT NULL DEFAULT false | Whether the event has been published |
| published_at | TIMESTAMPTZ | When it was published |
| created_at | TIMESTAMPTZ | Row creation timestamp |

**Indexes**: (published, created_at) WHERE published = false, (event_type)

## Custom Types

```sql
CREATE TYPE severity_level AS ENUM ('P0', 'P1', 'P2', 'P3', 'P4');
CREATE TYPE incident_status AS ENUM ('new', 'classified', 'flagged', 'resolved');
CREATE TYPE review_status AS ENUM ('pending', 'in_review', 'approved', 'overridden');
```

## Redis Caching Strategy

See `redis/TRIAGE-01_triage_cache.conf` for the dedicated Redis configuration.

Cached items:
- **Service topology graph**: `triage:topology:services` (hash, TTL 5 min)
- **Service dependencies**: `triage:topology:deps:{service_id}` (set, TTL 5 min)
- **Recent classifications by service**: `triage:classifications:recent:{service_id}` (sorted set, TTL 1 hour)
- **Classification confidence stats**: `triage:confidence:stats:{severity}` (hash, TTL 30 min)
