package internal

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/sync/errgroup"

	"github.com/cto-ai/entity-management/internal/adapters/eventbus"
	"github.com/cto-ai/entity-management/internal/adapters/handlers"
	"github.com/cto-ai/entity-management/internal/adapters/postgres"
	"github.com/cto-ai/entity-management/internal/domain"
)

// Run is the composition root. It wires everything and blocks until shutdown.
func Run(ctx context.Context, logger *slog.Logger) error {
	ctx, cancel := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// --- Configuration from environment ---
	dbURL := envOrDefault("DATABASE_URL", "postgres://localhost:5432/entitymanagement?sslmode=disable")
	natsURL := envOrDefault("NATS_URL", "nats://localhost:4222")
	httpAddr := envOrDefault("HTTP_ADDR", ":8080")

	// --- Database ---
	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	// --- Repositories ---
	entityRepo := postgres.NewEntityRepository(pool)
	outboxRepo := postgres.NewOutboxRepository(pool)

	// --- Domain Service ---
	entitySvc := domain.NewEntityService(entityRepo, outboxRepo)

	// --- Event Bus ---
	natsBus, err := eventbus.NewNATSEventBus(natsURL)
	if err != nil {
		return err
	}
	defer natsBus.Close(ctx)

	// --- Outbox Publisher ---
	publisher := eventbus.NewOutboxPublisher(outboxRepo, natsBus, logger)

	// --- HTTP Handlers ---
	httpHandler := handlers.NewHTTPHandler(entitySvc, logger)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		// Ping DB to assert readiness.
		if err := pool.Ping(ctx); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"status":"not ready"}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ready"}`))
	})
	httpHandler.RegisterRoutes(mux)

	httpServer := &http.Server{
		Addr:    httpAddr,
		Handler: mux,
	}

	// --- Goroutine orchestration ---
	g, gctx := errgroup.WithContext(ctx)

	g.Go(func() error {
		logger.InfoContext(gctx, "starting HTTP server", "addr", httpAddr)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			return err
		}
		return nil
	})

	g.Go(func() error {
		<-gctx.Done()
		logger.InfoContext(gctx, "shutting down HTTP server")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return httpServer.Shutdown(shutdownCtx)
	})

	g.Go(func() error {
		logger.InfoContext(gctx, "starting outbox publisher")
		return publisher.Run(gctx)
	})

	return g.Wait()
}

func envOrDefault(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}
