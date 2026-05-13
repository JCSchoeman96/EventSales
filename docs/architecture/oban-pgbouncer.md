# Oban and PgBouncer

## Slice 0.2 Decision

- Oban shares the normal `DATABASE_URL` runtime path.
- That runtime path is PgBouncer session pooling, not transaction pooling.
- `DIRECT_DATABASE_URL` is reserved for migrations, release tasks, and session-sensitive maintenance.
- Slice `0.2` keeps Oban intentionally minimal: one supervised Oban instance, no plugins, no cron, no Oban Web, and no real ingestion workers.

## Current Risk

PgBouncer transaction pooling can break PostgreSQL `LISTEN/NOTIFY` semantics. That means the default Postgres notifier must not be assumed safe under transaction pooling without an explicit smoke test.

## Deferred Work

- Transaction-pooling compatibility is deferred.
- A PgBouncer-compatible notifier or polling strategy is future work if the project moves away from session pooling.
- Slice `5.7` is the first slice that should claim production-like Oban/PgBouncer proof.

## Slice 0.2 Smoke Scope

- Enqueue a test job in `:test`.
- Drain the queue synchronously.
- Verify the job completes without relying on sleeps or production queue assumptions.
