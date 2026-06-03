package main

import (
	"context"
	"log/slog"
	"os"

	"github.com/cto-ai/entity-management/internal"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	if err := internal.Run(context.Background(), logger); err != nil {
		logger.ErrorContext(context.Background(), "fatal error", "error", err)
		os.Exit(1)
	}
}
