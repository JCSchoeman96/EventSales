# EventSales — Full Project Folder Structure

## Purpose

This document defines the recommended folder structure for **EventSales**, a separate Phoenix + Ash 3.x + LiveView application for WooCommerce/Tickera sales analytics.

The structure is designed around these rules:

```text
WordPress / WooCommerce sells tickets.
EventSales receives, normalizes, stores, aggregates, and displays sales data.
LiveView reads EventSales data only.
No dashboard screen should query WordPress directly.
Ash resources/actions own business rules.
Oban workers handle async processing.
Railway is the primary deployment target.
```

---

# 1. Top-Level Project Structure

```text
event_sales/
├── assets/
├── config/
├── docs/
├── lib/
├── priv/
├── scripts/
├── test/
├── .formatter.exs
├── .gitignore
├── mix.exs
├── mix.lock
├── README.md
└── railway.json / railway.toml optional
```

## Responsibility Overview

| Folder | Responsibility |
|---|---|
| `assets/` | Tailwind, JavaScript, icons, and frontend assets. |
| `config/` | Compile-time and runtime configuration. |
| `docs/` | Architecture, deployment, runbooks, and planning documents. |
| `lib/event_sales/` | Core application, Ash domains, resources, workers, clients, analytics, and business rules. |
| `lib/event_sales_web/` | Phoenix web layer: router, controllers, LiveViews, components, plugs, layouts. |
| `priv/` | Repo migrations, static assets, seeds, and app-private files. |
| `scripts/` | Local scaffolding, maintenance, and helper scripts. |
| `test/` | Full automated test suite mirroring application structure. |

---

# 2. Full Recommended Folder Tree

