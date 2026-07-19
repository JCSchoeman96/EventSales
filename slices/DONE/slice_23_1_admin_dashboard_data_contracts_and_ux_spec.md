# Slice 23.1 — Admin Dashboard Data Contracts and UX Specification

## Purpose

Define the admin dashboard data contracts, UX states, chart contracts, component boundaries, and frontend handoff rules before a frontend-focused agent rebuilds or polishes the dashboard.

This slice exists because Slice 23.0 should prove the MVP core flow end-to-end, while Slice 23.2 should implement the dashboard UI from stable contracts. Slice 23.1 is the bridge between correctness and frontend execution.

```text
Slice 23.0 — Full Webhook-to-Dashboard Acceptance
Slice 23.1 — Admin Dashboard Data Contracts and UX Specification
Slice 23.2 — Admin Dashboard Frontend Build
```

## Quick Verdict

Implement Slice 23.1 as a planning/contract slice, not a heavy UI implementation slice.

Expected output:

```text
docs/dashboard/admin_dashboard_v1_spec.md
docs/dashboard/admin_dashboard_chart_contracts.md
optional: test/event_sales/analytics/admin_dashboard_contract_test.exs
optional: test/event_sales_web/live/admin/dashboard_contract_render_test.exs
```

Do not redesign the dashboard in this slice. Do not build new chart-heavy UI. Do not let this slice become a frontend implementation PR.

## Current Repository Baseline

As of current `main`, EventSales already has:

- Phoenix 1.8 LiveView admin dashboard route and `DashboardLive`.
- Tailwind v4.3.0 configured through the Mix Tailwind wrapper.
- esbuild configured for `assets/js/app.js`.
- Mishka Chelekom installed as a dev generator dependency and Mishka CSS/hooks vendored into the asset pipeline.
- Vendored DaisyUI standalone plugin.
- Chart.js loaded globally from the root layout CDN script.
- Existing admin dashboard components under `lib/event_sales_web/live/admin/components/`.
- Existing `SalesChart` component using Chart.js, data attributes, stable canvas ids, and `phx-update="ignore"`.
- Existing `EventSales.Analytics.AdminDashboard` read facade.
- Existing `EventSales.Analytics.EventScopedDashboard` from Slice 20 for future event-scoped dashboard infrastructure.
- Slice 22 maintenance jobs merged.

The implementation agent must inspect these files first:

```text
AGENTS.md
assets/css/app.css
assets/js/app.js
assets/css/safelist.txt
assets/vendor/daisyui.mjs
assets/vendor/mishka_chelekom.css
assets/vendor/mishka_components.js
lib/event_sales_web/components/layouts/root.html.heex
lib/event_sales_web/live/admin/dashboard_live.ex
lib/event_sales_web/live/admin/components/sales_chart.ex
lib/event_sales_web/live/admin/components/stat_card.ex
lib/event_sales_web/live/admin/components/status_badge.ex
lib/event_sales_web/live/admin/components/order_table.ex
lib/event_sales_web/live/admin/components/unmapped_item_alert.ex
lib/event_sales_web/live/admin/components/stale_data_banner.ex
lib/event_sales/analytics/admin_dashboard.ex
lib/event_sales/analytics/event_scoped_dashboard.ex
lib/event_sales/analytics/hot_state_aggregator.ex
lib/event_sales/analytics/snapshot_reader.ex
test/event_sales/assets_pipeline_config_test.exs
test/event_sales_web/live/admin/dashboard_live_test.exs
```

## Explicit UI/Asset Stack Rules

The dashboard specs must explicitly instruct Slice 23.2 to use the current repo stack:

```text
Phoenix LiveView
Tailwind v4.3.0
Vendored DaisyUI v5.5.20 primitives
Mishka Chelekom CSS variables and LiveView hooks
Chart.js 4.4.4 loaded globally from root.html.heex
esbuild-managed assets/js/app.js
```

Do not add `assets/tailwind.config.js`.
Do not reintroduce Tailwind v3 patterns.
Do not install DaisyUI through npm.
Do not add another Chart.js import into `assets/js/app.js` while Chart.js is loaded globally in the root layout.
Do not replace Mishka hooks; any new hook map must merge with Mishka hooks.

