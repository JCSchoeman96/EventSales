# Historical Reporting Snapshots

Slice 9.7 introduces durable Postgres snapshot tables for historical reporting:

- `analytics_event_aggregate_snapshots`
- `analytics_daily_sales_aggregate_snapshots`

These tables are derived read models. They are not source truth. Durable sales
truth remains in normalized `sales_orders` and `sales_order_items` rows owned by
the Sales domain.

## Refresh Path

`EventSales.Analytics.SnapshotRefresh` refreshes snapshot rows from scoped
durable sales data. Refreshes may scan one event or one event/date bucket, but
they must delegate all completed-only ticket and revenue decisions to
`EventSales.Analytics.MetricRules`.

`EventSales.Analytics.Workers.RefreshSnapshotWorker` runs refresh work through
Oban on the `analytics_rebuilds` queue. It is scoped by event and optional
business date so long-running report refresh work stays bounded.

## Read Path

`EventSales.Analytics.SnapshotReader` is the read facade for historical
reporting snapshots. Future reporting and dashboard code must use
`SnapshotReader` for historical aggregate reads and `HotStateAggregator` for hot
dashboard reads. It must not scan raw order items on mount.

Slice 10 `DashboardLive` must not call `EventAggregator`, query
`sales_order_items`, use `OrderItem` directly, call `Repo` for report scans, or
call WooCommerce. Dashboard reads should go through `SnapshotReader` and/or
`HotStateAggregator`.

## Materialized View Strategy

True PostgreSQL materialized views are deferred. The current snapshot tables are
plain Ash/Postgres resources because they give explicit refresh scope, ordinary
Ash actions, simple idempotent upserts, and predictable test coverage before the
reporting workload is large enough to justify database-managed materialized view
refreshes.

Add real PostgreSQL materialized views only after a measured reporting query
requires them. At that point, keep the same public read facade so dashboard and
reporting callers do not depend on the physical storage strategy.

## Guardrails

- Snapshot tables are derived read models only.
- Sales/order tables remain source truth.
- Redis remains a cache or warm read model, never durable truth.
- No WooCommerce calls are allowed in snapshot refresh or reads.
- Slice 9.7 does not add dashboard UI, `/admin/dashboard`, KPI cards, or
  ticket-type aggregate math.
