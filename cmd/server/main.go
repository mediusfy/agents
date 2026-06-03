package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"entity-management/internal/adapters/eventbus"
	"entity-management/internal/adapters/handlers"
	"entity-management/internal/adapters/repository"
	"entity-management/internal/domain"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/stdout/stdoutmetric"
	"go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
	"golang.org/x/sync/errgroup"
)

const (
	serviceName    = "entity-management"
	defaultPort    = "8080"
	shutdownTimout = 10 * time.Second
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	// --- OpenTelemetry setup ---
	res := resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceNameKey.String(serviceName),
		semconv.ServiceVersionKey.String("1.0.0"),
	}

	traceExporter, err := stdouttrace.New(stdouttrace.WithPrettyPrint())
	if err != nil {
		logger.Error("failed to create trace exporter", "error", err)
		os.Exit(1)
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	metricExporter, err := stdoutmetric.New()
	if err != nil {
		logger.Error("failed to create metric exporter", "error", err)
		os.Exit(1)
	}
	mp := metric.NewMeterProvider(metric.WithReader(metric.NewPeriodicReader(metricExporter)))
	otel.SetMeterProvider(mp)
	otel.SetTextMapPropagator(propagation.TraceContext{})

	// --- Lifecycle context ---
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	g, ctx := errgroup.WithContext(ctx)

	// --- Ports: Postgres pool ---
	dbURL := envOrDefault("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/entitymgmt?sslmode=disable")
	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		logger.Error("failed to create pgx pool", "error", err)
		os.Exit(1)
	}
	g.Go(func() error {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimout)
		defer cancel()
		pool.Close()
		<-shutdownCtx.Done()
		return nil
	})

	// --- Ports: NATS event bus ---
	natsURL := envOrDefault("NATS_URL", "nats://localhost:4222")
	bus, err := eventbus.NewNATSEventBus(natsURL, logger)
	if err != nil {
		logger.Error("failed to connect to NATS", "error", err)
		os.Exit(1)
	}
	g.Go(func() error {
		<-ctx.Done()
		return bus.Close()
	})

	// --- Adapter wiring ---
	repo := repository.NewPostgresRepo(pool)
	svc := domain.NewService(repo, bus)
	entityHandler := handlers.NewEntityHandler(svc, logger)

	// --- HTTP server ---
	mux := http.NewServeMux()
	handlers.RegisterRoutes(mux, entityHandler)

	httpPort := envOrDefault("HTTP_PORT", defaultPort)
	httpSrv := &http.Server{
		Addr:         ":" + httpPort,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	g.Go(func() error {
		logger.Info("http server starting", "port", httpPort)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	})

	g.Go(func() error {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimout)
		defer cancel()
		logger.Info("shutting down http server")
		return httpSrv.Shutdown(shutdownCtx)
	})

	if err := g.Wait(); err != nil {
		logger.Error("server terminated with error", "error", err)
		os.Exit(1)
	}
	logger.Info("server stopped gracefully")
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
