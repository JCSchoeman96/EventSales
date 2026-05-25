# Admin Dashboard V1 — Data Contract and UX Specification

**Slice:** 23.1 (contracts only — not the frontend build)

**Audience:** Engineers and agents implementing Slice 23.2 (admin dashboard UI polish).

## Scope statement

This specification applies to the **internal admin dashboard only** (`/admin/dashboard`).

It does **not** define:

- A client or event-owner dashboard
- Public routes or exports
- External APIs
- Raw webhook payload display

This specification does **not** expose PII. It does **not** call WooCommerce or Tickera from web code. All dashboard data must come from existing aggregate/read facades (`EventSales.Analytics.AdminDashboard`, `HotStateAggregator`, `SnapshotReader`, bounded Postgres reads inside the facade).

## Data source rules

| Allowed | Forbidden in LiveView/components |
|---------|----------------------------------|
| `EventSales.Analytics.AdminDashboard` | `WooCommerceClient`, Tickera clients |
| `EventSales.Analytics.HotStateAggregator` | `Req`, `Finch`, `HTTPoison`, `Tesla` |
| `EventSales.Analytics.SnapshotReader` (via facade) | Direct `Repo` / raw SQL from web |
| `EventSales.Analytics.DashboardPubSub` | `WebhookEvent.payload` |
| `OrderItemMapper.list_unmapped_queue/1` (via facade) | `Order.customer_email`, `customer_name`, payment transaction IDs |

`EventSales.Analytics.EventScopedDashboard` exists for future event-scoped surfaces; it must not replace this admin contract in 23.2.

---

## V1 snapshot contract (`AdminDashboard.snapshot/0`)

Top-level map keys are **exactly** seven (no `:daily_buckets` in 23.1):

```elixir
%{
  kpis: %{
    total_sold: non_neg_integer(),
    total_revenue: Decimal.t(),
    today_sold: non_neg_integer(),
    today_revenue: Decimal.t()
  },
  events: [event_row()],
  statuses: %{String.t() => non_neg_integer()},
  ticket_types: [ticket_type_row()],
  recent_orders: [recent_order_row()],
  unmapped_alerts: [unmapped_alert_row()],
  hot_state: map()  # from HotStateAggregator.status/0
}
```

### Event row

```elixir
%{
  event_id: Ecto.UUID.t(),
  event_name: String.t(),
  total_sold: non_neg_integer(),
  total_revenue: Decimal.t(),
  today_sold: non_neg_integer(),
  today_revenue: Decimal.t(),
  status_breakdown: %{String.t() => non_neg_integer()},
  currency: String.t(),
  refreshed_at: DateTime.t() | nil
}
```

Event KPI totals come from hot cache or durable snapshots only. They do **not** backfill from raw order items when cache/snapshot is missing (zeros are correct).

`stale?` on event rows is **not** in the v1 contract; 23.2 may derive staleness from `refreshed_at` and `hot_state`.

### Ticket type row

```elixir
%{
  event_id: Ecto.UUID.t(),
  event_name: String.t(),
  ticket_type_id: Ecto.UUID.t() | nil,
  ticket_type_name: String.t(),
  total_sold: non_neg_integer(),
  total_revenue: Decimal.t()
}
```

Only **completed** orders with **mapped** **ticket** line items contribute. Pending, unmapped, non-ticket, and non-completed rows are excluded.

### Recent order row (PII-safe)

```elixir
%{
  order_number: String.t(),
  status: atom() | String.t(),
  currency: String.t(),
  raw_total: Decimal.t(),
  completed_at: DateTime.t() | nil,
  updated_at_source: DateTime.t() | nil
}
```

**Must never appear:** `customer_email`, `customer_name`, `billing`, `shipping`, `payment_gateway_transaction_id`, `transaction_id`, `payload`, `raw_payload`.

### Unmapped alert row (operational only)

```elixir
%{
  order_number: String.t() | nil,
  name: String.t(),
  woo_product_id: integer() | nil,
  woo_variation_id: integer() | nil,
  mapping_status: atom(),
  quantity: integer(),
  updated_at: DateTime.t()
}
```

### Sales trend / `daily_buckets` (Option B — not in v1 snapshot)

`:daily_buckets` is **not** part of `AdminDashboard.snapshot/0` in Slice 23.1. `DashboardLive` uses `Map.get(dashboard, :daily_buckets, [])` and renders an empty sales trend safely.

Future bucket shape (documented for a later backend/chart-data slice):

```elixir
%{date: ~D[2026-05-20], revenue_cents: 120_000, tickets_sold: 4}
```

When `:daily_buckets` is added, update this spec, chart contracts, and `admin_dashboard_contract_test.exs` in the **same PR**.

---

## Dashboard sections

### 1. Page shell

- **Owner (23.2):** `EventSalesWeb.Live.Admin.DashboardLive`
- **Data:** `load_dashboard/1`, `@page_title`, flash assigns, `@load_error`
- **Route:** `/admin/dashboard` (internal admin pipeline)

### 2. KPI summary cards

- **Owner:** `EventSalesWeb.Live.Admin.Components.StatCard`
- **Data:** `snapshot.kpis` — four metrics only (no `unmapped_count` or failed-job counts in v1)

### 3. Sales trend chart

- **Owner:** `EventSalesWeb.Live.Admin.Components.SalesChart` (live component)
- **Data today:** `@chart_labels`, `@chart_revenue`, `@chart_tickets` from `assign_chart_data/1` (empty when no `:daily_buckets`)
- **23.2:** Must show a clear **empty state** when all three lists are empty — not a broken Chart.js canvas

### 4. Status breakdown

