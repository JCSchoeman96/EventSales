# Migrations and Release Initialization

## Runtime contract

- `DATABASE_URL` serves application traffic.
- `DIRECT_DATABASE_URL` is preferred by `EventSales.Release.migrate/0` and falls back to `DATABASE_URL` only when explicitly safe.
- Slice 24.0 points both variables to Railway’s direct private PostgreSQL URL.
- Database URLs and startup failures are redacted before error messages are emitted.

## Railway pre-deploy command

The versioned `railway.toml` runs:

```bash
bin/event_sales eval 'EventSales.Release.migrate_and_bootstrap()'
```

The release entry point executes, in order:

1. All pending Ecto/Ash migrations through the direct migration URL.
2. Application startup for Ash access.
3. Idempotent admin bootstrap.
4. Idempotent active WooCommerce source-system bootstrap.

Any failure exits non-zero and prevents Railway from activating the deployment. Railway pre-deploy containers have private-network and service-variable access but do not share filesystem changes with the running application.

## Manual release commands

Migrate without bootstrap:

```bash
bin/event_sales eval 'EventSales.Release.migrate()'
```

Rollback a repo to a reviewed migration version:

```bash
bin/event_sales eval 'EventSales.Release.rollback(EventSales.Repo, 20260513122000)'
```

Do not run rollback during an incident without confirming data compatibility and taking a current backup.

See also [`docs/runbooks/database-backup-restore.md`](../runbooks/database-backup-restore.md).

## Bootstrap behavior

`mix eventsales.admin.bootstrap` and `mix eventsales.source_system.bootstrap` remain available in a Mix environment. Production releases use `migrate_and_bootstrap/0` because Mix tasks are not included in an OTP runtime release.

The source bootstrap matches `kind=:woocommerce` plus normalized base URL, creates only when missing, reactivates inactive records, updates changed names, and is safe to repeat. It does not call WooCommerce or alter webhook destinations.