```text
event_sales/
├── assets/
│   ├── css/
│   │   └── app.css
│   ├── js/
│   │   └── app.js
│   ├── vendor/
│   └── tailwind.config.js
│
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── prod.exs
│   ├── runtime.exs
│   └── test.exs
│
├── docs/
│   ├── architecture/
│   │   ├── overview.md
│   │   ├── domain-map.md
│   │   ├── data-flow.md
│   │   ├── caching-strategy.md
│   │   ├── performance-scaling-review.md
│   │   ├── security-model.md
│   │   ├── access-control-model.md
│   │   ├── webhook-ingestion.md
│   │   ├── reconciliation-strategy.md
│   │   ├── csv-import-strategy.md
│   │   └── analytics-model.md
│   │
│   ├── deployment/
│   │   ├── railway.md
│   │   ├── environment-variables.md
│   │   ├── release-checklist.md
│   │   └── optional-vps-notes.md
│   │
│   ├── product/
│   │   ├── prd.md
│   │   ├── kanban.md
│   │   ├── vertical-slice-roadmap.md
│   │   └── future-client-dashboard.md
│   │
│   ├── runbooks/
│   │   ├── production-smoke-test.md
│   │   ├── webhook-troubleshooting.md
│   │   ├── reconciliation.md
│   │   ├── csv-import.md
│   │   ├── event-launch-checklist.md
│   │   ├── incident-response.md
│   │   └── security-review.md
│   │
│   └── decisions/
│       ├── 0001-webhooks-primary-rest-fallback.md
│       ├── 0002-completed-only-sales-metric.md
│       ├── 0003-event-scoped-access-foundation.md
│       ├── 0004-railway-primary-deployment.md
│       └── 0005-csv-import-as-controlled-backfill.md
│
├── lib/
│   ├── event_sales/
│   │   ├── application.ex
│   │   ├── repo.ex
│   │   ├── accounts.ex
│   │   ├── catalog.ex
│   │   ├── sales.ex
│   │   ├── ingestion.ex
│   │   ├── analytics.ex
│   │   ├── audit.ex
│   │   │
│   │   ├── accounts/
│   │   │   ├── policies.ex
│   │   │   ├── pii_policy.ex
│   │   │   ├── resources/
│   │   │   │   ├── user.ex
│   │   │   │   ├── role.ex
│   │   │   │   ├── user_role.ex
│   │   │   │   └── event_access_grant.ex
│   │   │   └── services/
│   │   │       ├── role_assignment.ex
│   │   │       └── event_access.ex
│   │   │
│   │   ├── catalog/
│   │   │   ├── mapping_resolver.ex
│   │   │   ├── product_metadata_updater.ex
│   │   │   ├── resources/
│   │   │   │   ├── source_system.ex
│   │   │   │   ├── event.ex
│   │   │   │   ├── ticket_type.ex
│   │   │   │   ├── product_mapping.ex
│   │   │   │   └── event_dashboard_setting.ex
│   │   │   └── services/
│   │   │       ├── mapping_recalculation_request.ex
│   │   │       └── unmapped_item_detector.ex
│   │   │
│   │   ├── sales/
│   │   │   ├── order_upserter.ex
│   │   │   ├── order_item_mapper.ex
│   │   │   ├── status_rules.ex
│   │   │   ├── revenue_rules.ex
│   │   │   ├── resources/
│   │   │   │   ├── order.ex
│   │   │   │   ├── order_item.ex
│   │   │   │   └── coupon_snapshot.ex
│   │   │   └── services/
│   │   │       ├── mixed_event_splitter.ex
│   │   │       └── customer_sanitizer.ex
│   │   │
│   │   ├── ingestion/
│   │   │   ├── webhook_processor.ex
│   │   │   ├── webhook_replay.ex
│   │   │   ├── reconciliation_scheduler.ex
│   │   │   ├── parsers/
│   │   │   │   ├── woocommerce_order_parser.ex
│   │   │   │   ├── woocommerce_product_parser.ex
│   │   │   │   └── csv_order_parser.ex
│   │   │   ├── handlers/
│   │   │   │   ├── order_created_handler.ex
│   │   │   │   ├── order_updated_handler.ex
│   │   │   │   ├── product_updated_handler.ex
│   │   │   │   └── refund_created_handler.ex
│   │   │   ├── clients/
│   │   │   │   ├── woocommerce_client.ex
│   │   │   │   └── woocommerce_error.ex
│   │   │   ├── csv/
│   │   │   │   ├── parser.ex
│   │   │   │   ├── dry_run_validator.ex
│   │   │   │   └── apply_import.ex
│   │   │   ├── security/
│   │   │   │   └── webhook_signature.ex
│   │   │   ├── workers/
│   │   │   │   ├── process_webhook_worker.ex
│   │   │   │   ├── reconcile_orders_worker.ex
│   │   │   │   ├── backfill_orders_worker.ex
│   │   │   │   ├── process_csv_import_worker.ex
│   │   │   │   ├── purge_raw_payloads_worker.ex
│   │   │   │   └── product_update_worker.ex
│   │   │   └── resources/
│   │   │       ├── webhook_event.ex
│   │   │       ├── webhook_delivery_failure.ex
│   │   │       ├── sync_run.ex
│   │   │       ├── sync_cursor.ex
│   │   │       ├── csv_import_batch.ex
│   │   │       └── csv_import_row.ex
│   │   │
│   │   ├── analytics/
│   │   │   ├── metric_rules.ex
│   │   │   ├── cache_keys.ex
│   │   │   ├── dashboard_cache.ex
│   │   │   ├── aggregators/
│   │   │   │   ├── event_aggregator.ex
│   │   │   │   ├── ticket_type_aggregator.ex
│   │   │   │   ├── daily_sales_aggregator.ex
│   │   │   │   └── order_status_aggregator.ex
│   │   │   ├── resources/
│   │   │   │   ├── event_aggregate.ex
│   │   │   │   ├── ticket_type_aggregate.ex
│   │   │   │   ├── daily_sales_aggregate.ex
│   │   │   │   └── dashboard_cache_state.ex
│   │   │   └── services/
│   │   │       ├── cache_invalidator.ex
│   │   │       └── dashboard_snapshot_builder.ex
│   │   │
│   │   ├── audit/
│   │   │   ├── logger.ex
│   │   │   ├── resources/
│   │   │   │   └── audit_log.ex
│   │   │   └── services/
│   │   │       └── metadata_sanitizer.ex
│   │   │
│   │   ├── exports/
│   │   │   ├── event_sales_csv.ex
│   │   │   ├── order_list_csv.ex
│   │   │   └── export_policy.ex
│   │   │
│   │   └── maintenance/
│   │       ├── cache_cleanup_worker.ex
│   │       └── retention_policy.ex
│   │
│   └── event_sales_web/
│       ├── endpoint.ex
│       ├── gettext.ex
│       ├── router.ex
│       ├── telemetry.ex
│       ├── controllers/
│       │   ├── error_html.ex
│       │   ├── error_json.ex
│       │   ├── page_controller.ex
│       │   ├── webhook_controller.ex
│       │   ├── export_controller.ex
│       │   └── health_controller.ex
│       ├── live/
│       │   ├── admin/
│       │   │   ├── dashboard_live.ex
│       │   │   ├── events_live.ex
│       │   │   ├── event_detail_live.ex
│       │   │   ├── orders_live.ex
│       │   │   ├── mappings_live.ex
│       │   │   ├── webhooks_live.ex
│       │   │   ├── sync_live.ex
│       │   │   ├── imports_live.ex
│       │   │   ├── audit_live.ex
│       │   │   └── users_live.ex
│       │   ├── future_client/
│       │   │   └── README.md
│       │   └── components/
│       │       ├── stat_card.ex
│       │       ├── status_badge.ex
│       │       ├── sales_chart.ex
│       │       ├── order_table.ex
│       │       ├── event_summary_card.ex
│       │       ├── unmapped_item_alert.ex
│       │       ├── sync_status_badge.ex
│       │       ├── webhook_status_badge.ex
│       │       ├── csv_import_table.ex
│       │       └── pii_display.ex
│       ├── components/
│       │   ├── core_components.ex
│       │   ├── layouts.ex
│       │   └── layouts/
│       │       ├── app.html.heex
│       │       └── root.html.heex
│       ├── plugs/
│       │   ├── admin_only.ex
│       │   ├── rate_limit.ex
│       │   ├── require_authenticated_user.ex
│       │   └── event_scope_guard.ex
│       └── presenters/
│           ├── customer_presenter.ex
│           ├── money_presenter.ex
│           └── status_presenter.ex
│
├── priv/
│   ├── gettext/
│   ├── repo/
│   │   ├── migrations/
│   │   └── seeds.exs
│   └── static/
│       ├── assets/
│       ├── favicon.ico
│       └── robots.txt
│
├── scripts/
│   ├── scaffold_structure.sh
│   ├── scaffold_modules.sh
│   ├── scaffold_ash_resources.sh
│   ├── scaffold_tests.sh
│   ├── railway_smoke_test.sh
│   ├── local_reset_db.sh
│   ├── run_quality_checks.sh
│   └── generate_secret_key_base.sh
│
├── test/
│   ├── support/
│   │   ├── conn_case.ex
│   │   ├── data_case.ex
│   │   ├── live_case.ex
│   │   ├── fixtures/
│   │   │   ├── accounts_fixtures.ex
│   │   │   ├── catalog_fixtures.ex
│   │   │   ├── sales_fixtures.ex
│   │   │   ├── ingestion_fixtures.ex
│   │   │   └── analytics_fixtures.ex
│   │   ├── mocks/
│   │   │   └── woocommerce_client_mock.ex
│   │   └── helpers/
│   │       ├── webhook_helper.ex
│   │       ├── csv_helper.ex
│   │       └── money_helper.ex
│   │
│   ├── fixtures/
│   │   ├── woocommerce/
│   │   │   ├── order_completed.json
│   │   │   ├── order_pending.json
│   │   │   ├── order_cancelled.json
│   │   │   ├── order_refunded.json
│   │   │   ├── order_mixed_event.json
│   │   │   ├── product_updated.json
│   │   │   └── refund_created.json
│   │   └── csv/
│   │       ├── valid_event_import.csv
│   │       ├── invalid_missing_columns.csv
│   │       ├── duplicate_rows.csv
│   │       └── mixed_status_orders.csv
│   │
│   ├── event_sales/
│   │   ├── accounts/
│   │   │   ├── role_policy_test.exs
│   │   │   ├── event_access_grant_test.exs
│   │   │   └── pii_policy_test.exs
│   │   ├── catalog/
│   │   │   ├── event_test.exs
│   │   │   ├── ticket_type_test.exs
│   │   │   ├── product_mapping_test.exs
│   │   │   └── mapping_resolver_test.exs
│   │   ├── sales/
│   │   │   ├── order_test.exs
│   │   │   ├── order_item_test.exs
│   │   │   ├── order_status_metrics_test.exs
│   │   │   └── revenue_rules_test.exs
│   │   ├── ingestion/
│   │   │   ├── webhook_signature_test.exs
│   │   │   ├── process_webhook_worker_test.exs
│   │   │   ├── woocommerce_order_parser_test.exs
│   │   │   ├── woocommerce_client_test.exs
│   │   │   ├── reconciliation_cursor_test.exs
│   │   │   ├── csv_import_test.exs
│   │   │   └── webhook_replay_test.exs
│   │   ├── analytics/
│   │   │   ├── metric_rules_test.exs
│   │   │   ├── event_aggregator_test.exs
│   │   │   ├── dashboard_cache_test.exs
│   │   │   └── cache_invalidator_test.exs
│   │   ├── audit/
│   │   │   └── audit_log_test.exs
│   │   ├── exports/
│   │   │   └── event_sales_csv_test.exs
│   │   └── e2e/
│   │       └── webhook_to_dashboard_test.exs
│   │
│   └── event_sales_web/
│       ├── controllers/
│       │   ├── webhook_controller_test.exs
│       │   ├── export_controller_test.exs
│       │   └── health_controller_test.exs
│       ├── live/
│       │   └── admin/
│       │       ├── dashboard_live_test.exs
│       │       ├── event_detail_live_test.exs
│       │       ├── mappings_live_test.exs
│       │       ├── webhooks_live_test.exs
│       │       ├── sync_live_test.exs
│       │       └── imports_live_test.exs
│       └── plugs/
│           ├── admin_only_test.exs
│           ├── rate_limit_test.exs
│           └── event_scope_guard_test.exs
│
├── .formatter.exs
├── .gitignore
├── mix.exs
├── mix.lock
├── README.md
└── railway.toml optional
```