Preferred UI priority:

```text
1. Existing EventSales admin component
2. DaisyUI primitive
3. Mishka Chelekom component/hook
4. Small local Phoenix function component
5. Custom JavaScript only for browser-owned behavior
```

## Goals

Slice 23.1 must define:

1. The exact admin dashboard sections.
2. The exact metric names and display semantics.
3. The exact chart contracts.
4. The bounded data shapes returned to the LiveView.
5. Loading, empty, stale, partial, error, and degraded states.
6. PII exclusion rules.
7. Performance and scaling rules for each dashboard section.
8. Component ownership and boundaries.
9. The frontend handoff checklist for Slice 23.2.

## Non-Goals

Do not implement the final dashboard UI in this slice.

Do not build a client/event-owner dashboard.
Do not add public routes.
Do not add exports.
Do not add external APIs.
Do not add WooCommerce or Tickera calls.
Do not query raw orders directly from UI components.
Do not expose customer email, customer name, payment transaction IDs, or raw payload data.
Do not add a new charting library.
Do not redesign the full asset pipeline.

## Dashboard Information Architecture

The dashboard should be specified as the following admin-only surface:

```text
Admin Dashboard
├── Header / control bar
│   ├── page title
│   ├── last refreshed status
│   ├── manual refresh button
│   └── operational state indicator
├── KPI summary strip
│   ├── tickets sold
│   ├── revenue
│   ├── today tickets
│   ├── today revenue
│   ├── unmapped items
│   └── failed webhook / failed job warning count if available
├── Sales trend chart
│   ├── completed-ticket revenue over time
│   └── completed-ticket count over time
├── Event performance table
│   ├── event name
│   ├── tickets sold
│   ├── revenue
│   ├── today tickets
│   ├── status
│   └── stale indicator
├── Ticket type breakdown
│   ├── event name
│   ├── ticket type name
│   ├── tickets sold
│   └── revenue
├── Operational health panels
│   ├── hot-state freshness
│   ├── webhook processing status
│   ├── reconciliation status
│   ├── maintenance status
│   └── Oban visibility link, if appropriate
├── Unmapped alerts
│   ├── product/variation identifiers
│   ├── item name
│   ├── quantity
│   └── mapping status
└── Recent orders
    ├── order number
    ├── status
    ├── total
    ├── completed timestamp
    └── updated source timestamp
```

## Data Source Rules

Use read-model/facade data only:

```text
EventSales.Analytics.AdminDashboard
EventSales.Analytics.HotStateAggregator
EventSales.Analytics.SnapshotReader
EventSales.Analytics.EventScopedDashboard only for future event-scoped contracts, not admin UI replacement
```

Dashboard UI must not call:

```text
WooCommerceClient
Tickera clients
HTTP clients
Repo directly from LiveView/components
raw SQL from LiveView/components
WebhookEvent.payload
Sales.Order.customer_email
Sales.Order.customer_name
Sales.Order.payment_gateway_transaction_id
```

## Proposed Admin Dashboard Contract

The target dashboard contract should remain a map or struct that is easy for LiveView to render.

Recommended shape:

