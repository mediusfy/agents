// Package pkg is the composition root for dependency injection.
package pkg

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/jackc/pgx/v5/pgxpool"

	"entity-management/internal/adapters/eventbus"
	"entity-management/internal/adapters/postgres"
	"entity-management/internal/adapters/validator"
	"entity-management/internal/application"
	"entity-management/internal/domain"
	"entity-management/internal/ports"
)

type App struct {
	Pool   *pgxpool.Pool
	Bus    ports.EventBus
	Router *chi.Mux
	Logger *slog.Logger
}

type Config struct {
	HTTPPort     string
	DatabaseURL  string
	NATSURL      string
	EventBusType string
	Logger       *slog.Logger
}

func NewApp(ctx context.Context, cfg Config) (*App, error) {
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}

	dbCtx, dbCancel := context.WithTimeout(ctx, 10*time.Second)
	defer dbCancel()

	pool, err := pgxpool.New(dbCtx, cfg.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("pgxpool new: %w", err)
	}

	if err := pool.Ping(dbCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("pgxpool ping: %w", err)
	}

	schemaRepo := postgres.NewSchemaRepository(pool, logger)
	entityRepo := postgres.NewEntityRepository(pool, logger)
	outboxRepo := postgres.NewOutboxRepository(pool, logger)
	requestIdempotencyStore := postgres.NewRequestIdempotencyStore(pool, logger)

	if err := postgres.RunMigrations(ctx, pool); err != nil {
		pool.Close()
		return nil, fmt.Errorf("db migrate: %w", err)
	}

	var bus ports.EventBus
	switch cfg.EventBusType {
	case "nats":
		var err error
		bus, err = eventbus.NewNATSEventBus(cfg.NATSURL, logger)
		if err != nil {
			bus = eventbus.NewNoopBus(logger)
		}
	default:
		bus = eventbus.NewNoopBus(logger)
	}

	eventPublisher := ports.NewEventPublisherAdapter(bus, "entity-management")
	validatorCache := validator.NewMemoryValidator(schemaRepo, logger)
	uow := postgres.NewUnitOfWork(pool, logger)

	schemaSvc := application.NewSchemaService(
		schemaRepo,
		outboxRepo,
		uow,
		eventPublisher,
		validatorCache,
		logger,
	)

	readEntityUC := application.NewReadEntityUseCase(
		entityRepo,
		eventPublisher,
		logger,
	)

	domainSvc := domain.NewService(
		schemaRepo,
		entityRepo,
		outboxRepo,
		requestIdempotencyStore,
		uow,
	)

	createEntityUC := application.NewCreateEntityUseCase(domainSvc)
	updateEntityUC := application.NewUpdateEntityUseCase(domainSvc, logger)
	deleteRestoreUC := application.NewDeleteRestoreUseCase(domainSvc, logger)
	listEntitiesUC := application.NewListEntitiesUseCase(entityRepo, eventPublisher, logger)

	appRouter := chi.NewRouter()
	appRouter.Use(chimw.RequestID)
	appRouter.Use(chimw.RealIP)
	appRouter.Use(chimw.Logger)

	healthHandler := ports.NewHealthHandler(logger)
	healthHandler.RegisterChecker(ports.NewDatabaseHealthChecker(pool, logger))
	healthHandler.RegisterChecker(ports.NewEventBusHealthChecker(bus, logger))
	healthHandler.RegisterRoutes(appRouter)

	appRouter.Route("/api/v1", func(r chi.Router) {
		schemaHandler := ports.NewSchemaHTTPHandler(schemaSvc, logger)
		entityHandler := ports.NewEntityHTTPHandler(
			createEntityUC, readEntityUC, updateEntityUC,
			deleteRestoreUC, listEntitiesUC, logger,
		)
		schemaHandler.RegisterRoutes(r)
		entityHandler.RegisterRoutes(r)
	})

	return &App{
		Pool:   pool,
		Bus:    bus,
		Router: appRouter,
		Logger: logger,
	}, nil
}
