# Production Smoke Test

## Slice 0.2 Baseline Checks

Run these checks before moving on to production-like topology validation:

```bash
mix deps.get
mix ecto.create
mix ecto.migrate
mix test
mix format --check-formatted
MIX_ENV=test mix run scripts/smoke_test_oban_topology.exs
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
