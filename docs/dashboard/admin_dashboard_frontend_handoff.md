# Admin Dashboard Frontend Handoff (Slice 23.2)

**Prerequisite:** Slice 23.1 merged — read these contracts before changing dashboard UI.

```text
docs/dashboard/admin_dashboard_v1_spec.md
docs/dashboard/admin_dashboard_chart_contracts.md
docs/dashboard/admin_dashboard_frontend_handoff.md   (this file)
```

---

## UI stack (do not change in 23.2 without explicit approval)

| Layer | Version / source |
|-------|------------------|
| Phoenix | 1.8 LiveView |
| Tailwind | v4.3.0 via Mix `tailwind` wrapper (`assets/css/app.css`) |
| DaisyUI | v5.5.20 vendored — `assets/vendor/daisyui.mjs` |
| Mishka Chelekom | CSS variables + hooks — `assets/vendor/mishka_chelekom.css`, `mishka_components.js` |
| Chart.js | 4.4.4 — global CDN in `lib/event_sales_web/components/layouts/root.html.heex` |
| JS bundle | esbuild — `assets/js/app.js` |

---

## Implementation rules

### UI priority

1. Existing EventSales admin component (`StatCard`, `SalesChart`, `OrderTable`, etc.)
2. DaisyUI primitive (`btn`, `card`, `alert`, `badge`, `table`, `tabs`, `modal`, `dropdown`, `stat`, `skeleton`, `loading`)
3. Mishka Chelekom component/hook when design tokens or hooks are needed
4. Small local Phoenix function component
5. Custom JavaScript only for browser-owned behavior (Chart.js lifecycle)

### Tailwind v4

- Do **not** add `assets/tailwind.config.js`.
- Do **not** reintroduce Tailwind v3 config patterns.
- Do **not** install DaisyUI through npm.
- Do **not** add a second DaisyUI plugin source.
- Dynamic classes: prefer literal classes in HEEx; if generated, add literals to `assets/css/safelist.txt`.

### Mishka

- Do **not** remove or reorder Mishka CSS import **before** Tailwind in `assets/css/app.css`.
- Do **not** overwrite Mishka hooks in `app.js`. Merge new hooks:

```javascript
hooks: { ...MishkaComponents, ...NewHooks }
```

### Chart.js

- Do **not** import Chart.js in `assets/js/app.js` (already global in root layout).
- Use `SalesChart` as the canonical pattern.
- Stable canvas ids; `data-*` JSON attributes; `phx-update="ignore"`; destroy before recreate.
- Sales trend today: empty lists are valid — build empty-state UX, do not fake data.

### Data

- Load dashboard via `AdminDashboard.snapshot/0` only (or existing assigns pipeline in `DashboardLive`).
- Use cached aggregates / read models — **no** raw order scans in components.
- Respect bounded lists (events 50, recent orders 10, unmapped 10).

---

## Component boundaries

| Component | Module | Responsibility |
|-----------|--------|----------------|
| Page shell | `EventSalesWeb.Live.Admin.DashboardLive` | Mount, load, refresh, PubSub, chart assigns, inline tables |
| KPI cards | `EventSalesWeb.Live.Admin.Components.StatCard` | Display four KPI values |
| Sales trend | `EventSalesWeb.Live.Admin.Components.SalesChart` | Chart.js line chart |
| Status breakdown | `EventSalesWeb.Live.Admin.Components.StatusBadge` | Per-status counts |
| Unmapped alerts | `EventSalesWeb.Live.Admin.Components.UnmappedItemAlert` | Mapping queue rows |
| Recent orders | `EventSalesWeb.Live.Admin.Components.OrderTable` | PII-safe order table |
| Freshness banner | `EventSalesWeb.Live.Admin.Components.StaleDataBanner` | Read-model lifecycle and source-freshness classification visibility |

Do not move business logic into components. Formatting (`format_money`, dates) is allowed.

## Read-model and source-freshness signals

The dashboard snapshot has separate `read_model` and `source_freshness` fields. `read_model.generated_at` records when HotStateAggregator generated its read model. Source classification uses only the canonical event source-freshness projection.

The all-events policy is `COMBINED_SIGNALS`. `source_freshness.result.classification` is the worst classification among displayed events with evidence. `portfolio_anchor_at` is the newest available event anchor and does not affect that classification. `counts.missing` records events without an anchor. If all displayed events are missing evidence, the result remains `{:error, :missing_source_freshness_anchor}`.

Manual refresh rebuilds dashboard summaries. It does not advance the source-freshness projection. `EventScopedDashboard.source_watermark_at` remains legacy financial snapshot metadata; its `source_freshness` field is canonical M1-07 freshness.

The `DashboardLive` process that requests a manual rebuild receives a direct completion message and reloads the bounded snapshot, including when no event rows are displayed. This does not add a PubSub topic.

DashboardLive subscribes to each displayed event topic. `{:hot_state_updated, event_id, updated_at}` reports a read-model update. `{:source_freshness_updated, event_id}` reports a durable source projection update. Both replace one displayed row and update the displayed aggregates. An update for an event outside the displayed set leaves the dashboard unchanged. Do not add a global topic or polling.

---

## Forbidden work (23.2 agent)

- Backend business logic changes in `AdminDashboard` without contract doc/test updates
- WooCommerce or Tickera HTTP calls from web layer
- Migrations or new Ash resources
- New client/public dashboard routes
- PII fields in templates
- Raw webhook payload display
- Replacing or extending the v1 snapshot contract without updating 23.1 docs and `admin_dashboard_contract_test.exs`
- Inventing data shapes not in the 23.1 docs
- Asset pipeline overhaul (npm Tailwind, second Chart.js, tailwind.config.js)

---

## Required reading before coding

```text
AGENTS.md
assets/css/app.css
assets/js/app.js
assets/css/safelist.txt
lib/event_sales_web/components/layouts/root.html.heex
lib/event_sales_web/live/admin/dashboard_live.ex
lib/event_sales_web/live/admin/components/sales_chart.ex
lib/event_sales/analytics/admin_dashboard.ex
test/event_sales/analytics/admin_dashboard_contract_test.exs
test/event_sales/assets_pipeline_config_test.exs
```

---

## Verification commands (23.2 PR)

```bash
mix test test/event_sales/analytics/admin_dashboard_contract_test.exs
mix test test/event_sales_web/live/admin/dashboard_live_test.exs
mix test test/event_sales_web/full_webhook_to_dashboard_acceptance_test.exs
mix test test/event_sales/assets_pipeline_config_test.exs
bash scripts/check_no_web_woocommerce_refs.sh
mix assets.build   # if CSS/JS touched
bash scripts/local_ci.sh
```

---

## Sales trend empty state (23.2 acceptance)

With Slice 23.1 Option B, `AdminDashboard.snapshot/0` has **no** `:daily_buckets`. `DashboardLive` sets empty chart assigns. 23.2 is done when:

- Empty trend shows clear copy or placeholder (not a JS error / blank broken canvas).
- Refresh and PubSub updates still work.
- No new backend calls from LiveView for chart data.

Future `daily_buckets` backend work is a separate slice; when it lands, follow updated chart contracts.
