# Slice 0.2 — Repo, PgBouncer, Release, and DB Topology Baseline

## Task
Create the explicit database topology foundation before Ash resources and Oban workers depend on it.

## Objective
Avoid hidden deployment failures around Railway, PgBouncer, migrations, Ecto prepared statements, and Oban notifier behavior.

## Output
- `lib/event_sales/repo.ex`
- `lib/event_sales/release.ex`
- runtime config for `DATABASE_URL` and optional `DIRECT_DATABASE_URL`
- docs for PgBouncer/Oban topology
- smoke test script for production-like Oban job execution

## Strict Tests
- Repo starts in test.
- Runtime config reads DB env variables safely.
- Release migration path uses direct URL if provided.
- Oban can enqueue and execute a test job.
- PgBouncer compatibility notes are documented.

## Note
Do not assume PgBouncer transaction pooling is safe for all workloads. Use direct DB URL for migrations/session-sensitive tasks where needed. Oban must be tested under the production topology.
