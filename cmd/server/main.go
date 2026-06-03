package main

import (
	"context"
	"log/slog"
	"os"

	"github.com/drewjocham/agents/internal"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	slog.SetDefault(logger)

	ctx := context.Background()

	if err := internal.Run(ctx, logger); err != nil {
		logger.ErrorContext(ctx, "server exited with error", slog.Any("error", err))
		os.Exit(1)
	}
}
