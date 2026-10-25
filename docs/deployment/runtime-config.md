# Runtime configuration

## Local and development runtime

Use `bash scripts/dev_local.sh` for the local EventSales runtime. It verifies the local dependencies, applies development migrations, loads the local catalogue secret without printing it, and starts native Phoenix. Use `bash scripts/dev_local.sh doctor` and `bash scripts/dev_local.sh status` for local configuration and service checks. Do not use the production VPS Compose project for development.

Local tests use the workstation PostgreSQL TEST server through `bash scripts/dev_local.sh test`. Each run gets an EventSales-owned database under the `event_sales_test` prefix; partition suffixes remain unique. Tests use in-memory Redis adapters and do not connect to shared Redis.

## Production artifact and Compose boundary

Production VPS runs a reviewed immutable image reference in this form:

```text
EVENTSALES_IMAGE_REF=ghcr.io/jcschoeman96/eventsales@sha256:<64 lowercase hex characters>
```

The reference belongs to an accepted source commit and tree and a successful GHCR image publication. Production does not build source on the VPS. Use `deploy/vps/app/compose.yaml`; it has no `build:` directive. The loopback overlay is a later, separately authorized transition. This document contains no production start command.

Every production Compose invocation must use `--env-file /dev/null` so Compose cannot load the repository `.env`. `EVENTSALES_DEPLOY_ENV_FILE` identifies a separately protected, root-owned runtime environment file. Its exact path is supplied by later reviewed authority. This documentation and a repository merge do not authorize a production lifecycle; use the [VPS production runbook](vps-production.md) for the separate gates.

## Final runtime environment

The app Compose file supplies these structural values to the container:

```text
PHX_SERVER=true
PORT=4000
POOL_SIZE=20
DNS_CLUSTER_QUERY=eventsales-app
EVENTSALES_NODE_IP=<approved data-network IPv4>
WEBHOOK_REDIS_BUFFER_ENABLED=false
WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED=false
```

The node IP must equal the app's `ipv4_address` on `eventsales-prod_eventsales_data`. The `eventsales-app` alias belongs only to that data network. The approved node identity is `event_sales@EVENTSALES_NODE_IP`; `HOSTNAME` and an edge-network alias are not node or discovery authority.

The protected runtime file contains only the runtime values needed by explicitly enabled production features. The current required runtime inputs are:

| Name | Purpose |
|---|---|
| `DATABASE_URL` | Runtime database URL through PgBouncer to `event_sales_prod`, using `eventsales_runtime`. |
| `REDIS_URL` | Production Redis URL using the `eventsales_runtime` ACL identity and `eventsales:prod:*` namespace. |
| `SECRET_KEY_BASE` | Phoenix signing and encryption key. |
| `PHX_HOST` | Owner-approved public host used by endpoint URL/origin policy. |
| `WEBHOOK_PATH_TOKEN` | Authenticated webhook path token. |
| `WOOCOMMERCE_WEBHOOK_SECRET` | WooCommerce webhook signature secret. |
| `RELEASE_COOKIE` | Externally supplied distributed-release cookie. |

`EVENTSALES_NODE_IP` is also passed by Compose and is not a value to invent or choose before the read-only network collision audit. Set `EVENTSALES_BUSINESS_TIMEZONE` and `EVENTSALES_DEFAULT_CURRENCY` only to their accepted values when overriding the current defaults of `Africa/Johannesburg` and `ZAR`. `EVENTSALES_CHECK_ORIGIN` may be set from the separately approved host/origin decision.

For the approved runtime Redis paths, set `HOT_STATE_REDIS_SNAPSHOTS_ENABLED=true` and `WEBHOOK_RATE_LIMIT_ENABLED=true` only with the accepted values. The current snapshot TTL is `HOT_STATE_REDIS_SNAPSHOT_TTL_MS=3600000`; the rate-limit defaults are `WEBHOOK_RATE_LIMIT_WINDOW_MS=60000` and `WEBHOOK_RATE_LIMIT_MAX_REQUESTS=120`. The default rate-limit URL uses `REDIS_URL`; any explicit `WEBHOOK_RATE_LIMIT_REDIS_URL` or `HOT_STATE_REDIS_URL` override must use the same approved runtime Redis identity and namespace.