- **Owner:** `EventSalesWeb.Live.Admin.Components.StatusBadge`
- **Data:** `snapshot.statuses` (merged from event `status_breakdown` maps)
- **Semantics:** Counts are operational order-status distribution; non-completed statuses do **not** count as sold tickets in KPIs

### 5. Unmapped item alerts

- **Owner:** `EventSalesWeb.Live.Admin.Components.UnmappedItemAlert`
- **Data:** `snapshot.unmapped_alerts` (bounded queue via facade)

### 6. By-event table

- **Owner:** `DashboardLive` (inline table in 23.1)
- **Data:** `snapshot.events`, sorted by catalog name ascending (facade default)

### 7. By-ticket-type table

- **Owner:** `DashboardLive` (inline table)
- **Data:** `snapshot.ticket_types`, sorted by `{event_name, ticket_type_name}`

### 8. Recent orders table

- **Owner:** `EventSalesWeb.Live.Admin.Components.OrderTable`
- **Data:** `snapshot.recent_orders`, newest `updated_at_source` first

### 9. Freshness / stale data banner

- **Owner:** `EventSalesWeb.Live.Admin.Components.StaleDataBanner`
- **Data:** `snapshot.hot_state` — banner when `hot_state[:state]` in `[:warming, :stale]`

### 10. Manual refresh behavior

- **Owner:** `DashboardLive` — `handle_event("manual_refresh", ...)`
- **Behavior:** Rate-limited via `ManualActionRateLimiter`; calls `HotStateAggregator.request_rebuild/1` only
- **Must not:** Call WooCommerce/Tickera or synchronously scan raw orders

### 11. UX states (loading, empty, ready, stale, partial, error)

| Section | loading | empty | ready | stale | partial | error |
|---------|---------|-------|-------|-------|---------|-------|
| KPI cards | First mount before snapshot | Zeros (not nil/blank) | Values from `kpis` | Same values; banner may show | Some events with data, KPIs still sum displayed rows | `empty_dashboard/0` zeros + error flash |
| Sales trend | Mount | Empty chart panel / message; `labels/revenue/tickets == []` | Chart.js with data | Chart unchanged; banner | N/A until `daily_buckets` exists | Empty chart + error flash |
| Status badges | Mount | "No statuses yet" copy | Badges per `statuses` | Banner | Some statuses, others empty | Empty statuses + flash |
| Unmapped alerts | Mount | Empty list message | Alert rows | Banner | — | Empty + flash |
| By-event table | Mount | Single friendly empty row | Data rows | Banner | Events listed, zeros OK | Empty table + flash |
| By-ticket-type | Mount | Empty row message | Data rows | Banner | — | Empty + flash |
| Recent orders | Mount | `OrderTable` empty row | Order rows | Banner | — | Empty + flash |
| Stale banner | Hidden | Hidden | Hidden | Visible for `:warming`/`:stale` | — | Hidden (error flash instead) |

**Must not:**

- Show `nil` for KPI numeric fields in empty state
- Patch Chart.js canvas with LiveView DOM updates (use `phx-update="ignore"` on chart wrapper)
- Show raw exceptions or stack traces to admins

### 12. Accessibility and responsive rules (23.2)

- Use semantic headings (`h1` page title, `h2` section titles)
- Tables: horizontal scroll on small viewports (`overflow-x-auto`)
- Chart: maintain minimum height; do not rely on color alone for status meaning
- Refresh control: keyboard-accessible button with clear label
- Prefer DaisyUI contrast-friendly surfaces for alerts and banners

### 13. Security and PII rules

**Allowed on dashboard overview:** `order_number`, `status`, `currency`, `raw_total`, `completed_at`, `updated_at_source`, product mapping identifiers, item `name` for unmapped queue.

**Never show:** customer email/name, phone, billing/shipping, payment gateway transaction IDs, API keys, secrets, raw webhook payloads or headers.

### 14. Performance rules

| Section | Layer | Bound |
|---------|-------|-------|
| KPI totals | Hot cache + event rows | Sum of displayed events (max 50 events) |
| Sales trend | Future `daily_buckets` / snapshots | Max ~30 days; bounded snapshot rows (future slice) |
| Event table | Hot/snapshot per event | Default limit **50** events |
| Ticket types | Bounded `OrderItem` read in facade | Default **1000** rows scanned, aggregated in memory |
| Recent orders | Bounded `Order` read | Default **10** |
| Unmapped alerts | `OrderItemMapper` queue | Default **10** |
| Hot state | `HotStateAggregator.status/0` | O(1) GenServer read |

**Rules:**

- No unbounded order/order-item scans from LiveView or components
- No polling loops; use existing PubSub + `handle_info` for hot updates
- Manual refresh triggers async rebuild; does not block on full re-aggregation in the HTTP request

### 15. Slice 23.2 implementation boundaries

23.2 **may:** Restyle sections, adopt DaisyUI/Mishka primitives, improve empty/loading/stale UX, add chart variants that consume **documented** snapshot fields.

23.2 **must not:**

- Change `AdminDashboard.snapshot/0` keys or semantics without updating 23.1 docs and contract tests
- Add WooCommerce/Tickera/HTTP calls in web layer
- Query raw orders from components
- Add client routes or migrations
- Import Chart.js into `assets/js/app.js` (global CDN only)
- Add `assets/tailwind.config.js` or npm DaisyUI

See [`admin_dashboard_frontend_handoff.md`](admin_dashboard_frontend_handoff.md) and [`admin_dashboard_chart_contracts.md`](admin_dashboard_chart_contracts.md).

---

## Related code

| Module | Path |
|--------|------|
| Facade | `lib/event_sales/analytics/admin_dashboard.ex` |
| LiveView | `lib/event_sales_web/live/admin/dashboard_live.ex` |
| Contract tests | `test/event_sales/analytics/admin_dashboard_contract_test.exs` |
