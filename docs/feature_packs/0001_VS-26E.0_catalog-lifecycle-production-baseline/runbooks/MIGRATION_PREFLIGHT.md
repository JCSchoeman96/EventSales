# VS-26E.0 Migration and Database Preflight

## Safety rules

- Run read-only checks first.
- Never paste database URLs or credentials into evidence.
- Prefer release migration path already defined by the repo.
- Do not run ad-hoc DDL.
- Do not drop/recreate the active-run index to bypass a conflict.
- Do not rewrite run statuses manually.

## Migrations to verify

- `20260714100000_add_catalog_sync_retry_metadata`
- `20260714100100_add_catalog_sync_active_run_index`

Also verify predecessor Catalog Sync and revocation migrations are present.

## Read-only migration status

Use an approved Railway shell/database session and a read-only query or release-supported status mechanism. Evidence should list migration versions and applied/not-applied only.

Example SQL shape; adapt to actual Ecto schema table name after read-only discovery:

```sql
SELECT version
FROM schema_migrations
WHERE version IN (20260714100000, 20260714100100)
ORDER BY version;
```

## Duplicate active-run preflight

```sql
SELECT source_system_id, count(*) AS active_count
FROM ingestion_tickera_catalog_sync_runs
WHERE status IN ('queued','discovering','retry_scheduled','dry_run_ready','applying')
GROUP BY source_system_id
HAVING count(*) > 1
ORDER BY source_system_id;
```

Expected: zero rows.

Any row is a stop. Do not update statuses to make the migration pass.

## Retry columns and constraints

Read-only metadata checks must prove:

- `retry_attempt` integer nullable;
- `retry_max_attempts` integer nullable;
- attempt bounds constraints exist;
- `last_error` length constraint exists.

## Active-run index metadata

Prove:

- name: `ingestion_tickera_catalog_sync_runs_one_active_per_source_idx`;
- unique: true;
- valid: true;
- ready: true where available;
- key column: `source_system_id`;
- exact active predicate includes only:
  `queued`, `discovering`, `retry_scheduled`, `dry_run_ready`, `applying`.

Example metadata query shape:

```sql
SELECT
  i.relname AS index_name,
  ix.indisunique,
  ix.indisvalid,
  ix.indisready,
  pg_get_indexdef(ix.indexrelid) AS definition,
  pg_get_expr(ix.indpred, ix.indrelid) AS predicate
FROM pg_index ix
JOIN pg_class i ON i.oid = ix.indexrelid
WHERE i.relname = 'ingestion_tickera_catalog_sync_runs_one_active_per_source_idx';
```

## Oban state

Read-only inspection should identify jobs for:

- `EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorker`
- `EventSales.Ingestion.Workers.ApplyTickeraCatalogWorker`

Record counts by safe state, not full args if they contain more than run ids/hashes. Unexpected `available`, `scheduled`, `executing`, or `retryable` work is a stop until understood.

## Migration execution

Only after approval:

- use `EventSales.Release.migrate_and_bootstrap/0` through Railway pre-deploy, or
- use `EventSales.Release.migrate/0` through the reviewed direct/session-capable URL when a separately approved manual migration is required.

Do not rely on `DATABASE_URL` fallback until the live topology is documented safe.

## Post-migration

Repeat migration, constraint, index, duplicate-run, and Oban checks. Capture redacted results.
