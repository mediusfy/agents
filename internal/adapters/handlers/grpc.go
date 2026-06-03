package handlers

import (
	"context"
	"fmt"
	"log/slog"
	"net"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/drewjocham/agents/internal/domain"
)

// grpcServer is a manual gRPC service implementation for Entity operations.
// In production, code-generate from api/protobuf/entity/v1/entity.proto.
type grpcServer struct {
	svc *domain.EntityService
}

// NewGRPCServer creates the gRPC handler.
func NewGRPCServer(svc *domain.EntityService) *grpcServer {
	return &grpcServer{svc: svc}
}

// --- Request / Response types (mirror proto messages) ---

// EntityGetRequest mirrors the proto message.
type EntityGetRequest struct {
	Id string
}

// EntityGetResponse mirrors the proto message.
type EntityGetResponse struct {
	Id        string
	Name      string
	Type      string
	CreatedAt string
	UpdatedAt string
}

// EntityListRequest mirrors the proto message for listing entities.
type EntityListRequest struct {
	Page  int32
	Limit int32
}

// EntityListResponse mirrors the proto message for listing entities.
type EntityListResponse struct {
	Items []*EntityGetResponse
	Total int32
	Page  int32
	Limit int32
	Next  string
}

// --- RPC implementations ---

// GetEntity implements the GetEntity RPC.
func (s *grpcServer) GetEntity(ctx context.Context, req *EntityGetRequest) (*EntityGetResponse, error) {
	if req == nil || req.Id == "" {
		return nil, status.Error(codes.InvalidArgument, "id is required")
	}

	ent, err := s.svc.GetEntity(ctx, req.Id)
	if err != nil {
		return nil, mapDomainError(err)
	}

	return entityToGRPC(ent), nil
}

// ListEntities implements the ListEntities RPC.
func (s *grpcServer) ListEntities(ctx context.Context, req *EntityListRequest) (*EntityListResponse, error) {
	page := int(req.GetPage())
	if page < 1 {
		page = 1
	}
	limit := int(req.GetLimit())
	if limit < 1 || limit > 100 {
		limit = 20
	}

	input := domain.ListInput{Page: page, Limit: limit}

	result, err := s.svc.ListEntities(ctx, input)
	if err != nil {
		slog.ErrorContext(ctx, "grpc list entities failed", "error", err)
		return nil, status.Error(codes.Internal, "internal error")
	}

	items := make([]*EntityGetResponse, 0, len(result.Items))
	for _, e := range result.Items {
		items = append(items, entityToGRPC(&e))
	}

	return &EntityListResponse{
		Items: items,
		Total: int32(result.Total),
		Page:  int32(result.Page),
		Limit: int32(result.Limit),
		Next:  result.NextPage(),
	}, nil
}

// --- Registration ---

// RegisterWithServer registers the service on the given gRPC server.
func (s *grpcServer) RegisterWithServer(grpcSrv *grpc.Server) {
	grpcSrv.RegisterService(&entityServiceDesc, s)
}

// ServeGRPC starts a gRPC listener and serves until ctx is cancelled.
func ServeGRPC(ctx context.Context, addr string, svc *domain.EntityService) error {
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("grpc listen %s: %w", addr, err)
	}

	srv := grpc.NewServer()
	handler := NewGRPCServer(svc)
	handler.RegisterWithServer(srv)

	go func() {
		<-ctx.Done()
		slog.Info("grpc server shutting down")
		srv.GracefulStop()
	}()

	slog.Info("grpc server listening", "addr", addr)
	return srv.Serve(lis)
}

// --- Service descriptor ---

var entityServiceDesc = grpc.ServiceDesc{
	ServiceName: "entity.v1.EntityService",
	Methods: []grpc.MethodDesc{
		{
			MethodName: "GetEntity",
			Handler:    entityGetEntityHandler,
		},
		{
			MethodName: "ListEntities",
			Handler:    entityListEntitiesHandler,
		},
	},
	Streams:  []grpc.StreamDesc{},
	Metadata: "api/protobuf/entity/v1/entity.proto",
}

func entityGetEntityHandler(srv any, ctx context.Context, dec func(any) error, _ grpc.UnaryServerInterceptor) (any, error) {
	req := new(EntityGetRequest)
	if err := dec(req); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "decode: %v", err)
	}
	return srv.(*grpcServer).GetEntity(ctx, req)
}

func entityListEntitiesHandler(srv any, ctx context.Context, dec func(any) error, _ grpc.UnaryServerInterceptor) (any, error) {
	req := new(EntityListRequest)
	if err := dec(req); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "decode: %v", err)
	}
	return srv.(*grpcServer).ListEntities(ctx, req)
}

// --- Helpers ---

func entityToGRPC(e *domain.Entity) *EntityGetResponse {
	if e == nil {
		return nil
	}
	return &EntityGetResponse{
		Id:        e.ID,
		Name:      e.Name,
		Type:      e.Type,
		CreatedAt: e.CreatedAt.Format("2006-01-02T15:04:05Z07:00"),
		UpdatedAt: e.UpdatedAt.Format("2006-01-02T15:04:05Z07:00"),
	}
}

func mapDomainError(err error) error {
	switch {
	case isDomainErr(err, domain.ErrEntityNotFound):
		return status.Error(codes.NotFound, err.Error())
	case isDomainErr(err, domain.ErrInvalidEntityID):
		return status.Error(codes.InvalidArgument, err.Error())
	default:
		return status.Error(codes.Internal, "internal error")
	}
}

func isDomainErr(err, target error) bool {
	if err == nil {
		return false
	}
	for e := err; e != nil; e = unwrap(e) {
		if e == target {
			return true
		}
	}
	return false
}

func unwrap(e error) error {
	u, ok := e.(interface{ Unwrap() error })
	if !ok {
		return nil
	}
	return u.Unwrap()
}
