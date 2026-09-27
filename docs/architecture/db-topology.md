# Database Topology

## Local development

The workstation Dockge `dev-core` stack owns the shared PostgreSQL services.
EventSales connects only to its own database and role on each cluster:

| Environment | Endpoint | Database | Role |
| --- | --- | --- | --- |
| Development | `127.0.0.1:55432` | `event_sales_dev` | `eventsales_dev` |
| Test | `127.0.0.1:55433` | `event_sales_test` plus the existing partition suffix | `eventsales_test` |

PostgreSQL 18 is the project baseline. Tests must use the TEST cluster and
must never connect to development data. Local test runs use a run-specific
database name under the `event_sales_test` prefix; `MIX_TEST_PARTITION` remains
appended for partitioned runs.

## Runtime Paths

- `DATABASE_URL`: normal Phoenix, Ecto, and Oban runtime traffic through PgBouncer **session pooling**.
- `DIRECT_DATABASE_URL`: preferred direct connection path for release migrations and other session-sensitive maintenance.
- `EventSales.Repo`: uses the pooled runtime path for normal application traffic.
- `EventSales.Release`: prefers `DIRECT_DATABASE_URL` and falls back to `DATABASE_URL` only when the direct path is unavailable and the pooled path is documented safe.
- Smoke-test output reports only the selected source name, never the URL value.

## PgBouncer Rules

- Session pooling is the selected topology through Slice `5.7`.
- Transaction pooling is not configured or selected.
- Do not add transaction-pooling-specific Ecto settings or `prepare: :unnamed` without an actual transaction-pooling switch and its own proof.
- Oban uses `Oban.Notifiers.Postgres` under the selected session-pooling topology.
- Migrations should use `DIRECT_DATABASE_URL` when available.

## Verification Boundary

- Slice `0.2` proves the local/test baseline: repo startup, direct migration URL selection, and minimal Oban execution in test.
- Slice `5.7` proves real Oban queue execution, retry visibility, notifier reporting, queue config reporting, and migration URL-source reporting under the selected topology.
- Slice `24.0` owns Railway deployment smoke validation.

## Slice 5.5 — Webhook intake under pool pressure

- Normal intake persists to Postgres via `WebhookEventStore` and enqueues `ProcessWebhookWorker` through `WebhookEnqueue.enqueue_processing_once/1`.
- When `EventSales.Repo` checkout/queue times out (pool saturation), intake may push to the optional Redis buffer **only if** `WEBHOOK_REDIS_BUFFER_ENABLED` and `WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED` are both true and `REDIS_URL` is configured (fail-closed at boot otherwise).
- If the buffer is disabled or full, intake returns **503** so WooCommerce retries — never a silent 2xx without Postgres or an accepted buffer entry.
- The saturated request path does **not** enqueue the drainer (Oban also needs Postgres). Run `RedisWebhookBufferDrainer` manually or via scheduler when Postgres is healthy.
- PgBouncer remains on **session pooling**; do not enable transaction pooling without Slice `5.7` proof.
