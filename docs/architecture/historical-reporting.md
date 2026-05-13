# Historical Reporting Strategy

Use indexed Postgres queries initially, then EventAggregateSnapshot / DailySalesAggregateSnapshot and optional materialized views for heavier reporting. Dashboard mounts must not run unbounded order_items scans.
