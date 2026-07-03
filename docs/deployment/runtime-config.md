# Runtime Configuration

## Database and Redis paths

- `DATABASE_URL` is the private Railway PostgreSQL URL used by Phoenix, Ecto, Ash, and Oban.
- `DIRECT_DATABASE_URL` is the release migration path. Slice 24.0 references the same direct private PostgreSQL URL because PgBouncer is not deployed.
- `REDIS_URL` is the managed Redis connection used by hot-state snapshots when `HOT_STATE_REDIS_SNAPSHOTS_ENABLED=true`.
- The app must listen on Railway’s injected `PORT`.

## Required production variables

```text
DATABASE_URL
DIRECT_DATABASE_URL
REDIS_URL
SECRET_KEY_BASE
PHX_HOST
EVENTSALES_BUSINESS_TIMEZONE=Africa/Johannesburg
EVENTSALES_DEFAULT_CURRENCY=ZAR
HOT_STATE_REDIS_SNAPSHOTS_ENABLED=true
WEBHOOK_PATH_TOKEN
WOOCOMMERCE_WEBHOOK_SECRET
EVENTSALES_BOOTSTRAP_ADMIN_EMAIL
EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD
EVENTSALES_BOOTSTRAP_ADMIN_NAME
EVENTSALES_BOOTSTRAP_SOURCE_NAME
EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL
```

`WOOCOMMERCE_REST_BASE_URL`, `WOOCOMMERCE_CONSUMER_KEY`, and `WOOCOMMERCE_CONSUMER_SECRET` must be set before live ingestion, reconciliation, or metadata recovery is enabled. WooCommerce REST concurrency remains fixed at `2` in runtime configuration.

Live cutover controls:

```text
EVENTSALES_LIVE_CUTOVER_ENABLED=true
WEBHOOK_RATE_LIMIT_ENABLED=true
WEBHOOK_RATE_LIMIT_WINDOW_MS=60000
WEBHOOK_RATE_LIMIT_MAX_REQUESTS=120
WEBHOOK_RATE_LIMIT_REDIS_URL=<optional override; defaults to REDIS_URL>
```

When `EVENTSALES_LIVE_CUTOVER_ENABLED=true`, boot fails unless `WooCommerceRestConfig.validate_for_live_cutover!/0` passes.

Optional smoke controls:

```text
EVENTSALES_PUBLIC_BASE_URL
EVENTSALES_SMOKE_TIMEOUT_MS=60000
EVENTSALES_SMOKE_POLL_INTERVAL_MS=500
RAILWAY_SERVICE=EventSales
```

`EVENTSALES_PUBLIC_BASE_URL` is only needed when the generated `RAILWAY_PUBLIC_DOMAIN` should be overridden. It must use HTTPS.

## Secret handling

Set secrets through Railway stdin or its secret variable UI. Never commit values, place them in command-line arguments, or print them. The release bootstrap and smoke harness print safe status labels only.

## Local test requirement

PostgreSQL must be running for `mix test`. Use `bash scripts/dev_postgres.sh start`, then create and migrate the test database with `MIX_ENV=test mix ecto.create` and `MIX_ENV=test mix ecto.migrate`. Local tests do not require Redis.
