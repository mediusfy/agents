package handlers

import (
	"context"
	"errors"
	"fmt"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/prodanlabs/region-resolver/internal/adapters/gencode"
	"github.com/prodanlabs/region-resolver/internal/domain"
)

var grpcTracer = otel.Tracer("handlers.grpc")

// Compile-time interface check.
var _ gencode.EntityServiceServer = (*GRPCHandler)(nil)

// GRPCHandler implements the gencode.EntityServiceServer using the domain
// service. It translates between protobuf types and domain types.
type GRPCHandler struct {
	gencode.UnimplementedEntityServiceServer
	svc *domain.Service
}

// NewGRPCHandler creates a new gRPC handler.
func NewGRPCHandler(svc *domain.Service) *GRPCHandler {
	return &GRPCHandler{svc: svc}
}

// CreateEntity handles the gRPC CreateEntity RPC.
func (h *GRPCHandler) CreateEntity(ctx context.Context, req *gencode.CreateEntityRequest) (*gencode.CreateEntityResponse, error) {
	ctx, span := grpcTracer.Start(ctx, "handlers.GRPCHandler.CreateEntity",
		trace.WithAttributes(
			attribute.String("region", req.Region),
		),
	)
	defer span.End()

	result, err := h.svc.CreateEntity(ctx, domain.CreateEntityInput{
		Name:   req.Name,
		Region: req.Region,
	})
	if err != nil {
		span.RecordError(err)
		return nil, mapDomainError(err)
	}

	span.SetAttributes(
		attribute.String("entity_id", result.Entity.ID),
		attribute.String("data_residency_zone", string(result.Entity.DataResidencyZone)),
	)

	pbEntity := domainEntityToProto(result.Entity)
	return &gencode.CreateEntityResponse{Entity: pbEntity}, nil
}

// GetEntity handles the gRPC GetEntity RPC.
func (h *GRPCHandler) GetEntity(ctx context.Context, req *gencode.GetEntityRequest) (*gencode.GetEntityResponse, error) {
	ctx, span := grpcTracer.Start(ctx, "handlers.GRPCHandler.GetEntity",
		trace.WithAttributes(attribute.String("entity_id", req.Id)),
	)
	defer span.End()

	entity, err := h.svc.GetEntity(ctx, req.Id)
	if err != nil {
		span.RecordError(err)
		return nil, mapDomainError(err)
	}

	span.SetAttributes(
		attribute.String("region", entity.Region),
		attribute.String("data_residency_zone", string(entity.DataResidencyZone)),
	)

	pbEntity := domainEntityToProto(entity)
	return &gencode.GetEntityResponse{Entity: pbEntity}, nil
}

// UpdateEntity handles the gRPC UpdateEntity RPC.
func (h *GRPCHandler) UpdateEntity(ctx context.Context, req *gencode.UpdateEntityRequest) (*gencode.UpdateEntityResponse, error) {
	ctx, span := grpcTracer.Start(ctx, "handlers.GRPCHandler.UpdateEntity",
		trace.WithAttributes(
			attribute.String("entity_id", req.Id),
			attribute.Int("expected_version", int(req.ExpectedVersion)),
		),
	)
	defer span.End()

	op := domain.UpdateOperation{
		ExpectedVersion: int(req.ExpectedVersion),
	}
	if req.Name != nil {
		op.Name = req.Name
	}
	if req.Status != nil {
		s := domain.EntityStatus(*req.Status)
		op.Status = &s
	}

	entity, err := h.svc.UpdateEntity(ctx, req.Id, op)
	if err != nil {
		span.RecordError(err)
		return nil, mapDomainError(err)
	}

	pbEntity := domainEntityToProto(entity)
	return &gencode.UpdateEntityResponse{Entity: pbEntity}, nil
}

// DeleteEntity handles the gRPC DeleteEntity RPC.
func (h *GRPCHandler) DeleteEntity(ctx context.Context, req *gencode.DeleteEntityRequest) (*gencode.DeleteEntityResponse, error) {
	ctx, span := grpcTracer.Start(ctx, "handlers.GRPCHandler.DeleteEntity",
		trace.WithAttributes(attribute.String("entity_id", req.Id)),
	)
	defer span.End()

	if err := h.svc.DeleteEntity(ctx, req.Id); err != nil {
		span.RecordError(err)
		return nil, mapDomainError(err)
	}

	return &gencode.DeleteEntityResponse{Success: true}, nil
}

// ListEntities handles the gRPC ListEntities RPC.
func (h *GRPCHandler) ListEntities(ctx context.Context, _ *gencode.ListEntitiesRequest) (*gencode.ListEntitiesResponse, error) {
	ctx, span := grpcTracer.Start(ctx, "handlers.GRPCHandler.ListEntities")
	defer span.End()

	entities, err := h.svc.ListEntities(ctx)
	if err != nil {
		span.RecordError(err)
		return nil, mapDomainError(err)
	}

	pbEntities := make([]*gencode.Entity, 0, len(entities))
	for _, e := range entities {
		pbEntities = append(pbEntities, domainEntityToProto(e))
	}

	span.SetAttributes(attribute.Int("count", len(pbEntities)))
	return &gencode.ListEntitiesResponse{Entities: pbEntities}, nil
}

// domainEntityToProto converts a domain Entity to a protobuf Entity.
func domainEntityToProto(e *domain.Entity) *gencode.Entity {
	return &gencode.Entity{
		Id:                e.ID,
		Name:              e.Name,
		Region:            e.Region,
		DataResidencyZone: string(e.DataResidencyZone),
		Status:            string(e.Status),
		Version:           int32(e.Version),
		CreatedAt:         timestamppb.New(e.CreatedAt),
		UpdatedAt:         timestamppb.New(e.UpdatedAt),
	}
}

// mapDomainError converts domain errors to gRPC status errors.
func mapDomainError(err error) error {
	if err == nil {
		return nil
	}

	switch {
	case errors.Is(err, domain.ErrEntityNotFound):
		return status.Errorf(codes.NotFound, "%s", err.Error())
	case errors.Is(err, domain.ErrImmutableField):
		return status.Errorf(codes.InvalidArgument, "%s", err.Error())
	case errors.Is(err, domain.ErrStaleVersion):
		return status.Errorf(codes.FailedPrecondition, "%s", err.Error())
	case errors.Is(err, domain.ErrInvalidEntity):
		return status.Errorf(codes.InvalidArgument, "%s", err.Error())
	default:
		return status.Errorf(codes.Internal, "%s", err.Error())
	}
}

// Ensure fmt is used.
var _ = fmt.Sprintf
