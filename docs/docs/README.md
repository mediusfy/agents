# Entity Management Service — Database & Architecture Docs

## Stories

| Story | Description | Status |
|-------|-------------|--------|
| [ENTITY-01](ENTITY-01_000_create_entity.md) | Create Entity | ✅ Done |
| [ENTITY-02](ENTITY-02_001_retrieve_entity_by_id.md) | Retrieve Entity by ID | ✅ Done |
| **ENTITY-03** | **List Entities with Pagination** | **✅ Done** |
| [ENTITY-04](ENTITY-04_000_optimistic_concurrency.md) | Optimistic Concurrency (Update Entity) | ✅ Done |
| [ENTITY-05](ENTITY-05_000_soft_delete_restore.md) | Soft Delete & Restore | ✅ Done |

## ENTITY-03: List Entities with Pagination

See [ENTITY-03_list_entities_pagination.md](ENTITY-03_list_entities_pagination.md) for full details.

### Key Files

| File | Description |
|------|-------------|
| `database/migrations/ENTITY-03_000_list_entities_pagination.up.sql` | UP migration: pagination indexes, stored procedures, diagnostic |
| `database/migrations/ENTITY-03_000_list_entities_pagination.down.sql` | DOWN migration: rollback |
| `database/seeds/ENTITY-03_000_list_entities_pagination_seed.sql` | Seed 50 entities for pagination testing |
| `internal/adapters/postgres/repo.go` | `List()` method implementation using OFFSET/LIMIT |
| `config/redis/entity_list_cache.conf` | Redis caching config for entity list endpoint |
