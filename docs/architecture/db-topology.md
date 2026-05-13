# Database Topology

## Slice 0.2 Baseline

- `DATABASE_URL`: normal Phoenix, Ecto, and Oban runtime traffic through PgBouncer session pooling.
- `DIRECT_DATABASE_URL`: direct connection path for release migrations and other session-sensitive maintenance.
- `EventSales.Repo`: uses the pooled runtime path for normal application traffic.
- `EventSales.Release`: prefers `DIRECT_DATABASE_URL` and falls back to `DATABASE_URL` only when the direct path is unavailable and the pooled path is documented safe.

## PgBouncer Rules

- Session pooling is the chosen baseline in Slice `0.2`.
- Transaction pooling is deferred and is not configured in this slice.
- Do not add transaction-pooling-specific Ecto settings or `prepare: :unnamed` without a verified need.
- Oban notifier behavior must be tested under the chosen topology before transaction pooling is considered safe.
- Migrations should use a direct DB URL when available.

## Verification Boundary

- Slice `0.2` proves the local/test baseline: repo startup, direct migration URL selection, and minimal Oban execution in test.
- Slice `5.7` owns production-like Oban/PgBouncer smoke validation.
- Slice `24.0` owns Railway deployment smoke validation.
