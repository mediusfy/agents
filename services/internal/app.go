package internal

import (
	"context"
	"database/sql"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"golang.org/x/sync/errgroup"

	"github.com/drewjocham/agents/internal/adapters"
	"github.com/drewjocham/agents/internal/domain"
)

// Run is the composition root. It wires everything and blocks until shutdown.
func Run(ctx context.Context, logger *slog.Logger) error {
	ctx, cancel := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// --- Configuration from environment ---
	dbURL := envOrDefault("DATABASE_URL", "postgres://localhost:5432/entitysvc?sslmode=disable")
	natsURL := envOrDefault("NATS_URL", "nats://localhost:4222")
	httpAddr := envOrDefault("HTTP_ADDR", ":8080")

	// --- Database (pgx via stdlib bridge) ---
	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		return err
	}
	defer db.Close()

	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	if err := db.PingContext(ctx); err != nil {
		return err
	}

	// --- Repositories ---
	entityRepo := adapters.NewPostgresEntityRepository(db)

	// Run migrations.
	if err := entityRepo.Migrate(ctx); err != nil {
		return err
	}

	// --- Event Bus ---
	natsBus, err := adapters.NewNATSEventBus(natsURL, nil)
	if err != nil {
		return err
	}
	defer natsBus.Close() //nolint: errcheck

	// --- Domain Service ---
	entitySvc := domain.NewEntityService(entityRepo, natsBus)

	// --- HTTP Handlers ---
	httpHandler := adapters.NewHTTPService(entitySvc)
	mux := http.NewServeMux()

	// Health check endpoints (direct, no domain logic).
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		if err := db.PingContext(ctx); err != nil {
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

	return g.Wait()
}

func envOrDefault(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}
