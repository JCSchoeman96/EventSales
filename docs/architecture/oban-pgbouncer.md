# Oban and PgBouncer

## Risk

PgBouncer transaction pooling can break PostgreSQL LISTEN/NOTIFY semantics. Oban functionality that relies on notifications must be verified under the selected topology.

## Required Decision

Choose one production strategy:

1. Use direct DB connection for Oban where appropriate.
2. Use PgBouncer-compatible Oban notifier/polling strategy.
3. Use session pooling instead of transaction pooling where supported.

## Smoke Test

- Enqueue a job.
- Observe execution.
- Observe retry/failure behavior.
- Confirm queue health metrics.
