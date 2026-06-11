package ports

import (
	"context"

	"entity-management/internal/application"
)

type handlerNoopCreateUC struct{}

func (n *handlerNoopCreateUC) Execute(_ context.Context, _ application.CreateEntityRequest) (*application.CreateEntityResponse, error) {
	return nil, nil
}

type handlerNoopReadUC struct{}

func (n *handlerNoopReadUC) Execute(_ context.Context, _ string) (*application.ReadEntityResponse, error) {
	return nil, nil
}

type handlerNoopUpdateUC struct{}

func (n *handlerNoopUpdateUC) Execute(_ context.Context, _ application.UpdateEntityRequest) (*application.UpdateEntityResponse, error) {
	return nil, nil
}

type handlerNoopDeleteRestoreUC struct{}

func (n *handlerNoopDeleteRestoreUC) SoftDelete(_ context.Context, _ string) error      { return nil }
func (n *handlerNoopDeleteRestoreUC) HardDelete(_ context.Context, _ string) error      { return nil }
func (n *handlerNoopDeleteRestoreUC) PermanentDelete(_ context.Context, _ string) error { return nil }
func (n *handlerNoopDeleteRestoreUC) Restore(_ context.Context, _ string) error         { return nil }

type handlerNoopListUC struct{}

func (n *handlerNoopListUC) Execute(_ context.Context, _ application.ListEntitiesRequest) (*application.ListEntitiesResponse, error) {
	return &application.ListEntitiesResponse{Entities: []*application.EntityListItem{}}, nil
}
