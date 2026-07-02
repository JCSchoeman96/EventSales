# PgBouncer Strategy

## Slice 24.0 production topology

PgBouncer is intentionally not deployed in Slice 24.0. EventSales, release migrations, and Oban connect directly to Railway’s private managed PostgreSQL endpoint.

This topology preserves PostgreSQL session behavior and `LISTEN/NOTIFY`, allowing the existing `Oban.Notifiers.Postgres` configuration to be tested without transaction-pooling ambiguity. `DATABASE_URL` and `DIRECT_DATABASE_URL` therefore reference the same direct private URL for this slice.

## Deferred flash-sale topology

Direct PostgreSQL is sufficient to prove deployment and production behavior, but it is not final flash-sale certification. Before introducing PgBouncer:

- Choose session or transaction pooling explicitly.
- Keep a direct migration/session-sensitive URL.
- Validate Ecto prepared statements and connection settings.
- Re-run the real Oban success/retry smoke under the selected notifier topology.
- Measure pool saturation and connection demand rather than assuming a pooler is required.
- Document rollback to the direct topology.

Do not add `prepare: :unnamed`, polling notifiers, or transaction-pooling settings without a verified compatibility requirement and tests.