---

# 3. Domain Boundary Rules

## `lib/event_sales/`

This is the core business application.

Allowed here:

```text
Ash domains
Ash resources
business services
Oban workers
WooCommerce REST client boundary
analytics aggregation
cache invalidation
security verification
CSV import logic
audit logging
exports
```

Not allowed here:

```text
HEEx templates
LiveView rendering concerns
controller-specific logic
CSS/JS concerns
UI component formatting
```

---

## `lib/event_sales_web/`

This is the Phoenix web interface.

Allowed here:

```text
controllers
LiveViews
components
plugs
presenters
layouts
route definitions
```

Not allowed here:

```text
business rules
revenue calculations
WooCommerce REST calls
CSV mutation logic
webhook processing logic
aggregate calculation logic
```

Important rule:

```text
LiveView may call Ash actions and read EventSales caches.
LiveView must never call WooCommerce directly.
```

---

# 4. Domain Details

## 4.1 `EventSales.Accounts`

```text
lib/event_sales/accounts.ex
lib/event_sales/accounts/
├── policies.ex
├── pii_policy.ex
├── resources/
│   ├── user.ex
│   ├── role.ex
│   ├── user_role.ex
│   └── event_access_grant.ex
└── services/
    ├── role_assignment.ex
    └── event_access.ex
```

