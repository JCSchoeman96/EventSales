# PgBouncer Strategy

## Slice 0.2 Baseline

- Use PgBouncer session pooling for normal runtime traffic.
- Keep `DIRECT_DATABASE_URL` for migrations and other session-sensitive maintenance.
- Do not add transaction-pooling-specific repo settings in this slice.
- Do not add `prepare: :unnamed` unless a verified compatibility need appears.

## Deferred Compatibility Work

- Transaction pooling is a future optimization, not the Slice `0.2` baseline.
- If transaction pooling is evaluated later, it must come with explicit Ecto/Postgrex and Oban compatibility testing.
- Slice `5.7` is the first place that should prove Oban behavior under the chosen production topology.
