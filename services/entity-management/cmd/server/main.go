package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"golang.org/x/sync/errgroup"

	"entity-management/internal/adapters/eventbus"
	"entity-management/internal/adapters/postgres"
	"entity-management/pkg"
)

const serviceName = "entity-management"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})).With("service", serviceName)

	if err := run(logger); err != nil {
		logger.ErrorContext(context.Background(), "fatal startup error", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	cfg := loadConfig()

	shutdownTracer, err := initTracer(cfg)
	if err != nil {
		return fmt.Errorf("init tracer: %w", err)
	}
	defer shutdownTracer()

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// Initialize the application using the composition root
	app, err := pkg.NewApp(ctx, pkg.Config{
		HTTPPort:     cfg.HTTPPort,
		DatabaseURL:  cfg.DatabaseURL,
		NATSURL:      cfg.NATSURL,
		EventBusType: cfg.EventBusType,
		Logger:       logger,
	})
	if err != nil {
		return fmt.Errorf("initialize app: %w", err)
	}
	defer app.Pool.Close()

	srv := &http.Server{
		Addr:         fmt.Sprintf(":%s", cfg.HTTPPort),
		Handler:      app.Router,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Outbox Relay dependencies
	outboxRepo := postgres.NewOutboxRepository(app.Pool, logger)
	topicResolver := eventbus.NATSTopicResolver()

	// --- Outbox Relay ---
	relay := eventbus.NewOutboxRelay(outboxRepo, app.Bus, logger,
		eventbus.WithPollInterval(500*time.Millisecond),
		eventbus.WithMaxRetries(3),
		eventbus.WithBatchSize(50),
		eventbus.WithTopicResolver(topicResolver),
	)

	// --- errgroup graceful shutdown ---
	g, egCtx := errgroup.WithContext(ctx)

	g.Go(func() error {
		logger.InfoContext(egCtx, "http server starting", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("http serve: %w", err)
		}
		return nil
	})

	g.Go(func() error {
		logger.InfoContext(egCtx, "outbox relay starting",
			"event_bus_type", cfg.EventBusType)
		if err := relay.Run(egCtx); err != nil && !errors.Is(err, context.Canceled) {
			return fmt.Errorf("outbox relay: %w", err)
		}
		return nil
	})

	g.Go(func() error {
		<-egCtx.Done()
		logger.InfoContext(context.Background(), "shutting down...")

		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer shutdownCancel()

		if err := srv.Shutdown(shutdownCtx); err != nil {
			logger.ErrorContext(context.Background(), "http shutdown error", "error", err)
		}
		if err := app.Bus.Close(); err != nil {
			logger.ErrorContext(context.Background(), "event bus close error", "error", err)
		}
		return nil
	})

	if err := g.Wait(); err != nil {
		logger.ErrorContext(context.Background(), "service error", "error", err)
		return err
	}

	logger.InfoContext(context.Background(), "server stopped gracefully")
	return nil
}

type config struct {
	HTTPPort     string
	DatabaseURL  string
	NATSURL      string
	EventBusType string
	OTLPEndpoint string
}

func loadConfig() config {
	return config{
		HTTPPort:     getEnvOrDefault("HTTP_PORT", "8080"),
		DatabaseURL:  getEnvOrDefault("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/entity_management?sslmode=disable"),
		NATSURL:      getEnvOrDefault("NATS_URL", "nats://localhost:4222"),
		EventBusType: getEnvOrDefault("EVENT_BUS_TYPE", "nats"),
		OTLPEndpoint: getEnvOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT", ""),
	}
}

func getEnvOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func initTracer(_ config) (func(), error) {
	exp, err := stdouttrace.New(stdouttrace.WithPrettyPrint())
	if err != nil {
		return nil, fmt.Errorf("stdouttrace new: %w", err)
	}

	res, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(
			"https://opentelemetry.io/schemas/1.26.0",
			attribute.String("service.name", serviceName),
			attribute.String("service.version", "1.0.0"),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("resource new: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	return func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		tp.Shutdown(ctx)
	}, nil
}
