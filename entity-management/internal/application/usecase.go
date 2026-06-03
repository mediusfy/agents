package application

import (
	"context"
	"fmt"
	"time"

	"entity-management/internal/domain"
)

type CreateEntityRequest struct {
	SchemaID       string         `json:"schema_id"`
	Name           string         `json:"name"`
	Type           string         `json:"type"`
	Region         string         `json:"region"`
	Attributes     map[string]any `json:"attributes"`
	Metadata       map[string]any `json:"metadata"`
	IdempotencyKey string         `json:"idempotency_key,omitempty"`
}

type CreateEntityResponse struct {
	EntityID  string     `json:"entity_id"`
	SchemaID  string     `json:"schema_id"`
	Name      string     `json:"name"`
	Type      string     `json:"type"`
	Region    string     `json:"region"`
	Status    string     `json:"status"`
	CreatedAt time.Time  `json:"created_at"`
	UpdatedAt time.Time  `json:"updated_at"`
	Created   bool       `json:"created"`
}

type CreateEntityUseCase struct {
	svc *domain.Service
}

func NewCreateEntityUseCase(svc *domain.Service) *CreateEntityUseCase {
	return &CreateEntityUseCase{svc: svc}
}

func (uc *CreateEntityUseCase) Execute(ctx context.Context, req CreateEntityRequest) (*CreateEntityResponse, error) {
	input := domain.CreateEntityInput{
		SchemaID:       req.SchemaID,
		Name:           req.Name,
		Type:           req.Type,
		Region:         req.Region,
		Attributes:     req.Attributes,
		Metadata:       req.Metadata,
		IdempotencyKey: req.IdempotencyKey,
	}

	result, err := uc.svc.CreateEntity(ctx, input)
	if err != nil {
		return nil, fmt.Errorf("create entity: %w", err)
	}

	return &CreateEntityResponse{
		EntityID:  result.Entity.ID,
		SchemaID:  result.Entity.SchemaID,
		Name:      result.Entity.Name,
		Type:      result.Entity.Type,
		Region:    result.Entity.Region,
		Status:    string(result.Entity.Status),
		CreatedAt: result.Entity.CreatedAt,
		UpdatedAt: result.Entity.UpdatedAt,
		Created:   result.Created,
	}, nil
}