Purpose:

```text
authentication
roles
event-scoped access
future client dashboard permissions
PII visibility rules
```

Roles:

```text
admin
staff
event_owner
event_staff
```

MVP use:

```text
admin only
```

Future use:

```text
event owner dashboards
event staff dashboards
password/token-protected event views
```

---

## 4.2 `EventSales.Catalog`

```text
lib/event_sales/catalog.ex
lib/event_sales/catalog/
├── mapping_resolver.ex
├── product_metadata_updater.ex
├── resources/
│   ├── source_system.ex
│   ├── event.ex
│   ├── ticket_type.ex
│   ├── product_mapping.ex
│   └── event_dashboard_setting.ex
└── services/
    ├── mapping_recalculation_request.ex
    └── unmapped_item_detector.ex
```

Purpose:

```text
source store identity
events
ticket types
WooCommerce product/variation mapping
manual capacity
future event dashboard settings
```

Important rule:

```text
WooCommerce products/variations do not become trusted ticket metrics until mapped.
```

---

## 4.3 `EventSales.Sales`

```text
lib/event_sales/sales.ex
lib/event_sales/sales/
├── order_upserter.ex
├── order_item_mapper.ex
├── status_rules.ex
├── revenue_rules.ex
├── resources/
│   ├── order.ex
│   ├── order_item.ex
│   └── coupon_snapshot.ex
└── services/
    ├── mixed_event_splitter.ex
    └── customer_sanitizer.ex
```

