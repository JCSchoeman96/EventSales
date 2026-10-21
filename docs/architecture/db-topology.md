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

- The approved D1 production target sends `DATABASE_URL` runtime traffic through PgBouncer **transaction pooling**.
- `DIRECT_DATABASE_URL` remains the direct PostgreSQL path for migrations and bootstrap work. R2 will define their separate entrypoints.
- `EventSales.Repo` uses only the runtime path during normal application work.
- `EventSales.Release` currently prefers `DIRECT_DATABASE_URL` and falls back to `DATABASE_URL` when the direct path is unavailable. R2 will separate the production migration entrypoint before D1 deployment.
- Smoke-test output reports only the selected source name, never the URL value.

## PgBouncer Rules

- The approved D1 production target uses transaction pooling with `max_prepared_statements=200`.
- Oban uses `Oban.Notifiers.PG`; runtime notifications must not depend on PostgreSQL `LISTEN/NOTIFY` sessions.
- Keep Postgrex named preparation enabled unless a later transaction-pooling proof demonstrates a concrete incompatibility and a separate review approves a change.
- Older Slice `5.7` and Railway records describe the historical direct/session-pooling topology. They do not define the D1 production target.

## Distributed Runtime Boundary

- D1 production releases use Erlang long names with the stable basename `event_sales` and the node's internal IPv4: `RELEASE_DISTRIBUTION=name` and `RELEASE_NODE=event_sales@${EVENTSALES_NODE_IP}`.
- `EVENTSALES_NODE_IP` will be selected only after a read-only VPS Docker-network collision audit. The later app network's `ipv4_address` and this variable must use the same approved value.
- `DNS_CLUSTER_QUERY=eventsales-app` is supplied by the production deployment contract. The locked `dns_cluster` 0.2.0 resolves that query to IPs and forms peer names from the current node basename and each returned IP.
- The deployment contract places the `eventsales-app` alias only on the internal EventSales data network. When `EVENTSALES_NODE_IP` is set, `rel/env.sh.eex` configures EPMD with that address and configures the Erlang distribution listener with `inet_dist_use_interface` for the same address on `start*` and `daemon*` commands. R4 must verify the actual Docker address assignments, BEAM and EPMD listening sockets, DNS answers, and absence of a host-published distribution port.
- `RELEASE_COOKIE` is an externally supplied production secret. R1 configures the release contract but does not prove production or multi-node clustering.

## Verification Boundary

- Slice `0.2` proves the local/test baseline: repo startup, direct migration URL selection, and minimal Oban execution in test.
- Slice `5.7` proves real Oban queue execution, retry visibility, notifier reporting, queue config reporting, and migration URL-source reporting under the selected topology.
- Slice `24.0` owns Railway deployment smoke validation.

## Historical Slice 5.5 — Webhook intake under pool pressure

- Normal intake persists to Postgres via `WebhookEventStore` and enqueues `ProcessWebhookWorker` through `WebhookEnqueue.enqueue_processing_once/1`.
- When `EventSales.Repo` checkout/queue times out (pool saturation), intake may push to the optional Redis buffer **only if** `WEBHOOK_REDIS_BUFFER_ENABLED` and `WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED` are both true and `REDIS_URL` is configured (fail-closed at boot otherwise).
- If the buffer is disabled or full, intake returns **503** so WooCommerce retries — never a silent 2xx without Postgres or an accepted buffer entry.
- The saturated request path does **not** enqueue the drainer (Oban also needs Postgres). Run `RedisWebhookBufferDrainer` manually or via scheduler when Postgres is healthy.
- This slice recorded the pre-D1 **session-pooling** topology. The approved D1 target supersedes it with transaction pooling.
