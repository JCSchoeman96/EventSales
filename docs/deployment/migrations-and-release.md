# Migrations and release initialization

## Runtime contract

- `DATABASE_URL` serves application traffic through the approved runtime database path.
- The VPS migration lifecycle requires `DIRECT_DATABASE_URL` to connect directly to PostgreSQL as `eventsales_migrator`. The PgBouncer runtime URL is not migration authority.
- `EventSales.Release.migrate()` runs migrations only. `EventSales.Release.bootstrap()` runs admin and source-system bootstrap only. Normal application startup runs neither.
- Migration and bootstrap use the same separately approved immutable application image digest that later runs the app.
- Database URLs and startup failures are redacted before error messages are emitted.

## Historical Railway compatibility

The versioned Railway pre-deploy configuration retains its historical compatibility operation, `EventSales.Release.migrate_and_bootstrap()`. That Railway-specific operation composes migrations followed by admin and WooCommerce source-system bootstrap. It is retained for Railway compatibility and does not define or authorize the VPS lifecycle.

## Separate VPS transitions

The VPS runbook separates migration, temporary bootstrap-app start, bootstrap invocation, and final runtime recreation. Each transition needs a new explicit authorization. A completed migration does not authorize bootstrap, and bootstrap does not authorize final app start.

The one-shot migration transition uses the approved image digest and direct `DIRECT_DATABASE_URL` path as `eventsales_migrator`. It invokes only `EventSales.Release.migrate()`. It requires accepted data-plane proof, reviewed backup/restore evidence, a destructive-risk review, no running app, and no host port.

The bootstrap transition runs later in a temporary private app using the same digest. After readiness, it invokes only `EventSales.Release.bootstrap()`. Bootstrap does not migrate. It is not the final runtime. The final runtime is recreated from the same digest after bootstrap succeeds, with all bootstrap-only and migration-only credentials removed.

## Failure and rollback handling

Each one-shot transition consumes its own authorization. A failure preserves output, container identity, and resulting database state for review. Inspect `schema_migrations` after a migration failure under separate read-only authority. Do not blindly rerun a migration or bootstrap, even where bootstrap operations are idempotent. Idempotency does not grant a new authorization.

Database rollback is never automatic. It requires a current backup, data and schema compatibility review, and separate explicit destructive authority. Preserve migration evidence until the review accepts the next action.

See the [VPS production runbook](vps-production.md) for the complete transition gates and the [database backup and restore guidance](../runbooks/database-backup-restore.md) for the repository's current recovery reference.

## Release operations

The release entrypoints remain separate:

```elixir
EventSales.Release.migrate()
EventSales.Release.bootstrap()
```

Use the migration entrypoint only for the separately authorized migration transition. Use the bootstrap entrypoint only for the separately authorized temporary bootstrap runtime after migration acceptance. Do not combine them for VPS production.

## Bootstrap behavior

`mix eventsales.admin.bootstrap` and `mix eventsales.source_system.bootstrap` remain available in a Mix environment. Railway retains `migrate_and_bootstrap/0` for compatibility. The VPS release lifecycle uses the release operations `migrate/0` and `bootstrap/0`; they are available in an OTP runtime release and do not depend on Mix tasks.

The source bootstrap matches `kind=:woocommerce` plus normalized base URL, creates only when missing, reactivates inactive records, and updates changed names. It does not call WooCommerce or alter webhook destinations. This implementation detail does not authorize a blind retry after a failed bootstrap transition.