Purpose:

```text
normalized WooCommerce orders
normalized line items
order statuses
completed-only sold rules
completed-only revenue rules
minimal customer fields
mixed-event order handling
```

Important rule:

```text
Reporting must be based on order items, not only order headers.
```

Reason:

```text
One WooCommerce cart may contain tickets for more than one event.
```

---

## 4.4 `EventSales.Ingestion`

```text
lib/event_sales/ingestion.ex
lib/event_sales/ingestion/
├── webhook_processor.ex
├── webhook_replay.ex
├── reconciliation_scheduler.ex
├── parsers/
├── handlers/
├── clients/
├── csv/
├── security/
├── workers/
└── resources/
```

Purpose:

```text
webhook intake
webhook processing
WooCommerce REST fallback
REST reconciliation
CSV import
backfill
raw payload retention
sync run tracking
```

Important rule:

```text
Webhook controller receives only.
Workers process.
```

Correct flow:

```text
validate webhook
store raw event
enqueue Oban job
return fast
process async
```

Wrong flow:

```text
validate webhook
call WooCommerce REST inline
calculate metrics inline
update dashboard inline
return slowly
```

---

## 4.5 `EventSales.Analytics`

```text
lib/event_sales/analytics.ex
lib/event_sales/analytics/
├── metric_rules.ex
├── cache_keys.ex
├── dashboard_cache.ex
├── aggregators/
├── resources/
└── services/
```

Purpose:

```text
completed-only metrics
revenue calculations
status breakdowns
event aggregates
ticket type aggregates
dashboard snapshots
cache invalidation
PubSub update preparation
```

Caching rules:

```text
Hot data:
ETS / GenServer / Cachex
TTL: 10s–5m

Warm data:
Redis
TTL: 30m–24h

Cold data:
Postgres
durable normalized records
```

Important rule:

```text
Dashboard screens should not perform heavy SUM/GROUP BY queries on every mount.
```

---

## 4.6 `EventSales.Audit`

```text
lib/event_sales/audit.ex
lib/event_sales/audit/
├── logger.ex
├── resources/
│   └── audit_log.ex
└── services/
    └── metadata_sanitizer.ex
```

Purpose:

```text
mapping change audit
manual sync audit
webhook replay audit
CSV import audit
future client dashboard access audit
```