```elixir
%{
  kpis: %{
    total_sold: non_neg_integer(),
    total_revenue: Decimal.t(),
    today_sold: non_neg_integer(),
    today_revenue: Decimal.t(),
    unmapped_count: non_neg_integer(),
    failed_webhook_count: non_neg_integer(),
    failed_job_alert_count: non_neg_integer()
  },
  chart_data: %{
    sales_trend: %{
      labels: [String.t()],
      revenue: [number()],
      tickets: [non_neg_integer()],
      currency: String.t(),
      granularity: :day | :hour,
      empty?: boolean()
    },
    status_breakdown: %{
      labels: [String.t()],
      counts: [non_neg_integer()]
    },
    ticket_type_breakdown: %{
      labels: [String.t()],
      tickets: [non_neg_integer()],
      revenue: [number()]
    }
  },
  events: [
    %{
      event_id: Ecto.UUID.t(),
      event_name: String.t(),
      total_sold: non_neg_integer(),
      total_revenue: Decimal.t(),
      today_sold: non_neg_integer(),
      today_revenue: Decimal.t(),
      currency: String.t(),
      refreshed_at: DateTime.t() | nil,
      stale?: boolean()
    }
  ],
  ticket_types: [
    %{
      event_id: Ecto.UUID.t(),
      event_name: String.t(),
      ticket_type_id: Ecto.UUID.t() | nil,
      ticket_type_name: String.t(),
      total_sold: non_neg_integer(),
      total_revenue: Decimal.t()
    }
  ],
  statuses: %{optional(String.t()) => non_neg_integer()},
  recent_orders: [
    %{
      order_number: String.t(),
      status: atom() | String.t(),
      currency: String.t(),
      raw_total: Decimal.t(),
      completed_at: DateTime.t() | nil,
      updated_at_source: DateTime.t() | nil
    }
  ],
  unmapped_alerts: [
    %{
      order_number: String.t() | nil,
      name: String.t(),
      woo_product_id: integer() | nil,
      woo_variation_id: integer() | nil,
      mapping_status: atom(),
      quantity: integer(),
      updated_at: DateTime.t()
    }
  ],
  health: %{
    hot_state: map(),
    stale?: boolean(),
    partial?: boolean(),
    load_error: atom() | nil,
    last_refreshed_at: DateTime.t() | nil,
    maintenance: %{
      raw_payload_purge_visible?: boolean(),
      failed_job_alert_visible?: boolean()
    }
  }
}
```

The final exact contract may be introduced as a documented map, a typed module, or a test fixture. Do not over-engineer a full DTO layer unless it reduces ambiguity for the frontend agent.

## Chart Contracts

### Sales Trend Chart

Purpose: show completed-ticket sales trend over time.

Contract:

```elixir
%{
  id: "sales-trend",
  type: :line,
  labels: ["2026-05-20", "2026-05-21"],
  datasets: [
    %{key: :revenue, label: "Revenue", values: [1200.00, 1600.00], unit: "ZAR"},
    %{key: :tickets, label: "Tickets", values: [4, 7], unit: "count"}
  ],
  empty?: false
}
```

Rules:

- Revenue values passed to Chart.js must be numbers, not Decimal structs.
- Display formatting may use `Intl.NumberFormat` client-side or server-side labels, but the raw chart values must remain numeric.
- Missing buckets should render as zero only when the bucket exists and has no sales. Missing data should be represented as empty/partial state, not fake sales.

### Ticket Type Breakdown Chart

Purpose: show ticket sales and revenue by ticket type.

Contract:

```elixir
%{
  id: "ticket-type-breakdown",
  type: :bar,
  labels: ["General Admission", "VIP"],
  tickets: [120, 40],
  revenue: [54000.00, 36000.00],
  currency: "ZAR",
  empty?: false
}
```

### Status Breakdown Chart

Purpose: show operational order status distribution.

Contract:

```elixir
%{
  id: "status-breakdown",
  type: :doughnut,
  labels: ["completed", "pending", "failed"],
  counts: [120, 8, 2],
  empty?: false
}
```

Status chart must not imply non-completed statuses count as sold tickets.

## UX State Contract

Every dashboard section must specify these states:

```text
loading — first render while data is being fetched
empty — no data exists yet
partial — some data exists but a section has no rows
stale — hot state is older than acceptable freshness threshold
error — facade returned an error
degraded — source data is available but a subsystem is unhealthy
ready — normal render
```

Recommended render rules:

- KPI cards: show zero for true empty state, not for error state.
- Charts: show empty-state panel when labels/datasets are empty.
- Tables: show one friendly empty row instead of disappearing.
- Stale banner: visible when hot-state freshness says stale.
- Error state: show bounded error message, no raw exception details.
- Manual refresh: rate-limited and never calls WooCommerce/Tickera directly.

## PII and Security Contract

The admin dashboard may show operational order numbers and status, but must not show customer PII by default in the dashboard overview.

