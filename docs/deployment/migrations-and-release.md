# Migrations and Release Initialization

## Runtime contract

- `DATABASE_URL` serves application traffic.
- `DIRECT_DATABASE_URL` is preferred by `EventSales.Release.migrate/0` and falls back to `DATABASE_URL` only when explicitly safe.
- Slice 24.0 points both variables to Railway’s direct private PostgreSQL URL.
- Database URLs and startup failures are redacted before error messages are emitted.
- Normal long-running application startup runs neither migrations nor bootstrap.

## Railway pre-deploy command

The versioned `railway.toml` keeps the Railway compatibility command:

```bash
bin/event_sales eval 'EventSales.Release.migrate_and_bootstrap()'
```

`migrate_and_bootstrap/0` composes the release migration and bootstrap operations, in order:

1. All pending Ecto/Ash migrations through the direct migration URL.
2. Application startup for Ash access.
3. Idempotent admin bootstrap.
4. Idempotent active WooCommerce source-system bootstrap.

Any failure exits non-zero and prevents Railway from activating the deployment. Railway pre-deploy containers have private-network and service-variable access but do not share filesystem changes with the running application.

## Separate VPS lifecycle transitions

The VPS production lifecycle uses two distinct one-shot release operations:

1. After the separately authorized direct-database migration transition succeeds, run `EventSales.Release.bootstrap/0` through a temporary runtime explicitly authorized for bootstrap.
2. Recreate the final long-running runtime without migration- or bootstrap-only credentials.

The bootstrap operation starts the application, runs the idempotent admin bootstrap, then the idempotent source-system bootstrap. It does not run migrations. Normal application startup runs neither operation.

These are deployment requirements, not claims that a VPS deployment has occurred. If either one-shot transition fails, preserve its output and resulting state for review; do not blindly rerun it.

## Release operations

Run migrations without bootstrap:

```bash
bin/event_sales eval 'EventSales.Release.migrate()'
```

Run bootstrap without migrations, only in an explicitly bootstrap-authorized temporary runtime and after the migration transition succeeds:

```bash
bin/event_sales eval 'EventSales.Release.bootstrap()'
```

Rollback a repo to a reviewed migration version:

```bash
bin/event_sales eval 'EventSales.Release.rollback(EventSales.Repo, 20260513122000)'
```

Do not run rollback during an incident without confirming data compatibility and taking a current backup.

See also [`docs/runbooks/database-backup-restore.md`](../runbooks/database-backup-restore.md).

## Bootstrap behavior

`mix eventsales.admin.bootstrap` and `mix eventsales.source_system.bootstrap` remain available in a Mix environment. Railway retains `migrate_and_bootstrap/0` for compatibility. The VPS release lifecycle uses the release operations `migrate/0` and `bootstrap/0` separately; these functions are available in an OTP runtime release and do not depend on Mix tasks.

The source bootstrap matches `kind=:woocommerce` plus normalized base URL, creates only when missing, reactivates inactive records, updates changed names, and is safe to repeat. It does not call WooCommerce or alter webhook destinations.
