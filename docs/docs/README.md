



## 📋 Stories

| ID | Story | Theme | Priority | Status |
|----|-------|-------|----------|--------|
| ENT-01 | Define Entity Schema | Entity Management | P0 | ✅ Implemented |
| GITOPS-01 | Automated Incident Response via GitOps PRs | GitOps | P0 | Planned |
| ... | ... | ... | ... | ... |

### Recently Completed

| Story | Artifacts |
|-------|-----------|
| **ENT-01** Define Entity Schema | [Schema Definition Doc](docs/docs/ENT-01_schema_definition.md), [Migration](docs/migrations/002_create_entity_schemas.sql), [Seed Data](docs/seeds/002_entity_schema_data.sql), [Redis Config](docs/config/redis-entity-schema.conf) |


## ENTITY-05 — Soft-Delete, Hard-Delete, and Restore Entity Instances

**Migration files:**
- `docs/generated-app/default/database/migrations/ENTITY-05_000_soft_delete_restore.up.sql` — Up migration
- `docs/generated-app/default/database/migrations/ENTITY-05_000_soft_delete_restore.down.sql` — Down migration
- `docs/generated-app/default/database/seeds/ENTITY-05_000_soft_delete_restore_seed.sql` — Seed data
- `docs/generated-app/default/database/redis/ENTITY-05_soft_delete_cache.conf` — Redis config
- `docs/docs/ENTITY-05_SCHEMA_SUMMARY.md` — Full schema documentation

**Summary:** Introduces three atomic operations on entities:
1. **Soft-delete** (default `DELETE`): Sets `deleted_at = NOW()`, sets `status = 'deleted'`, emits `entitymanagement.EntitySoftDeleted`
2. **Hard-delete** (`DELETE ?permanent=true`): Permanently removes already-soft-deleted entities, emits `entitymanagement.EntityHardDeleted`
3. **Restore** (`POST /entities/{id}/restore`): Clears `deleted_at`, reverts status to `'active'`, emits `entitymanagement.EntityRestored`

All changes are additive (no new tables, no ALTER TABLE on existing columns).


## ENTITYMGMT-01: Schema Definition with Typed Attributes

**Status**: ✅ Complete  
**Story**: Admin defines entity schema with typed attributes  
**Event**: `entitymanagement.schema.defined` → written to transactional outbox  
**Files**:
- `entity-management/database/migrations/ENTITYMGMT-01_000_schema_definition.up.sql`
- `entity-management/database/migrations/ENTITYMGMT-01_000_schema_definition.down.sql`
- `entity-management/database/seeds/ENTITYMGMT-01_000_schema_definition_seed.sql`
- `entity-management/database/queries/ENTITYMGMT-01_define_schema.sql`
- `entity-management/config/redis/cache.conf`

See [Full Docs](database/migrations/ENTITYMGMT-01_000_schema_definition.md) for details.
