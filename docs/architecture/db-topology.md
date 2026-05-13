# Database Topology

## Required Production Concepts

- `DATABASE_URL`: normal app traffic; may be pooled.
- `DIRECT_DATABASE_URL`: migrations and session-sensitive operations where needed.
- `EventSales.Repo`: AshPostgres/Ecto repository.
- `EventSales.Release`: release migration helper.

## PgBouncer Rules

- Transaction pooling is not automatically safe for every feature.
- If transaction pooling is used, configure and test Ecto/Postgrex prepared statement behavior.
- Oban notifier behavior must be tested under the chosen topology.
- Migrations should use a direct DB URL when available.