The runtime configuration reads additional feature-specific values. Do not include them unless the feature has separate authority and an accepted name-only inventory: WooCommerce REST (`WOOCOMMERCE_REST_BASE_URL`, `WOOCOMMERCE_CONSUMER_KEY`, `WOOCOMMERCE_CONSUMER_SECRET`); the Woo order index (`WOO_ORDER_INDEX_BASE_URL`, `WOO_ORDER_INDEX_KEY_ID`, `WOO_ORDER_INDEX_SECRET`); Tickera catalogue feed (`TICKERA_CATALOG_FEED_*`); and catalogue change receiver/dispatcher (`CATALOG_CHANGE_*`). Keep catalogue auto-Apply, catalogue change receivers, live cutover controls, copied WordPress webhooks, and Redis webhook degraded buffering disabled unless a specific reviewed task enables and tests them.

At final private-runtime acceptance, derive and record the exact container environment-name inventory from the accepted `config/runtime.exs`, `rel/env.sh.eex`, app Compose, and private probe. Record names and role/destination only. Never print `DATABASE_URL`, `REDIS_URL`, secret values, release-cookie values, or password verifiers.

The final long-running runtime must exclude:

```text
DIRECT_DATABASE_URL
EVENTSALES_MIGRATOR_PASSWORD
EVENTSALES_BACKUP_PASSWORD
POSTGRES_BOOTSTRAP_PASSWORD
POSTGRES_PASSWORD
POSTGRES_PASSWORD_FILE
PGPASSWORD
PGPASSFILE
EVENTSALES_SECRET_DIR
all EVENTSALES_BOOTSTRAP_*
```

The current bootstrap-only names are:

```text
EVENTSALES_BOOTSTRAP_ADMIN_EMAIL
EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD
EVENTSALES_BOOTSTRAP_ADMIN_NAME
EVENTSALES_BOOTSTRAP_ADMIN_ROTATE_PASSWORD
EVENTSALES_BOOTSTRAP_SOURCE_NAME
EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL
```

The final app receives no PostgreSQL bootstrap, migrator, backup, PgBouncer-rendering, or Redis ACL source files. Its only database role is `eventsales_runtime` through PgBouncer. Migration and bootstrap use separate, explicitly authorized temporary lifecycles.

## Migration and bootstrap classes

`DIRECT_DATABASE_URL` is migration-only and points directly to PostgreSQL as `eventsales_migrator`. The runtime `DATABASE_URL` through PgBouncer is not migration authority. Bootstrap-only values exist only in the temporary bootstrap lifecycle. Normal app startup runs neither `EventSales.Release.migrate()` nor `EventSales.Release.bootstrap()`.

The release environment sets `RELEASE_DISTRIBUTION=name` and `RELEASE_NODE=event_sales@${EVENTSALES_NODE_IP}`. It binds EPMD and the Erlang distribution listener to the approved data-network address. A private proof must verify actual sockets; configuration alone does not prove the bind. Production and multi-node clustering remain unproven until their authorized gates pass.

## WooCommerce access

`WOOCOMMERCE_REST_BASE_URL`, `WOOCOMMERCE_CONSUMER_KEY`, and `WOOCOMMERCE_CONSUMER_SECRET` are required before live REST ingestion, reconciliation, or metadata recovery is enabled. WooCommerce REST concurrency remains fixed at `2` in runtime configuration. Live cutover needs its own explicit authority.

## Secret handling

Keep local secrets in ignored `.env` or `.env.local` files. Tracked example files contain placeholders only. Store production values only through the separately approved protected environment mechanism. Never commit, print, log, hash for reporting, or pass secret values in command-line arguments.
