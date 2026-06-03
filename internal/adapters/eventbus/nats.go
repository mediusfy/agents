package eventbus

import (
	"context"
	"fmt"
	"log/slog"

	cloudevents "github.com/cloudevents/sdk-go/v2/event"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("adapters.eventbus.NATSEventBus")

// NATSEventBus publishes CloudEvents to NATS JetStream.
type NATSEventBus struct {
	conn   *nats.Conn
	js     jetstream.JetStream
	logger *slog.Logger
}

// NewNATSEventBus connects to NATS and creates a JetStream context.
func NewNATSEventBus(url string, logger *slog.Logger) (*NATSEventBus, error) {
	conn, err := nats.Connect(url)
	if err != nil {
		return nil, fmt.Errorf("nats connect: %w", err)
	}
	js, err := jetstream.New(conn)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("jetstream new: %w", err)
	}
	return &NATSEventBus{conn: conn, js: js, logger: logger}, nil
}

// Publish sends a CloudEvent as a JetStream message on a subject derived
// from the event Subject field.
func (b *NATSEventBus) Publish(ctx context.Context, event cloudevents.Event) error {
	ctx, span := tracer.Start(ctx, "adapters.eventbus.NATSEventBus.Publish",
		trace.WithAttributes(
			attribute.String("event.id", event.ID()),
			attribute.String("event.subject", event.Subject()),
		))
	defer span.End()

	data, err := event.MarshalJSON()
	if err != nil {
		return fmt.Errorf("marshal event: %w", err)
	}

	// Use event.Subject as the NATS subject, e.g. "entitymanagement.entity.hard_deleted".
	subject := event.Subject()
	if subject == "" {
		subject = event.Type()
	}

	_, err = b.js.Publish(ctx, subject, data)
	if err != nil {
		return fmt.Errorf("jetstream publish: %w", err)
	}

	b.logger.DebugContext(ctx, "event published",
		"subject", subject,
		"event_id", event.ID(),
	)
	return nil
}

// Close shuts down the NATS connection.
func (b *NATSEventBus) Close() error {
	b.conn.Close()
	return nil
}

// OutboxPoller reads pending outbox rows and publishes them via JetStream.
type OutboxPoller struct {
	pool   queryer
	bus    *NATSEventBus
	logger *slog.Logger
}

type queryer interface {
	Query(ctx context.Context, sql string, args ...any) (interface {
		Next() bool
		Scan(dest ...any) error
		Close()
	}, error)
	Exec(ctx context.Context, sql string, args ...any) (interface{ RowsAffected() int64 }, error)
}

// OutboxRow represents a pending outbox entry.
type OutboxRow struct {
	ID        string
	EventType string
	Subject   string
	Source    string
	Payload   []byte
}

// PollAndPublish reads up to 100 unprocessed outbox entries, publishes them,
// and marks them as processed.
func (p *OutboxPoller) PollAndPublish(ctx context.Context) (int, error) {
	const selectQ = `
		SELECT id, event_type, subject, source, payload
		FROM outbox
		WHERE processed_at IS NULL
		ORDER BY created_at ASC
		LIMIT 100
		FOR UPDATE SKIP LOCKED
	`

	rows, err := p.pool.Query(ctx, selectQ)
	if err != nil {
		return 0, fmt.Errorf("select outbox: %w", err)
	}
	defer rows.Close()

	var published int
	for rows.Next() {
		var row OutboxRow
		if err := rows.Scan(&row.ID, &row.EventType, &row.Subject, &row.Source, &row.Payload); err != nil {
			return published, fmt.Errorf("scan outbox row: %w", err)
		}

		ce := cloudevents.New()
		ce.SetID(row.ID)
		ce.SetType(row.EventType)
		ce.SetSubject(row.Subject)
		ce.SetSource(row.Source)
		ce.SetDataContentType("application/json")
		if err := ce.SetData("application/json", row.Payload); err != nil {
			return published, fmt.Errorf("set event data: %w", err)
		}

		if err := p.bus.Publish(ctx, ce); err != nil {
			return published, fmt.Errorf("publish outbox row %s: %w", row.ID, err)
		}

		if _, err := p.pool.Exec(ctx,
			`UPDATE outbox SET processed_at = NOW() WHERE id = $1`, row.ID); err != nil {
			return published, fmt.Errorf("mark processed %s: %w", row.ID, err)
		}
		published++
	}
	return published, nil
}
