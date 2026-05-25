# Admin Dashboard Chart Contracts (V1)

**Slice:** 23.1 — contracts for Slice 23.2 chart rendering

**Canonical Chart.js pattern:** `lib/event_sales_web/live/admin/components/sales_chart.ex`

**Global Chart.js:** `chart.js@4.4.4` in `lib/event_sales_web/components/layouts/root.html.heex` — do **not** import Chart.js in `assets/js/app.js`.

---

## Shared Chart.js rendering rules (23.2)

1. Use `EventSalesWeb.Live.Admin.Components.SalesChart` as the reference implementation for line/area dual-axis trends.
2. Assign a **stable unique** canvas id (e.g. `sales-chart-main`).
3. Pass numeric series via `data-labels`, `data-revenue`, `data-tickets` JSON attributes on the canvas.
4. Set `phx-update="ignore"` on the canvas (or chart wrapper) so LiveView does not patch an active chart.
5. **Destroy** any existing `canvas._chart` instance before creating a new `Chart(...)`.
6. Chart values must be JSON-serializable **numbers** for revenue/tickets — not `Decimal` structs.
7. Do not compute chart series from raw `Order` / `OrderItem` queries in LiveView or components.
8. No new npm chart dependencies in 23.2.

---

## Timezone and currency

- **Business timezone:** `EventSales.Analytics.MetricRules.business_timezone/0` (used by snapshots and daily summaries).
- **Default currency:** `Application.get_env!(:event_sales, :default_currency)` on event rows; chart labels may show currency in axis/tooltip formatters.
- **Nil handling:** Missing snapshot/cache → zero counts and `Decimal.new("0")` revenue in tables; chart empty state, not fabricated buckets.

---

## Chart: `sales_trend`

| Field | Value |
|-------|-------|
| **Purpose** | Completed-ticket revenue and ticket count over time (admin-wide) |
| **Chart type** | Line, dual Y-axis (revenue left, tickets right) |
| **Data source (23.1)** | **Not in snapshot** — Option B |
| **Data source (future)** | `AdminDashboard.snapshot/0` → `:daily_buckets` (future backend slice) |
| **LiveView today** | `DashboardLive.assign_chart_data/1` reads `Map.get(dashboard, :daily_buckets, [])` → `@chart_labels`, `@chart_revenue`, `@chart_tickets` |

### Input shape (future `daily_buckets`)

List of buckets, sorted ascending by `date`:

```elixir
[
  %{date: ~D[2026-05-20], revenue_cents: 120_000, tickets_sold: 4},
  %{date: ~D[2026-05-21], revenue_cents: 160_000, tickets_sold: 7}
]
```

`DashboardLive` maps to chart assigns:

- `labels` → `Date.to_string(date)`
- `revenue` → `div(revenue_cents, 100)` (integer dollars/units for Chart.js)
- `tickets` → `tickets_sold`

### Empty shape (23.1 / current)

```elixir
daily_buckets = []
# => chart_labels == [], chart_revenue == [], chart_tickets == []
```

**23.2 requirement:** Render an explicit empty-state (message or placeholder card). Do not leave a broken or uninitialized canvas.

### Bounds (future implementation)

- Max **30** calendar days (configurable, must stay bounded)
- Data from `DailySalesAggregateSnapshot` via a bounded `SnapshotReader` range API — **no** raw order table scans
- Aggregate across displayed events (max 50) per business date

### Sort order

Ascending by `date`.

### PII

No per-order or customer fields in chart series.

### Chart.js notes

- Match `SalesChart` dataset keys and dual-axis ids (`yR`, `yT`).
- Revenue axis formatter may prefix currency (e.g. `R`) client-side.

---

## Chart: `tickets_by_event`

| Field | Value |
|-------|-------|
| **Purpose** | Ticket volume comparison across events |
| **Chart type** | Bar (23.2) or table (current 23.1 table) |
| **Data source** | `snapshot.events` |
| **Input shape** | `labels` = event names; `values` = `total_sold` per row |
| **Empty shape** | `events == []` |
| **Sort** | Event name ascending (facade order) |
| **Max rows** | 50 (event limit) |
| **Currency** | N/A (ticket counts) |
| **PII** | None |

---

## Chart: `revenue_by_event`

| Field | Value |
|-------|-------|
| **Purpose** | Revenue comparison across events |
| **Chart type** | Bar (23.2) or table (current) |
| **Data source** | `snapshot.events` |
| **Input shape** | `labels` = event names; `values` = `Decimal` or numeric revenue per row |
| **Empty shape** | `events == []` |
| **Sort** | Event name ascending |
| **Max rows** | 50 |
| **Currency** | Per-row `currency` (display formatting in 23.2) |
| **PII** | None |

For Chart.js, convert `Decimal` to numbers in LiveView before passing to `data-*` attributes.

---

## Chart: `tickets_by_ticket_type`

| Field | Value |
|-------|-------|
| **Purpose** | Tickets sold by ticket type (across events) |
| **Chart type** | Bar (23.2) or table (current) |
| **Data source** | `snapshot.ticket_types` |
| **Input shape** | `labels` = `"{event_name} — {ticket_type_name}"` or separate dimensions; `values` = `total_sold` |
| **Empty shape** | `ticket_types == []` |
| **Sort** | `{event_name, ticket_type_name}` ascending |
| **Max rows** | Bounded by facade row scan (1000 item cap before aggregation) |
| **PII** | None |

Only completed mapped ticket line items are included in facade totals.

---

## Chart: `status_breakdown`

| Field | Value |
|-------|-------|
| **Purpose** | Operational order status distribution (not sold-ticket KPIs) |
| **Chart type** | Doughnut (23.2) or status badges (current) |
| **Data source** | `snapshot.statuses` |
| **Input shape** | `labels` = status strings; `counts` = non-negative integers |
| **Empty shape** | `statuses == %{}` |
| **Sort** | Stable string key order (e.g. alphabetical) for 23.2 charts |
| **Max segments** | Sum of per-event breakdowns (bounded by event count) |
| **PII** | None |

**Semantics:** A high `pending` count does **not** increase `kpis.total_sold`. Status chart is operational visibility only.

### Chart.js notes (23.2 doughnut)

- Use same PII and aggregate rules as badges.
- Empty: show empty-state panel, not a default slice with fake data.

---

## Contract maintenance

When adding `:daily_buckets` to `AdminDashboard.snapshot/0`:

1. Update this file (`sales_trend` data source = present).
2. Update `admin_dashboard_v1_spec.md`.
3. Update `@snapshot_keys` in `admin_dashboard_contract_test.exs`.
4. Implement bounded snapshot reads only — document limits here.