Important rule:

```text
Audit metadata must not store secrets or full raw webhook payloads.
```

---

# 5. Web Layer Structure

```text
lib/event_sales_web/
├── endpoint.ex
├── gettext.ex
├── router.ex
├── telemetry.ex
├── controllers/
├── live/
├── components/
├── plugs/
└── presenters/
```

## Controllers

```text
controllers/
├── webhook_controller.ex
├── export_controller.ex
├── health_controller.ex
├── page_controller.ex
├── error_html.ex
└── error_json.ex
```

Controller rules:

```text
webhook_controller:
- validate
- store
- enqueue
- return
- no heavy processing

export_controller:
- stream export data
- enforce policy
- audit export

health_controller:
- Railway health check
```

---

## Admin LiveViews

```text
live/admin/
├── dashboard_live.ex
├── events_live.ex
├── event_detail_live.ex
├── orders_live.ex
├── mappings_live.ex
├── webhooks_live.ex
├── sync_live.ex
├── imports_live.ex
├── audit_live.ex
└── users_live.ex
```

Purpose:

```text
dashboard_live:
main sales dashboard

events_live:
event list

event_detail_live:
event-specific performance

orders_live:
normalized order search/list

mappings_live:
product/variation to event/ticket mapping

webhooks_live:
webhook logs and failed replay

sync_live:
manual scoped reconciliation and sync status

imports_live:
CSV dry-run/apply

audit_live:
admin audit visibility

users_live:
future role/user management
```

Important rule:

```text
Admin LiveViews may queue jobs.
They must not execute heavy work inline.
```

---

## Components

```text
live/components/
├── stat_card.ex
├── status_badge.ex
├── sales_chart.ex
├── order_table.ex
├── event_summary_card.ex
├── unmapped_item_alert.ex
├── sync_status_badge.ex
├── webhook_status_badge.ex
├── csv_import_table.ex
└── pii_display.ex
```

Component rules:

```text
Components display data only.
Components must not call WooCommerce.
Components must not contain business rules.
Use presenters/helpers for formatting.
Use Ash/domain functions for actual decisions.
```

---

## Plugs

```text
plugs/
├── admin_only.ex
├── rate_limit.ex
├── require_authenticated_user.ex
└── event_scope_guard.ex
```

Purpose:

```text
admin_only:
protect admin routes and Oban Web

rate_limit:
protect manual refresh, replay, sync, imports

require_authenticated_user:
protect authenticated areas

event_scope_guard:
defensive web-layer guard for event-scoped routes
```

Important rule:

```text
Plugs are not a replacement for Ash policies.
```

---

# 6. Test Structure

The test tree mirrors the application structure.

```text
test/
├── support/
├── fixtures/
├── event_sales/
└── event_sales_web/
```

## Core test areas

```text
event_sales/accounts/
- role policies
- event access grants
- PII masking

event_sales/catalog/
- events
- ticket types
- product mappings
- mapping resolver

event_sales/sales/
- orders
- order items
- status rules
- revenue rules

event_sales/ingestion/
- webhook signatures
- webhook worker
- WooCommerce parser
- WooCommerce client
- reconciliation cursor
- CSV import
- replay

event_sales/analytics/
- metric rules
- aggregators
- dashboard cache
- cache invalidation

event_sales/e2e/
- webhook to dashboard full path
```

## Web test areas

```text
event_sales_web/controllers/
- webhook controller
- export controller
- health controller

event_sales_web/live/admin/
- dashboard
- event detail
- mappings
- webhooks
- sync
- imports

event_sales_web/plugs/
- admin only
- rate limit
- event scope guard
```

---

# 7. Fixtures

```text
test/fixtures/woocommerce/
├── order_completed.json
├── order_pending.json
├── order_cancelled.json
├── order_refunded.json
├── order_mixed_event.json
├── product_updated.json
└── refund_created.json
```

Purpose:

