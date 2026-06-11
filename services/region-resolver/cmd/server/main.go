package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"golang.org/x/sync/errgroup"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"

	"github.com/prodanlabs/region-resolver/internal/adapters/gencode"
	"github.com/prodanlabs/region-resolver/internal/adapters/handlers"
	natsbus "github.com/prodanlabs/region-resolver/internal/adapters/natsbus"
	"github.com/prodanlabs/region-resolver/internal/adapters/postgres"
	"github.com/prodanlabs/region-resolver/internal/domain"
	"github.com/prodanlabs/region-resolver/internal/ports"
)

const serviceName = "region-resolver"

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

	// --- OpenTelemetry Tracing ---
	shutdownTracer, err := initTracer(cfg)
	if err != nil {
		return fmt.Errorf("init tracer: %w", err)
	}
	defer shutdownTracer()

	// --- Root context with signal handling for graceful shutdown ---
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// --- Database ---
	dbCtx, dbCancel := context.WithTimeout(ctx, 10*time.Second)
	defer dbCancel()

	pool, err := pgxpool.New(dbCtx, cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("pgxpool new: %w", err)
	}
	defer pool.Close()

	if err := pool.Ping(dbCtx); err != nil {
		return fmt.Errorf("pgxpool ping: %w", err)
	}
	logger.InfoContext(ctx, "connected to postgres")

	// --- Entity Repository ---
	entityRepo := postgres.NewEntityRepository(pool, logger)
	if err := entityRepo.MigrateEntities(ctx); err != nil {
		return fmt.Errorf("migrate entities: %w", err)
	}
	logger.InfoContext(ctx, "database migrations applied")

	// --- Event Bus (NATS or degraded noop fallback) ---
	var bus ports.EventBus
	natsBus, err := natsbus.NewNATSEventBus(cfg.NATSURL, logger)
	if err != nil {
		logger.WarnContext(ctx, "nats unavailable, using no-op event bus (degraded mode)",
			"error", err)
		bus = natsbus.NewNoopBus(logger)
	} else {
		bus = natsBus
	}

	eventPublisher := ports.NewEventPublisherAdapter(bus, serviceName)

	// --- Domain Service ---
	domainSvc := domain.NewService(entityRepo, eventPublisher)

	// --- Handlers ---
	httpHandler := handlers.NewHTTPHandler(domainSvc, logger)
	grpcHandler := handlers.NewGRPCHandler(domainSvc)

	// --- HTTP Mux ---
	mux := http.NewServeMux()
	httpHandler.RegisterRoutes(mux, func(_ context.Context) bool {
		return pool.Ping(ctx) == nil
	})

	httpSrv := &http.Server{
		Addr:         fmt.Sprintf(":%s", cfg.HTTPPort),
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// --- gRPC Server ---
	grpcSrv := grpc.NewServer()
	gencode.RegisterEntityServiceServer(grpcSrv, grpcHandler)
	reflection.Register(grpcSrv)

	grpcLis, err := net.Listen("tcp", fmt.Sprintf(":%s", cfg.GRPCPort))
	if err != nil {
		return fmt.Errorf("grpc listen: %w", err)
	}

	// --- errgroup orchestration for graceful shutdown ---
	g, egCtx := errgroup.WithContext(ctx)

	// Start HTTP server.
	g.Go(func() error {
		logger.InfoContext(egCtx, "http server starting", "addr", httpSrv.Addr)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("http serve: %w", err)
		}
		return nil
	})

	// Start gRPC server.
	g.Go(func() error {
		logger.InfoContext(egCtx, "grpc server starting", "addr", grpcLis.Addr().String())
		if err := grpcSrv.Serve(grpcLis); err != nil && !errors.Is(err, grpc.ErrServerStopped) {
			return fmt.Errorf("grpc serve: %w", err)
		}
		return nil
	})

	// Signal handler goroutine: when SIGTERM received, gracefully shut down.
	g.Go(func() error {
		<-egCtx.Done()
		logger.InfoContext(context.Background(), "shutting down gracefully...")

		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer shutdownCancel()

		// Shutdown gRPC server first (stop accepting new requests).
		grpcSrv.GracefulStop()

		// Shutdown HTTP server.
		if err := httpSrv.Shutdown(shutdownCtx); err != nil {
			logger.ErrorContext(context.Background(), "http server shutdown error", "error", err)
		}

		// Close event bus connection.
		if err := bus.Close(); err != nil {
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
	GRPCPort     string
	DatabaseURL  string
	NATSURL      string
	OTLPEndpoint string
}

func loadConfig() config {
	return config{
		HTTPPort:     getEnvOrDefault("HTTP_PORT", "8080"),
		GRPCPort:     getEnvOrDefault("GRPC_PORT", "9090"),
		DatabaseURL:  getEnvOrDefault("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/region_resolver?sslmode=disable"),
		NATSURL:      getEnvOrDefault("NATS_URL", "nats://localhost:4222"),
		OTLPEndpoint: getEnvOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT", ""),
	}
}

func getEnvOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func initTracer(cfg config) (func(), error) {
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
			attribute.String("deployment.environment", getEnvOrDefault("ENV", "development")),
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
		_ = tp.Shutdown(ctx)
	}, nil
}

// Silence unused import warning.
var _ = json.Marshal
