# Runtime Configuration

## Database and Redis paths

- `DATABASE_URL` is the PostgreSQL connection used by Phoenix, Ecto, Ash, and Oban.
- `DIRECT_DATABASE_URL` is the preferred release migration path. The runtime may use `DATABASE_URL` when both values refer to the same direct service.
- `REDIS_URL` is the Redis connection used by webhook rate limiting and by optional hot-state snapshots or degraded-mode buffering.
- Docker Compose reads these URLs from a protected deployment environment file selected through `EVENTSALES_DEPLOY_ENV_FILE`. Pass `--env-file /dev/null` to Compose so it does not load the repository root `.env`. Its dependencies remain externally managed or separately project-owned; the repository Compose file does not duplicate workstation shared DEV/TEST services.
- The app listens on `PORT`; the canonical Compose contract uses the container port `4000`.

Example single-host deployment command:

```bash
EVENTSALES_DEPLOY_ENV_FILE=/etc/eventsales/eventsales.env \
  docker compose --env-file /dev/null up -d --build
```

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

Set secrets through the selected deployment's protected environment mechanism.
Never commit values, place them in command-line arguments, or print them. Safe
templates such as `.env.example` contain placeholders only.

## Local test requirement

Local tests use the workstation PostgreSQL TEST server through
`bash scripts/dev_local.sh test`. Each run gets an EventSales-owned database
under the `event_sales_test` prefix; partition suffixes remain unique. Tests
use in-memory Redis adapters and do not connect to shared Redis.