Never expose:

```text
customer_name
customer_email
payment_gateway_transaction_id
raw webhook payload
raw headers beyond already sanitized headers
API keys
secrets
```

Recent orders may show:

```text
order_number
status
currency
raw_total
completed_at
updated_at_source
```

Recent orders must not show:

```text
customer_email
customer_name
payment_gateway_transaction_id
billing address
phone number
raw payload
```

## Performance and Scaling Review

For each dashboard section, the spec must state the data layer:

| Section | Data Layer | Rule |
|---|---|---|
| KPI totals | HotStateAggregator / SnapshotReader | No raw table scan from LiveView |
| Sales trend | SnapshotReader/materialized daily buckets | Bounded buckets only |
| Event table | Hot/warm event summaries | Event limit capped |
| Ticket type breakdown | Existing bounded facade or future snapshot | Cap rows and avoid peak scans |
| Recent orders | Bounded read facade | Limit rows; no PII |
| Unmapped alerts | Existing mapper facade | Limit rows |
| Operational health | Telemetry/read-model status | No external calls |

Performance rules:

- Do not load unbounded order/order-item rows.
- Do not compute charts from raw tables in LiveView.
- Use bounded limits and explicit row caps.
- Prefer hot state and snapshots.
- No polling loops; use PubSub/LiveView pushes where already available.
- Manual refresh requests a rebuild; it does not synchronously rebuild large state.

## Proposed Files for Slice 23.1

Create:

```text
docs/dashboard/admin_dashboard_v1_spec.md
docs/dashboard/admin_dashboard_chart_contracts.md
docs/dashboard/admin_dashboard_frontend_handoff.md
```

Optional if useful:

```text
test/event_sales/analytics/admin_dashboard_contract_test.exs
test/event_sales_web/live/admin/dashboard_contract_render_test.exs
```

Do not create new CSS/JS-heavy files in this slice.

## Tests for Slice 23.1

Add only contract/spec tests if needed:

- AdminDashboard snapshot contains all required top-level keys.
- Dashboard chart data contract can be built from bounded data.
- No chart contract contains PII keys.
- Recent orders contract excludes customer fields.
- Empty dashboard contract renders without crashing.
- Stale dashboard state is representable.
- Asset pipeline config test remains green.

## TOON Prompt — Slice 23.1

| Field | Content |
|---|---|
| Task | Implement Slice 23.1 — Admin Dashboard Data Contracts and UX Specification. |
| Objective | Produce the stable dashboard data, chart, UX, security, and frontend handoff contracts needed before a frontend-focused agent implements the admin dashboard UI. |
| Output | `docs/dashboard/admin_dashboard_v1_spec.md`, `docs/dashboard/admin_dashboard_chart_contracts.md`, `docs/dashboard/admin_dashboard_frontend_handoff.md`, and any minimal contract tests required to keep the spec aligned with current code. |
| Note | Use current EventSales stack: Phoenix LiveView, Tailwind v4.3.0, vendored DaisyUI, Mishka Chelekom, and Chart.js loaded globally. Do not build the final dashboard UI. Do not add WooCommerce/Tickera calls. Do not expose PII. Use bounded aggregate/read-model contracts only. Add no heavy CSS/JS implementation in this slice. |

## Verification Commands

```bash
mix test test/event_sales/analytics/admin_dashboard_contract_test.exs
mix test test/event_sales_web/live/admin/dashboard_live_test.exs
mix test test/event_sales/assets_pipeline_config_test.exs
mix format --check-formatted
mix compile --warnings-as-errors
bash scripts/check_no_web_woocommerce_refs.sh
bash scripts/local_ci.sh
```

If no optional tests are added, replace missing test paths with the existing dashboard and asset tests.

## Completion Criteria

Slice 23.1 is complete when:

- Dashboard information architecture is documented.
- Chart contracts are documented.
- UX states are documented.
- PII rules are documented.
- Current UI stack is explicitly documented for Slice 23.2.
- Frontend handoff is clear enough that a frontend agent does not need to invent backend contracts.
- No final UI redesign is attempted.
- Required checks pass.
