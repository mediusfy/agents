// Package pkg is the composition root for dependency injection.
// All wiring happens here; no init()-based registration.
package pkg

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/prodanlabs/region-resolver/internal/adapters/handlers"
	natsbus "github.com/prodanlabs/region-resolver/internal/adapters/natsbus"
	"github.com/prodanlabs/region-resolver/internal/adapters/postgres"
	"github.com/prodanlabs/region-resolver/internal/domain"
	"github.com/prodanlabs/region-resolver/internal/ports"
)

// App holds all initialized dependencies for the region-resolver service.
type App struct {
	DB          *pgxpool.Pool
	Bus         ports.EventBus
	Service     *domain.Service
	HTTPHandler *handlers.HTTPHandler
	GRPCHandler *handlers.GRPCHandler
	Logger      *slog.Logger
}

// AppConfig holds optional configuration for the App.
type AppConfig struct {
	DatabaseURL string
	NATSURL     string
	Logger      *slog.Logger
}

// AppOption is a functional option for App construction.
type AppOption func(*AppConfig)

// NewApp initializes all dependencies. It connects to the database and
// message bus, runs migrations, and wires up the domain service and handlers.
func NewApp(ctx context.Context, opts ...AppOption) (*App, error) {
	cfg := &AppConfig{
		DatabaseURL: envOrDefault("DATABASE_URL", "postgres://localhost:5432/region_resolver?sslmode=disable"),
		NATSURL:     envOrDefault("NATS_URL", "nats://localhost:4222"),
		Logger: slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
			Level: slog.LevelInfo,
		})),
	}
	for _, opt := range opts {
		opt(cfg)
	}

	logger := cfg.Logger.With("service", "region-resolver")

	// --- Database ---
	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("connect to database: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		return nil, fmt.Errorf("ping database: %w", err)
	}
	logger.InfoContext(ctx, "database connected")

	// --- Repositories ---
	entityRepo := postgres.NewEntityRepository(pool, logger)
	if err := postgres.RunMigrations(ctx, pool); err != nil {
		pool.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	logger.InfoContext(ctx, "database migrations complete")

	// --- NATS event bus ---
	var bus ports.EventBus
	natsBus, err := natsbus.NewNATSEventBus(cfg.NATSURL, logger)
	if err != nil {
		logger.WarnContext(ctx, "nats unavailable, using no-op event bus", "error", err)
		bus = natsbus.NewNoopBus(logger)
	} else {
		bus = natsBus
		logger.InfoContext(ctx, "connected to NATS")
	}

	// --- Event Publisher ---
	eventPublisher := ports.NewEventPublisherAdapter(bus, "region-resolver")

	// --- Domain Service ---
	domainSvc := domain.NewService(entityRepo, eventPublisher)

	// --- Handlers ---
	httpHandler := handlers.NewHTTPHandler(domainSvc, logger)
	grpcHandler := handlers.NewGRPCHandler(domainSvc)

	return &App{
		DB:          pool,
		Bus:         bus,
		Service:     domainSvc,
		HTTPHandler: httpHandler,
		GRPCHandler: grpcHandler,
		Logger:      logger,
	}, nil
}

// Close gracefully shuts down all connections.
func (a *App) Close() {
	if a.Bus != nil {
		if err := a.Bus.Close(); err != nil {
			a.Logger.Error("closing event bus", "error", err)
		}
	}
	if a.DB != nil {
		a.DB.Close()
	}
}

func envOrDefault(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}
