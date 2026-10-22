# Runtime Configuration

## Database and Redis paths

- `DATABASE_URL` is the PostgreSQL connection used by Phoenix, Ecto, Ash, and Oban. For the D1 VPS runtime, it points to PgBouncer.
- `REDIS_URL` is the Redis connection used by webhook rate limiting and by optional hot-state snapshots or degraded-mode buffering.
- Docker Compose reads these URLs from a protected deployment environment file selected through `EVENTSALES_DEPLOY_ENV_FILE`. Pass `--env-file /dev/null` to Compose so it does not load the repository root `.env`. Its dependencies remain externally managed or separately project-owned; the repository Compose file does not duplicate workstation shared DEV/TEST services.
- The app listens on `PORT`; the canonical Compose contract uses the container port `4000`.

Example single-host deployment command:

```bash
EVENTSALES_DEPLOY_ENV_FILE=/etc/eventsales/eventsales.env \
  docker compose --env-file /dev/null up -d --build
```

## Credential classes

### Final long-running runtime

The final D1 VPS runtime receives runtime-required values only. Depending on enabled features, these include:

```text
DATABASE_URL
REDIS_URL
SECRET_KEY_BASE
PHX_HOST
EVENTSALES_BUSINESS_TIMEZONE=Africa/Johannesburg
EVENTSALES_DEFAULT_CURRENCY=ZAR
HOT_STATE_REDIS_SNAPSHOTS_ENABLED=true
WEBHOOK_PATH_TOKEN
WOOCOMMERCE_WEBHOOK_SECRET
DNS_CLUSTER_QUERY
EVENTSALES_NODE_IP
RELEASE_COOKIE
WOOCOMMERCE_REST_BASE_URL
WOOCOMMERCE_CONSUMER_KEY
WOOCOMMERCE_CONSUMER_SECRET
```

Feature-specific values are present only when the corresponding runtime feature requires them. The final long-running VPS runtime must exclude:

```text
DIRECT_DATABASE_URL
EVENTSALES_BOOTSTRAP_ADMIN_EMAIL
EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD
EVENTSALES_BOOTSTRAP_ADMIN_NAME
EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD
EVENTSALES_BOOTSTRAP_SOURCE_NAME
EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL
```

### Migration-only

`DIRECT_DATABASE_URL` is the D1 VPS migration-only database path. The VPS migration transition uses the direct PostgreSQL route; pooled PgBouncer is not the migration authority. Release migration code retains its Railway compatibility fallback to `DATABASE_URL` only where that fallback has already been established as safe.

### Bootstrap-only

The bootstrap-only class is:

```text
EVENTSALES_BOOTSTRAP_ADMIN_EMAIL
EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD
EVENTSALES_BOOTSTRAP_ADMIN_NAME
EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD
EVENTSALES_BOOTSTRAP_SOURCE_NAME
EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL
```

The temporary bootstrap-authorized application needs the union of the runtime and bootstrap classes because it starts the application to run Ash bootstrap operations. These classes remain distinct. After bootstrap succeeds, recreate the final long-running runtime with the bootstrap-only class absent.

## D1 release contract

The D1 production deployment contract will set `DNS_CLUSTER_QUERY=eventsales-app`, provide an approved `EVENTSALES_NODE_IP` on the internal EventSales data network, and provide `RELEASE_COOKIE` through the protected secret mechanism. `rel/env.sh.eex` sets `RELEASE_DISTRIBUTION=name`, `RELEASE_NODE=event_sales@${EVENTSALES_NODE_IP}`, and `ERL_EPMD_ADDRESS=${EVENTSALES_NODE_IP}` only when the node IP is supplied; it fails safely if the IP is invalid or the node IP is set without a cookie. For long-running server commands and distributed helper commands, it appends the matching IPv4 tuple as the kernel `inet_dist_use_interface` setting while preserving existing `ELIXIR_ERL_OPTIONS`. `eval` and `version` do not receive that listener option. Other release environments that omit the node IP are not forced into VPS distribution settings.

The node IP is not selected in R1. R4 will choose it after a read-only VPS Docker-network collision audit and use the same value for the app attachment's `ipv4_address`. The deployment contract places the `eventsales-app` alias on the internal data network and configures the Erlang distribution listener to bind to `EVENTSALES_NODE_IP`. The private runtime proof must inspect the actual BEAM listener and EPMD sockets, confirm no distribution listener on the edge IP, confirm no host-published distribution port, and verify that `eventsales-app` resolves to the expected data-network peer IP set. Production and multi-node clustering have not been runtime-proven.

`EventSales.Repo` defaults to `POOL_SIZE=20` in the production runtime configuration. A deployment may override it with `POOL_SIZE`; the default and override behavior are covered by a focused test. This is a client-pool setting, not a PgBouncer server-pool setting.

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
