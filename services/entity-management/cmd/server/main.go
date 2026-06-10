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

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"golang.org/x/sync/errgroup"

	"entity-management/internal/adapters/eventbus"
	"entity-management/internal/adapters/postgres"
	"entity-management/internal/adapters/validator"
	"entity-management/internal/application"
	"entity-management/internal/domain"
	"entity-management/internal/ports"
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

	// --- Database connection pool ---
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

	// --- Repositories ---
	schemaRepo := postgres.NewSchemaRepository(pool, logger)
	entityRepo := postgres.NewEntityRepository(pool, logger)
	outboxRepo := postgres.NewOutboxRepository(pool, logger)
	requestIdempotencyStore := postgres.NewRequestIdempotencyStore(pool, logger)

	// --- Migrations ---
	if err := schemaRepo.Migrate(ctx); err != nil {
		return fmt.Errorf("db migrate schemas: %w", err)
	}
	if err := entityRepo.MigrateEntities(ctx); err != nil {
		return fmt.Errorf("db migrate entities: %w", err)
	}
	if err := requestIdempotencyStore.MigrateRequestIdempotency(ctx); err != nil {
		return fmt.Errorf("db migrate request idempotency: %w", err)
	}
	logger.InfoContext(ctx, "database migrations applied")

	// --- Event Bus (Solace PubSub+ or NATS with degraded noop fallback) ---
	var bus ports.EventBus
	var topicResolver eventbus.TopicResolver

	switch cfg.EventBusType {
	case "solace":
		solaceCfg := eventbus.SolaceConfig{
			Host:     cfg.SolaceHost,
			VPNName:  cfg.SolaceVPN,
			UserName: cfg.SolaceUser,
			Password: cfg.SolacePassword,
		}
		sb, err := eventbus.NewSolaceBus(solaceCfg, logger)
		if err != nil {
			logger.WarnContext(ctx, "solace unavailable, using no-op event bus",
				"error", err)
			bus = eventbus.NewNoopBus(logger)
			topicResolver = eventbus.NATSTopicResolver()
		} else {
			bus = sb
			topicResolver = eventbus.SolaceTopicResolver()
			logger.InfoContext(ctx, "using Solace PubSub+ event bus")
		}
	case "nats":
		var err error
		bus, err = eventbus.NewNATSEventBus(cfg.NATSURL, logger)
		if err != nil {
			logger.WarnContext(ctx, "nats unavailable, using no-op event bus",
				"error", err)
			bus = eventbus.NewNoopBus(logger)
			topicResolver = eventbus.NATSTopicResolver()
		} else {
			topicResolver = eventbus.NATSTopicResolver()
			logger.InfoContext(ctx, "using NATS event bus")
		}
	default:
		logger.WarnContext(ctx, "no event bus configured, using no-op", "event_bus_type", cfg.EventBusType)
		bus = eventbus.NewNoopBus(logger)
		topicResolver = eventbus.NATSTopicResolver()
	}

	// --- Event Publisher (CloudEvents enveloping) ---
	eventPublisher := ports.NewEventPublisherAdapter(bus, serviceName)

	// --- Schema Validator (in-memory cache) ---
	validatorCache := validator.NewMemoryValidator(schemaRepo, logger)

	// --- Unit of Work ---
	uow := postgres.NewUnitOfWork(pool, logger)

	// --- Schema Service (use case) ---
	schemaSvc := application.NewSchemaService(
		schemaRepo,
		outboxRepo,
		uow,
		eventPublisher,
		validatorCache,
		logger,
	)

	// --- Read Entity Use Case ---
	readEntityUC := application.NewReadEntityUseCase(
		entityRepo,
		eventPublisher,
		logger,
	)

	// --- Domain Service (create, update, delete/restore) ---
	domainSvc := domain.NewService(
		schemaRepo,
		entityRepo,
		outboxRepo,
		requestIdempotencyStore,
		uow,
	)

	// --- Application Use Cases ---
	createEntityUC := application.NewCreateEntityUseCase(domainSvc)
	updateEntityUC := application.NewUpdateEntityUseCase(domainSvc, logger)
	deleteRestoreUC := application.NewDeleteRestoreUseCase(domainSvc, logger)
	listEntitiesUC := application.NewListEntitiesUseCase(entityRepo, logger)

	// --- Health Handler (HEALTH-01: Liveness + Readiness with structured checks) ---
	healthHandler := ports.NewHealthHandler(logger)

	// Register per-dependency health checkers for the /health/ready endpoint.
	healthHandler.RegisterChecker(ports.NewDatabaseHealthChecker(pool, logger))
	healthHandler.RegisterChecker(ports.NewEventBusHealthChecker(bus, logger))

	// --- Chi Router ---
	app := chi.NewRouter()

	// Register middleware
	app.Use(chimw.RequestID)
	app.Use(chimw.RealIP)
	app.Use(chimw.Logger)

	// Register health endpoints (HEALTH-01) at the root level for K8s probes.
	healthHandler.RegisterRoutes(app)

	// Register API routes under /api/v1.
	app.Route("/api/v1", func(r chi.Router) {
		schemaHandler := ports.NewSchemaHTTPHandler(schemaSvc, logger)
		entityHandler := ports.NewEntityHTTPHandler(
			createEntityUC, readEntityUC, updateEntityUC,
			deleteRestoreUC, listEntitiesUC, logger,
		)
		schemaHandler.RegisterRoutes(r)
		entityHandler.RegisterRoutes(r)
	})

	srv := &http.Server{
		Addr:         fmt.Sprintf(":%s", cfg.HTTPPort),
		Handler:      app,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// --- Outbox Relay ---
	relay := eventbus.NewOutboxRelay(outboxRepo, bus, logger,
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
	HTTPPort       string
	DatabaseURL    string
	NATSURL        string
	EventBusType   string
	SolaceHost     string
	SolaceVPN      string
	SolaceUser     string
	SolacePassword string
	OTLPEndpoint   string
}

func loadConfig() config {
	return config{
		HTTPPort:       getEnvOrDefault("HTTP_PORT", "8080"),
		DatabaseURL:    getEnvOrDefault("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/entity_management?sslmode=disable"),
		NATSURL:        getEnvOrDefault("NATS_URL", "nats://localhost:4222"),
		EventBusType:   getEnvOrDefault("EVENT_BUS_TYPE", "nats"),
		SolaceHost:     getEnvOrDefault("SOLACE_HOST", "tcp://localhost:55555"),
		SolaceVPN:      getEnvOrDefault("SOLACE_VPN", "default"),
		SolaceUser:     getEnvOrDefault("SOLACE_USERNAME", "default"),
		SolacePassword: getEnvOrDefault("SOLACE_PASSWORD", "default"),
		OTLPEndpoint:   getEnvOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT", ""),
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
