# Slice 23.2 — Admin Dashboard Frontend Build

## Purpose

Implement the admin analytics dashboard frontend from the Slice 23.1 contracts using the current EventSales UI stack:

```text
Phoenix LiveView
Tailwind v4.3.0
Vendored DaisyUI v5.5.20
Mishka Chelekom CSS variables and LiveView hooks
Chart.js 4.4.4 loaded globally from root.html.heex
esbuild-managed assets/js/app.js
```

This slice is for the frontend-focused agent. It should make the admin dashboard visually useful, responsive, and reliable without changing backend business rules.

## Quick Verdict

Build the frontend after Slice 23.0 and Slice 23.1 are complete.

Do not let the frontend agent invent backend logic. It must consume existing dashboard contracts/read facades and render them well.

## Preconditions

Before Slice 23.2 starts:

1. Slice 22.0 is merged.
2. Slice 23.0 E2E webhook-to-dashboard acceptance is green.
3. Slice 23.1 dashboard data/UX/chart contracts are merged.
4. `main` is clean and up to date.
5. The frontend agent has read:

```text
AGENTS.md
docs/dashboard/admin_dashboard_v1_spec.md
docs/dashboard/admin_dashboard_chart_contracts.md
docs/dashboard/admin_dashboard_frontend_handoff.md
assets/css/app.css
assets/js/app.js
assets/css/safelist.txt
lib/event_sales_web/components/layouts/root.html.heex
lib/event_sales_web/live/admin/dashboard_live.ex
lib/event_sales_web/live/admin/components/sales_chart.ex
test/event_sales/assets_pipeline_config_test.exs
```

## Current Repo Baseline

The current dashboard already renders:

- KPI cards.
- Sales trend chart component.
- Status badges.
- Unmapped alerts.
- Event table.
- Ticket type table.
- Recent orders table.
- Stale data banner.
- Manual refresh button.

Slice 23.2 may refactor and improve these surfaces, but it must not remove the data safety guarantees or route protections.

## Non-Negotiable Frontend Stack Rules

### Tailwind v4.3.0

Use Tailwind v4 patterns already configured in `assets/css/app.css` and `config/config.exs`.

Do not add:

```text
assets/tailwind.config.js
Tailwind v3 config syntax
npm Tailwind setup
second CSS pipeline
```

Dynamic Tailwind classes must be avoided. If unavoidable, add literal class names to:

```text
assets/css/safelist.txt
```

### DaisyUI

Use vendored DaisyUI primitives for generic UI:

```text
btn
card
alert
badge
table
tabs
modal
dropdown
stat
skeleton
loading
```

Do not install DaisyUI through npm. Do not add another DaisyUI plugin source.

### Mishka Chelekom

Use Mishka when the component benefits from Mishka design tokens, CSS variables, or LiveView hooks.

Do not remove or reorder the Mishka CSS import before Tailwind in `assets/css/app.css`.

When adding LiveView hooks, merge with Mishka hooks:

```js
hooks: { ...MishkaComponents, ...NewHooks }
```

Never replace the existing hook map with only the new hooks.

### Chart.js

Chart.js is loaded globally from:

```text
lib/event_sales_web/components/layouts/root.html.heex
```

Do not import Chart.js again in `assets/js/app.js`.

Use the existing `SalesChart` pattern unless Slice 23.1 explicitly approves a small refactor:

- stable unique canvas id
- server data through `data-*` attributes as JSON
- `phx-update="ignore"` on canvas or wrapper
- wait for global `window.Chart`
- destroy existing chart instance before recreating
- do not let LiveView patch an active Chart.js canvas
- no large table scans for chart data

## Goals

Build a polished admin dashboard with:

1. Clear information hierarchy.
2. Responsive KPI cards.
3. Sales trend chart.
4. Ticket type breakdown visualization.
5. Status/operational health panels.
6. Event performance table.
7. Recent orders table with no PII.
8. Unmapped alerts panel.
9. Loading, empty, stale, partial, and error states.
10. Accessible markup and keyboard-safe controls.
11. Asset pipeline compliance.

## Non-Goals

Do not build the public/client/event-owner dashboard.
Do not add client dashboard routes.
Do not expose PII.
Do not add WooCommerce/Tickera calls.
Do not query raw orders from LiveView/components.
Do not create new backend business logic.
Do not add exports.
Do not add a new chart library.
Do not redesign auth.
Do not add operational write controls to Oban Web.