```text
Use realistic WooCommerce/Tickera payloads for parser, worker, and end-to-end tests.
```

CSV fixtures:

```text
test/fixtures/csv/
├── valid_event_import.csv
├── invalid_missing_columns.csv
├── duplicate_rows.csv
└── mixed_status_orders.csv
```

Purpose:

```text
Test dry-run validation, duplicate detection, status handling, and import safety.
```

---

# 8. Documentation Structure

## Architecture docs

```text
docs/architecture/
├── overview.md
├── domain-map.md
├── data-flow.md
├── caching-strategy.md
├── performance-scaling-review.md
├── security-model.md
├── access-control-model.md
├── webhook-ingestion.md
├── reconciliation-strategy.md
├── csv-import-strategy.md
└── analytics-model.md
```

Purpose:

```text
Explain how the system is designed and why.
```

## Deployment docs

```text
docs/deployment/
├── railway.md
├── environment-variables.md
├── release-checklist.md
└── optional-vps-notes.md
```

Purpose:

```text
Make Railway deployment repeatable.
Keep VPS notes separate and secondary.
```

## Runbooks

```text
docs/runbooks/
├── production-smoke-test.md
├── webhook-troubleshooting.md
├── reconciliation.md
├── csv-import.md
├── event-launch-checklist.md
├── incident-response.md
└── security-review.md
```

Purpose:

```text
Help operate the system during real events.
```

## Product docs

```text
docs/product/
├── prd.md
├── kanban.md
├── vertical-slice-roadmap.md
└── future-client-dashboard.md
```

Purpose:

```text
Keep product scope, roadmap, and future plans visible.
```

## Decision records

```text
docs/decisions/
├── 0001-webhooks-primary-rest-fallback.md
├── 0002-completed-only-sales-metric.md
├── 0003-event-scoped-access-foundation.md
├── 0004-railway-primary-deployment.md
└── 0005-csv-import-as-controlled-backfill.md
```

Purpose:

```text
Preserve important architectural decisions.
```

---

# 9. Scripts Structure

```text
scripts/
├── scaffold_structure.sh
├── scaffold_modules.sh
├── scaffold_ash_resources.sh
├── scaffold_tests.sh
├── railway_smoke_test.sh
├── local_reset_db.sh
├── run_quality_checks.sh
└── generate_secret_key_base.sh
```

## Script responsibilities

| Script | Purpose |
|---|---|
| `scaffold_structure.sh` | Create base folders and `.keep` files. |
| `scaffold_modules.sh` | Create basic module shells with headers. |
| `scaffold_ash_resources.sh` | Create Ash resource stubs only. |
| `scaffold_tests.sh` | Create test skeletons matching the roadmap. |
| `railway_smoke_test.sh` | Verify production health, webhook endpoint, and app status. |
| `local_reset_db.sh` | Drop/create/migrate/seed local database. |
| `run_quality_checks.sh` | Run format, compile, tests, and lint checks. |
| `generate_secret_key_base.sh` | Generate Phoenix secret key base. |

Important rule:

```text
Scripts may scaffold boring structure.
Scripts must not generate unreviewed business logic.
```

---

# 10. Naming Conventions

## Application namespace

```text
EventSales
EventSalesWeb
```

## Ash domains

```text
EventSales.Accounts
EventSales.Catalog
EventSales.Sales
EventSales.Ingestion
EventSales.Analytics
EventSales.Audit
```

## Resource modules

Use singular nouns:

```text
EventSales.Sales.Order
EventSales.Sales.OrderItem
EventSales.Catalog.Event
EventSales.Catalog.TicketType
EventSales.Ingestion.WebhookEvent
```

## Worker modules

Use action-oriented names:

```text
EventSales.Ingestion.Workers.ProcessWebhookWorker
EventSales.Ingestion.Workers.ReconcileOrdersWorker
EventSales.Ingestion.Workers.ProcessCsvImportWorker
```

## LiveView modules

