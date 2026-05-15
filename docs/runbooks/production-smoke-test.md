# Production Smoke Test

## Slice 0.2 Baseline Checks

Run these checks before moving on to production-like topology validation:

```bash
mix deps.get
mix ecto.create
mix ecto.migrate
mix test
mix format --check-formatted
```

## What Slice 0.2 Proves

- Repo starts in `:test`.
- Release migration URL selection prefers `DIRECT_DATABASE_URL`.
- Oban can enqueue and execute a test job in `:test`.
- Local and CI test runs require Postgres but not Redis.

## What Slice 0.2 Does Not Prove

- Production-like Oban behavior behind the selected Railway/PgBouncer topology.
- Railway deployment health, webhook reachability, or protected Oban Web behavior.

Those checks remain with Slice `5.7` and Slice `24.0`.

## Slice 5.7 Oban Topology Smoke

Local mode may run with Mix against local Postgres:

```bash
SMOKE_TOPOLOGY_MODE=local mix run scripts/smoke_test_oban_topology.exs
```

Production-like mode must run with real Oban queues, not ExUnit sandbox or test helpers:

```bash
SMOKE_TOPOLOGY_MODE=production_like \
SMOKE_TIMEOUT_MS=30000 \
SMOKE_POLL_INTERVAL_MS=500 \
mix run scripts/smoke_test_oban_topology.exs
```

Expected output includes:

- `smoke_topology_mode`
- `runtime_db_source`
- `migration_db_source`
- `configured_notifier`
- `queue_config`
- success job ID and final state
- fail-once job ID, final state, attempt count, and error count

Acceptance:

- success job reaches `completed` within `SMOKE_TIMEOUT_MS`.
- fail-once job reaches `completed` within `SMOKE_TIMEOUT_MS`.
- fail-once job has `attempt > 1`.
- fail-once job has at least one persisted error.
- the script exits non-zero on timeout or missing real Oban queue execution.

The script prints DB source names only. It must not print `DATABASE_URL`, `DIRECT_DATABASE_URL`, credentials, host passwords, webhook secrets, or raw payloads.