## Frontend Implementation Scope

Allowed files:

```text
lib/event_sales_web/live/admin/dashboard_live.ex
lib/event_sales_web/live/admin/components/*.ex
assets/js/app.js only if a LiveView hook is truly needed
assets/css/safelist.txt only for unavoidable dynamic classes
test/event_sales_web/live/admin/dashboard_live_test.exs
test/event_sales_web/live/admin/*dashboard*_test.exs
test/event_sales/assets_pipeline_config_test.exs only if asset contract legitimately changes
```

Avoid touching backend modules unless Slice 23.1 contract tests show a small presentation adapter is missing.

If backend data shape changes are needed, stop and request a separate backend contract PR.

## Recommended Component Structure

Use or refactor existing admin components into clear units:

```text
lib/event_sales_web/live/admin/components/stat_card.ex
lib/event_sales_web/live/admin/components/sales_chart.ex
lib/event_sales_web/live/admin/components/status_badge.ex
lib/event_sales_web/live/admin/components/order_table.ex
lib/event_sales_web/live/admin/components/unmapped_item_alert.ex
lib/event_sales_web/live/admin/components/stale_data_banner.ex
```

Optional new components if they keep the dashboard cleaner:

```text
lib/event_sales_web/live/admin/components/dashboard_section.ex
lib/event_sales_web/live/admin/components/kpi_grid.ex
lib/event_sales_web/live/admin/components/empty_state.ex
lib/event_sales_web/live/admin/components/operational_health_panel.ex
lib/event_sales_web/live/admin/components/ticket_type_chart.ex
lib/event_sales_web/live/admin/components/status_breakdown_chart.ex
```

Keep each component focused. Do not create a giant all-purpose dashboard component.

## Layout Specification

Recommended responsive layout:

```text
Mobile
- Single column
- KPI cards stacked
- Charts full width
- Tables horizontally scrollable
- Operational panels stacked

Tablet
- KPI cards in 2 columns
- Main chart full width
- Secondary panels in 2 columns

Desktop
- Header/control row
- KPI strip in 4 or 6 columns depending final contract
- Primary chart wide
- Health/status side panel
- Event and ticket tables below
```

Use literal Tailwind classes. Prefer DaisyUI card/stat/table primitives where they improve consistency.

## Visual Hierarchy

Dashboard order:

1. Header and refresh control.
2. Stale/error/degraded alert banner.
3. KPI strip.
4. Primary sales trend chart.
5. Operational health/status panel.
6. Event performance table.
7. Ticket type breakdown.
8. Unmapped alerts.
9. Recent orders.

Rationale: show business value first, then operational warnings, then detail drill-downs.

## Chart Implementation Rules

### Sales Trend

Use Chart.js line chart.

Required behavior:

- Revenue and tickets displayed as separate datasets.
- Empty chart data shows an empty-state component, not a broken canvas.
- Chart renders after LiveView mount and after LiveView patches without duplicate chart instances.
- Chart values come from Slice 23.1 contract only.

### Ticket Type Breakdown

Use either:

- horizontal bar chart, or
- table-first UI with optional bar visualization.

Do not force charting if the data is better as a table.

### Status Breakdown

Use either:

- badges and counts, or
- doughnut chart if the contract is stable.

Do not visually imply pending/refunded/failed orders are sold tickets.

## UX State Rendering

Every major panel must handle:

### Loading

Use DaisyUI `skeleton` or `loading` primitives.

### Empty

Use friendly copy:

```text
No completed ticket sales yet.
No unmapped items.
No recent orders yet.
No chart data yet.
```

### Stale

Show `StaleDataBanner` prominently. Include last refreshed time if available.

### Error

Show bounded user-safe error message:

```text
Dashboard data could not be loaded.
```

No raw exceptions.

### Partial

Render available sections and show empty/partial state only where missing.

## PII Rules

The dashboard overview must not show:

```text
customer_name
customer_email
payment_gateway_transaction_id
raw webhook payload
raw headers
billing address
phone number
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

Tests must assert the dashboard does not render known fixture PII.

## Accessibility Rules

- Use semantic headings in order.
- Buttons must have visible labels.
- Chart panels must include textual summary or accessible fallback.
- Tables must have table headers.
- Alerts must be readable without relying only on color.
- Do not use tiny text as the only way to see critical status.
- Maintain keyboard accessibility for refresh and interactive controls.

## LiveView Rules

- Manual refresh remains rate-limited.
- Manual refresh requests rebuild; it does not call external APIs.
- Use PubSub updates already available for hot state/event rows.
- Avoid JS push events unless browser-owned behavior needs them.
- Do not put business logic in LiveView.
- Keep assigns explicit and named.
- Do not store large datasets in assigns.

## Performance and Scaling Review

Frontend must not cause:

- unbounded data loading
- repeated full dashboard reloads on every small update
- chart recreation loops
- large JSON blobs in `data-*` attributes
- polling in custom JavaScript
- raw order scans from UI

Chart data must be bounded:

```text
max buckets: 30 to 90 depending contract
max ticket type rows: capped
max event rows: capped
recent orders: capped
unmapped alerts: capped
```

Use hot/warm read models and bounded admin facades.

## Testing Plan

Add or update tests for:

- Dashboard route renders for admin.
- Dashboard denies unauthenticated/non-admin users through existing auth tests if relevant.
- KPI cards render expected values from fixture data.
- Empty dashboard renders empty states.
- Stale banner renders when hot state is stale.
- Chart component renders data attributes with valid JSON.
- Chart component uses stable canvas id.
- Chart canvas/wrapper uses `phx-update="ignore"`.
- Dashboard does not render PII fixture values.
- Dashboard does not reference WooCommerce/Tickera clients.
- Asset pipeline config test passes.
- `mix assets.build` succeeds.

Avoid brittle tests that assert exact CSS class ordering or Chart.js internal DOM output.

## Frontend Agent Prompt

```text
Implement Slice 23.2 — Admin Dashboard Frontend Build.

Use the Slice 23.1 dashboard data, UX, and chart contracts exactly.

Use the current EventSales frontend stack:
- Phoenix LiveView
- Tailwind v4.3.0
- vendored DaisyUI v5.5.20
- Mishka Chelekom CSS variables and LiveView hooks
- Chart.js 4.4.4 loaded globally in root.html.heex
- esbuild assets/js/app.js

Do not add a new chart library.
Do not import Chart.js into app.js.
Do not add assets/tailwind.config.js.
Do not reintroduce Tailwind v3 config patterns.
Do not install DaisyUI through npm.
Do not replace Mishka LiveView hooks.
Do not call WooCommerce or Tickera from LiveView/components.
Do not expose customer PII.
Do not query raw orders directly from UI.
Do not add backend business logic.

Build a responsive, accessible admin analytics dashboard using existing read facades and contracts.
```

## TOON Prompt — Slice 23.2

| Field | Content |
|---|---|
| Task | Implement Slice 23.2 — Admin Dashboard Frontend Build. |
| Objective | Turn the existing admin dashboard into a polished, responsive, chart-rich analytics surface using the Slice 23.1 contracts and the approved EventSales frontend stack. |
| Output | Updated `DashboardLive`, admin dashboard components, chart components if needed, focused LiveView/component tests, and asset pipeline verification. |
| Note | Use Tailwind v4.3.0, vendored DaisyUI, Mishka Chelekom, and globally loaded Chart.js. Do not add backend business logic, PII, WooCommerce/Tickera calls, new chart libraries, Tailwind v3 config, npm DaisyUI, or client dashboard routes. Chart data must come from bounded dashboard contracts/read facades only. |

## Verification Commands

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix assets.build
mix test test/event_sales/assets_pipeline_config_test.exs
mix test test/event_sales_web/live/admin/dashboard_live_test.exs
mix test test/event_sales_web/live/admin/component_namespace_test.exs
bash scripts/check_no_web_woocommerce_refs.sh
bash scripts/local_ci.sh
```

If the PR changes production assets, also run:

```bash
MIX_ENV=prod mix assets.deploy
```

## Completion Criteria

Slice 23.2 is complete when:

- Admin dashboard is visually coherent and responsive.
- KPI cards, charts, tables, status/health panels, unmapped alerts, and recent orders render from stable contracts.
- Empty/stale/error/partial states render clearly.
- Chart.js works without duplicate instances or LiveView canvas patch bugs.
- No PII leaks into the dashboard overview.
- No WooCommerce/Tickera calls are introduced in web code.
- Asset pipeline tests and local CI pass.
