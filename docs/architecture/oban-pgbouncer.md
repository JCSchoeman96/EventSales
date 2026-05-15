# Oban and PgBouncer

## Selected Topology

- Oban shares the normal `DATABASE_URL` runtime path.
- That runtime path is PgBouncer **session pooling**, not transaction pooling.
- `DIRECT_DATABASE_URL` is reserved for migrations, release tasks, and session-sensitive maintenance.
- Oban is explicitly configured with `notifier: Oban.Notifiers.Postgres`.
- Queue config is `default: 10` and `webhooks: 10`.

## Notifier Decision

`Oban.Notifiers.Postgres` uses PostgreSQL notifications and is the selected notifier for the current session-pooling topology. The notifier is explicit in config so smoke-test output can report the selected strategy instead of relying on hidden Oban defaults.

PgBouncer transaction pooling can break PostgreSQL `LISTEN/NOTIFY` semantics. EventSales does not rely on transaction pooling for Oban, and it does not claim transaction-pooling compatibility.

`Oban.Notifiers.PG` is not selected in Slice `5.7` because it requires a functional Distributed Erlang cluster to broadcast notifications across nodes. EventSales has not introduced clustering in this slice.

## Slice 5.7 Smoke Scope

- `SMOKE_TOPOLOGY_MODE=local` may run with Mix against local Postgres.
- `SMOKE_TOPOLOGY_MODE=production_like` must run real Oban queues and poll persisted `oban_jobs`.
- The script must not use SQL sandbox, `test/support`, or `Oban.drain_queue/1`.
- The script inserts one success job and one fail-once job.
- The fail-once job must persist an error, retry, and finish `completed` with `attempt > 1`.
- The output reports runtime DB source, migration DB source, notifier, queue config, timeout, poll interval, job IDs, final states, attempt count, and error count.

## Out Of Scope

- PgBouncer transaction pooling.
- `prepare: :unnamed`.
- `Oban.Notifiers.PG`.
- Distributed Erlang clustering.
- Alternative Oban engines.
- Oban Web.
