# Slice 5.7 — Oban/PgBouncer Production Topology Smoke Test

## Task
Prove Oban runs correctly under the selected Railway/Postgres/PgBouncer topology.

## Objective
Avoid discovering at launch that queue notifications, retries, or migrations fail behind PgBouncer transaction pooling.

## Output
- `scripts/smoke_test_oban_topology.exs`
- `docs/architecture/oban-pgbouncer.md`
- `docs/architecture/db-topology.md`
- production topology checklist

## Strict Tests
- A job enqueues and executes in production-like config.
- Queue failure/retry behavior is observable.
- The chosen Oban notifier/polling strategy is documented.
- Migrations use a direct/safe DB path.

## Note
PgBouncer transaction pooling may break LISTEN/NOTIFY behavior. Do not assume Oban notification behavior without a smoke test.