Use page names:

```text
EventSalesWeb.Admin.DashboardLive
EventSalesWeb.Admin.EventDetailLive
EventSalesWeb.Admin.MappingsLive
```

## Service modules

Use precise behavior names:

```text
MappingResolver
OrderUpserter
DashboardSnapshotBuilder
CacheInvalidator
MetadataSanitizer
```

---

# 11. Required Index Planning

## Accounts

```text
users.email unique
user_roles.user_id
user_roles.role_id
event_access_grants.user_id
event_access_grants.event_id
event_access_grants.expires_at
```

## Catalog

```text
source_systems.kind + base_url unique
events.source_system_id
events.slug
events.starts_at
ticket_types.event_id
product_mappings.source_system_id
product_mappings.woo_product_id
product_mappings.woo_variation_id
product_mappings.event_id
product_mappings.ticket_type_id
product_mappings.active
```

## Sales

```text
orders.source_system_id + woo_order_id unique
orders.status
orders.completed_at
orders.created_at_source
orders.updated_at_source
order_items.order_id + woo_line_item_id unique
order_items.event_id
order_items.ticket_type_id
order_items.mapping_status
order_items.woo_product_id
order_items.woo_variation_id
order_items.item_kind
```

## Ingestion

```text
webhook_events.delivery_id
webhook_events.topic
webhook_events.resource_id
webhook_events.status
webhook_events.received_at
webhook_events.payload_hash
sync_runs.source_system_id
sync_runs.status
sync_runs.started_at
sync_cursors.sync_run_id
csv_import_batches.event_id
csv_import_batches.status
csv_import_rows.csv_import_batch_id
csv_import_rows.status
```

## Audit

```text
audit_logs.user_id
audit_logs.event_id
audit_logs.action
audit_logs.inserted_at
```

---

# 12. Performance and Scaling Placement

## Hot data

Location:

```text
EventSales.Analytics.DashboardCache
EventSales.Analytics.Aggregators.*
```

Use for:

```text
today's totals
active event totals
order status counters
recent dashboard snapshots
```

Layer:

```text
ETS / GenServer / Cachex
TTL: 10s–5m
```

---

## Warm data

Location:

```text
EventSales.Analytics.DashboardCache
Redis-backed cache
```

Use for:

```text
event aggregate snapshots
ticket type summaries
chart datasets
future client dashboard snapshots
```

Layer:

```text
Redis
TTL: 30m–24h
```

---

## Cold data

Location:

```text
Ash resources backed by Postgres
```

Use for:

```text
orders
order items
events
ticket types
mappings
webhooks
sync runs
CSV imports
audit logs
```

Layer:

```text
Postgres
```

---

# 13. What Not To Add Yet

Do not add these folders/features in MVP unless the requirement changes:

```text
lib/event_sales/billing/
lib/event_sales/marketing/
lib/event_sales/checkins/
lib/event_sales/scanner/
lib/event_sales/tenanting/
lib/event_sales/client_portal/ full implementation
lib/event_sales/accounting/ full implementation
```

Reason:

```text
They are plausible future features, but they would distract from the sales dashboard MVP.
```

---

# 14. Success Criteria for the Folder Structure

The structure is successful when:

```text
Each domain has a clear owner.
Each resource has an obvious home.
Each worker has a clear queue and responsibility.
No WordPress REST calls can leak into LiveView.
Tests mirror the application structure.
Docs explain architecture, deployment, and operations.
Scripts can create boring scaffolding safely.
Future client dashboard support has a foundation without being built prematurely.
```

---

# 15. Final Recommendation

Use this structure from the beginning.

It is large enough to avoid messy growth, but not so abstract that the MVP becomes over-engineered.

The key discipline is this:

```text
Create the folders early.
Create the modules only when the slice needs them.
Keep business logic behind Ash actions and service modules.
Keep LiveView thin.
Keep WooCommerce isolated.
Keep WordPress protected.
```
