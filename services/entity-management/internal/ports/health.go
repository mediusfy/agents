package ports

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// HealthChecker defines the interface for dependency health checks.
type HealthChecker interface {
	Name() string
	Check(ctx context.Context) error
}

// HealthHandler manages and serves liveness and readiness probes.
type HealthHandler struct {
	mu       sync.RWMutex
	checkers []HealthChecker
	logger   *slog.Logger
}

func NewHealthHandler(logger *slog.Logger) *HealthHandler {
	return &HealthHandler{
		checkers: make([]HealthChecker, 0),
		logger:   logger.With("component", "HealthHandler"),
	}
}

func (h *HealthHandler) RegisterChecker(checker HealthChecker) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.checkers = append(h.checkers, checker)
}

func (h *HealthHandler) RegisterRoutes(r chi.Router) {
	r.Get("/healthz", h.handleLiveness)
	r.Get("/health/ready", h.handleReadiness)
	r.Get("/health/live", h.handleLiveness)
}

func (h *HealthHandler) handleLiveness(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"status":"UP"}`))
}

func (h *HealthHandler) handleReadiness(w http.ResponseWriter, r *http.Request) {
	h.mu.RLock()
	checkers := make([]HealthChecker, len(h.checkers))
	copy(checkers, h.checkers)
	h.mu.RUnlock()

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	status := "UP"
	details := make(map[string]string)
	hasError := false

	var wg sync.WaitGroup
	var mu sync.Mutex

	for _, c := range checkers {
		wg.Add(1)
		go func(checker HealthChecker) {
			defer wg.Done()
			err := checker.Check(ctx)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				details[checker.Name()] = "DOWN: " + err.Error()
				hasError = true
			} else {
				details[checker.Name()] = "UP"
			}
		}(c)
	}

	wg.Wait()

	if hasError {
		status = "DOWN"
	}

	resp := map[string]any{
		"status": status,
		"checks": details,
	}

	w.Header().Set("Content-Type", "application/json")
	if hasError {
		w.WriteHeader(http.StatusServiceUnavailable)
	} else {
		w.WriteHeader(http.StatusOK)
	}

	_ = json.NewEncoder(w).Encode(resp)
}

// DatabaseHealthChecker checks the pgx database pool.
type DatabaseHealthChecker struct {
	pool   *pgxpool.Pool
	logger *slog.Logger
}

func NewDatabaseHealthChecker(pool *pgxpool.Pool, logger *slog.Logger) *DatabaseHealthChecker {
	return &DatabaseHealthChecker{
		pool:   pool,
		logger: logger,
	}
}

func (c *DatabaseHealthChecker) Name() string { return "database" }

func (c *DatabaseHealthChecker) Check(ctx context.Context) error {
	if c.pool == nil {
		return context.DeadlineExceeded
	}
	return c.pool.Ping(ctx)
}

// EventBusHealthChecker checks the EventBus adapter.
type EventBusHealthChecker struct {
	bus    EventBus
	logger *slog.Logger
}

func NewEventBusHealthChecker(bus EventBus, logger *slog.Logger) *EventBusHealthChecker {
	return &EventBusHealthChecker{
		bus:    bus,
		logger: logger,
	}
}

func (c *EventBusHealthChecker) Name() string { return "eventbus" }

func (c *EventBusHealthChecker) Check(ctx context.Context) error {
	if c.bus == nil {
		return context.DeadlineExceeded
	}
	return c.bus.Ping(ctx)
}
