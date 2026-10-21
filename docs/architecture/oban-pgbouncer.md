# Oban and PgBouncer

## Approved D1 target topology

- Oban SQL shares the normal `DATABASE_URL` runtime path through PgBouncer **transaction pooling**.
- Migrations use direct PostgreSQL through `DIRECT_DATABASE_URL`; R2 will define their separate entrypoints.
- Oban notifications use `Oban.Notifiers.PG`, while queue rows and job durability remain in PostgreSQL.
- Queue config keeps `default: 10` and `webhooks: 10`.
- This is the approved repository target and has not yet been deployed to production.

## Notifier Decision

`Oban.Notifiers.PG` publishes notifications through Erlang process groups. This avoids PostgreSQL session-level `LISTEN/NOTIFY` through the transaction pool. The notifier is explicit in config so tests and later runtime evidence can identify the selected strategy.

The existing `DNSCluster` supervisor remains the node-discovery boundary. D1 production releases use `RELEASE_DISTRIBUTION=name` and `RELEASE_NODE=event_sales@${EVENTSALES_NODE_IP}`, with a shared externally supplied `RELEASE_COOKIE`. `DNS_CLUSTER_QUERY=eventsales-app` resolves peers by IP; the locked `dns_cluster` 0.2.0 uses the local node basename for the discovered peer names. The alias belongs on the internal EventSales data network, away from the edge network. The IP is chosen after a read-only VPS network collision audit. R1 configures this contract but does not prove production or multi-node clustering.

The earlier Railway and Slice `5.7` topology used `Oban.Notifiers.Postgres` with direct or session-pooled PostgreSQL. That is historical context, not the approved D1 production target.

The later private runtime proof must exercise prepared Ecto/Ash queries through PgBouncer with named prepared statements enabled and `max_prepared_statements=200`. Do not add `prepare: :unnamed` without a failed proof and separate approval.

## Slice 5.7 Smoke Scope

- `SMOKE_TOPOLOGY_MODE=local` may run with Mix against local Postgres.
- `SMOKE_TOPOLOGY_MODE=production_like` must run real Oban queues and poll persisted `oban_jobs`.
- The script must not use SQL sandbox, `test/support`, or `Oban.drain_queue/1`.
- The script inserts one success job and one fail-once job.
- The fail-once job must persist an error, retry, and finish `completed` with `attempt > 1`.
- The output reports runtime DB source, migration DB source, notifier, queue config, timeout, poll interval, job IDs, final states, attempt count, and error count.

## Historical Slice 5.7 boundary

Slice `5.7` preceded the D1 decision and did not prove transaction-pooling compatibility, the PG notifier, or distributed clustering. Alternative Oban engines and Oban Web remain out of scope.
