# Migrations And Release

## Runtime Contract

- `DATABASE_URL` is the normal runtime path for app traffic.
- `DIRECT_DATABASE_URL` is the preferred path for release migrations.
- `EventSales.Release.migration_database_url/1` prefers `DIRECT_DATABASE_URL` and only falls back to `DATABASE_URL` when the direct path is unavailable.
- Do not log full database URLs with credentials while diagnosing release problems.

## Release Commands

Run release migrations with the bundled release helper:

```bash
bin/event_sales eval "EventSales.Release.migrate()"
```

Rollback a repo to a specific migration version:

```bash
bin/event_sales eval "EventSales.Release.rollback(EventSales.Repo, 20260513122000)"
```

## Railway Guidance

- Railway is the primary deployment target.
- Prefer setting both `DATABASE_URL` and `DIRECT_DATABASE_URL` in Railway so release tasks do not depend on the pooled runtime path.
- If only `DATABASE_URL` is available, treat it as a documented fallback rather than the preferred migration path.
