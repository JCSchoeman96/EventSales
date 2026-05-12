# EventSales — Comprehensive Vertical Slice Development Roadmap

**Project:** EventSales  
**Stack:** Elixir, Phoenix, LiveView, Ash 3.x, AshPostgres, Tailwind, Mishka Chelekom, Oban, Bandit, PostgreSQL, Redis, Railway  
**Primary source:** WooCommerce webhooks  
**Fallback/reconciliation:** WooCommerce REST API  
**Backfill:** REST API and event-scoped CSV import  
**Dashboard:** Internal admin dashboard first, future event/client-scoped dashboards later

---

## 1. Quick Direction for the Coding Agent

Build EventSales as a vertical-slice product, not as disconnected backend/frontend tasks.

Every slice must:

1. Add one working user/system capability.
2. Include Ash resources/actions/policies where needed.
3. Include Oban worker behavior where needed.
4. Include LiveView/admin visibility where needed.
5. Include strict automated tests.
6. Protect WordPress performance.
7. Avoid direct dashboard-to-WooCommerce calls.

The correct roadmap is **not**:

```text
DB first → API later → UI later → tests at the end
```

The correct roadmap is:

```text
thin working path → harden → expand → reconcile → import → expose → deploy
```

---

## 2. Ultimate Goal → MVP Backward Plan

### 2.1 Ultimate Long-Term Goal

EventSales becomes a reliable sales intelligence layer for WooCommerce + Tickera events:

```text
WooCommerce sells tickets.
EventSales receives and normalizes sales data.
Postgres stores durable reporting data.
Redis/ETS/cache layers serve fast dashboards.
LiveView gives admins and eventually clients scoped visibility.
REST reconciliation and CSV imports correct gaps.
Audit logs make all manual actions traceable.
```

### 2.2 MVP Goal

The MVP is complete when:

```text
A completed WooCommerce order webhook is received,
validated,
stored,
processed by Oban,
normalized into Ash/Postgres,
mapped to the right event and ticket type,
included in completed-only ticket/revenue totals,
visible on the admin dashboard within 5 minutes,
and recoverable through logs/replay/reconciliation.
```

### 2.3 Core Architectural Rule

```text
Dashboard reads EventSales data only.
Dashboard must never call WordPress or WooCommerce directly.
```

---

## 3. Locked Product Decisions

### 3.1 Ingestion Decisions

| Area | Decision |
|---|---|
| Primary ingestion | WooCommerce webhooks |
| Fallback/reconciliation | WooCommerce REST API |
| Backfill | REST API and CSV import |
| Webhook topics | `order.created`, `order.updated`, architecture-ready for `product.updated` and refund handling |
| Webhook behavior | Validate, store raw event, enqueue Oban job, return quickly |
| REST behavior | Worker-only, low concurrency, never from LiveView |
| REST max concurrency | 2 concurrent WooCommerce REST requests |
| Reconciliation | Hourly shallow sync, off-peak deeper sync |
| CSV import | Event-scoped dry-run + apply |

### 3.2 Sales Rules

| Metric | Rule |
|---|---|
| Tickets sold | Completed orders only |
| Dashboard statuses | Show all order statuses |
| Basic revenue | Completed ticket line item total after discounts |
| Pending/processing/failed/cancelled/refunded | Visible but excluded from MVP sold/revenue totals |
| Non-ticket products | Stored but excluded from ticket/event metrics |
| Unmapped products | Stored and alerted; excluded from ticket/event metrics |
| Mixed-event orders | Split by order line item |

### 3.3 Access Decisions

| Area | Decision |
|---|---|
| MVP launch | Internal admin dashboard only |
| Future client/event dashboards | Design infrastructure now, do not launch in MVP |
| Roles | `admin`, `staff`, `event_owner`, `event_staff` |
| Event-scoped access | Required from the domain/policy layer |
| Client dashboards | Aggregate-first, no PII by default |
| PII | Store order number, name, email for admin use; mask by role |
| Audit logs | Required for admin actions and future client access |

### 3.4 Deployment Decisions

| Area | Decision |
|---|---|
| Primary hosting | Railway |
| Database | Managed PostgreSQL |
| Cache/queue support | Redis + Oban |
| Web server | Phoenix/Bandit on Railway |
| VPS/systemd/Nginx | Not the primary deployment path |
| Tests | Full test suite from the beginning |

---

## 4. Domain Map Used by All Slices

```text
EventSales.Accounts
- User
- Role
- UserRole
- EventAccessGrant

EventSales.Catalog
- SourceSystem
- Event
- TicketType
- ProductMapping
- EventDashboardSetting

EventSales.Sales
- Order
- OrderItem
- CouponSnapshot

EventSales.Ingestion
- WebhookEvent
- SyncRun
- SyncCursor
- CsvImportBatch
- CsvImportRow

EventSales.Analytics
- EventAggregate
- DailySalesAggregate
- DashboardCache
- EventAggregator

EventSales.Audit
- AuditLog
```

---

## 5. Recommended Project Structure

```text
lib/
  event_sales/
    accounts/
      resources/
        user.ex
        role.ex
        user_role.ex
        event_access_grant.ex
      policies.ex
      pii_policy.ex

    catalog/
      resources/
        source_system.ex
        event.ex
        ticket_type.ex
        product_mapping.ex
        event_dashboard_setting.ex
      mapping_resolver.ex
      product_metadata_updater.ex

    sales/
      resources/
        order.ex
        order_item.ex
        coupon_snapshot.ex
      order_upserter.ex
      order_item_mapper.ex

    ingestion/
      resources/
        webhook_event.ex
        sync_run.ex
        sync_cursor.ex
        csv_import_batch.ex
        csv_import_row.ex
      workers/
        process_webhook_worker.ex
        reconcile_orders_worker.ex
        backfill_orders_worker.ex
        process_csv_import_worker.ex
        purge_raw_payloads_worker.ex
      clients/
        woocommerce_client.ex
        woocommerce_error.ex
      security/
        webhook_signature.ex
      parsers/
        woocommerce_order_parser.ex
      handlers/
        product_updated_handler.ex
      csv/
        parser.ex
        dry_run_validator.ex
        apply_import.ex
      webhook_processor.ex
      webhook_replay.ex

    analytics/
      resources/
        event_aggregate.ex
        daily_sales_aggregate.ex
      aggregators/
        event_aggregator.ex
      dashboard_cache.ex
      cache_keys.ex
      metric_rules.ex

    audit/
      resources/
        audit_log.ex
      logger.ex

    exports/
      event_sales_csv.ex

  event_sales_web/
    controllers/
      webhook_controller.ex
      export_controller.ex

    live/
      admin/
        dashboard_live.ex
        events_live.ex
        event_detail_live.ex
        orders_live.ex
        mappings_live.ex
        webhooks_live.ex
        sync_live.ex
        imports_live.ex
      components/
        stat_card.ex
        status_badge.ex
        sales_chart.ex
        order_table.ex
        unmapped_item_alert.ex

    plugs/
      admin_only.ex

    presenters/
      customer_presenter.ex

docs/
  architecture/
    overview.md
    domain-map.md
  deployment/
    railway.md
  runbooks/
    production-smoke-test.md
    webhook-troubleshooting.md
    event-launch-checklist.md
    reconciliation.md
    csv-import.md
    security.md
    incident-response.md

test/
  event_sales/
  event_sales_web/
  fixtures/
    woocommerce/
```

---

## 6. Strict Test Policy

Every slice must include tests before it is considered done.

### 6.1 Mandatory Test Types

```text
Unit tests:
- pure functions
- signature verification
- parsers
- metric rules
- mapping rules

Ash/resource tests:
- actions
- validations
- changes
- constraints
- policies

Worker tests:
- Oban execution
- retries
- idempotency
- failure behavior

Integration tests:
- webhook → DB
- DB → aggregate
- aggregate → LiveView
- REST sync → normalized orders

LiveView tests:
- permissions
- rendering
- forms
- alerts
- refresh behavior

Performance/safety tests:
- no direct WooCommerce call from LiveView
- REST concurrency capped at 2
- duplicate webhook does not duplicate records
- large CSV is streamed or chunked
```

### 6.2 Global Acceptance Command

Every slice should pass:

```bash
mix format --check-formatted
mix credo --strict
mix test
MIX_ENV=test mix ash.codegen --dry-run
```

If `credo` is not added immediately, replace it with the project’s chosen lint/static-analysis command.

---

## 7. Performance Architecture Rules

### 7.1 Data Layers

| Layer | Technology | Use | TTL |
|---|---|---|---|
| Hot | ETS / GenServer / Cachex | active dashboard counters, recent status, today totals | 10s–5m |
| Warm | Redis | event aggregate snapshots, chart data, client dashboard snapshots | 30m–24h |
| Cold | PostgreSQL | orders, order items, mappings, webhooks, sync runs, audits | durable |

### 7.2 WordPress Protection Rules

```text
Webhook endpoint returns quickly.
Webhook handler does not call WooCommerce REST.
Oban limits WooCommerce REST concurrency to 2.
REST sync pauses on 429/500/timeouts/slow responses.
Hourly reconciliation is shallow.
Deep reconciliation runs off-peak.
Backfills are date/event-scoped.
CSV import is processed asynchronously.
Dashboard never queries WordPress live.
Manual refresh never calls WooCommerce directly.
```

### 7.3 Cache Invalidation Rules

Invalidate affected cache when:

```text
order processed
order status changed
mapping changed
CSV import applied
reconciliation applied
product metadata relevant to mapping changed
raw aggregate recalculation completed
```

---

# 8. Vertical Slice Roadmap

---

## Slice 0 — Project Bootstrap and Development Guardrails

### Goal

Create the new `EventSales` Phoenix/Ash application with the correct foundation.

### Outcome

A clean app boots locally, connects to Postgres/Redis, runs tests, and has Railway-ready runtime config.

### Build

```text
Phoenix app
Ash 3.x
AshPostgres
LiveView
Tailwind
Mishka Chelekom
Bandit
Oban
Postgres
Redis
basic health route
Railway env documentation
test tooling
formatter/linter setup
```

### Key Files

```text
mix.exs
config/config.exs
config/runtime.exs
config/test.exs
lib/event_sales/application.ex
lib/event_sales_web/router.ex
docs/deployment/railway.md
docs/architecture/overview.md
test/support/
```

### Strict Tests

```text
Application boots in test.
Repo connects.
Redis config loads safely.
Oban starts in test mode.
Health route returns success.
Required env variables are documented.
No production secrets are hardcoded.
```

### Performance & Scaling Review

```text
Data layer: none yet.
Risk: bad runtime config blocks Railway deploy.
Rule: runtime config must use env variables only.
```

### Done When

```text
mix test passes
health route works
Railway deployment assumptions are documented
no business logic has been faked
```

---

## Slice 1 — Domain Skeleton and Ash Boundaries

### Goal

Create the domain boundaries before business logic grows randomly.

### Outcome

The app has named Ash domains and resource locations, even if most resources are still thin.

### Build

```text
EventSales.Accounts
EventSales.Catalog
EventSales.Sales
EventSales.Ingestion
EventSales.Analytics
EventSales.Audit
```

### Key Files

```text
lib/event_sales/accounts.ex
lib/event_sales/catalog.ex
lib/event_sales/sales.ex
lib/event_sales/ingestion.ex
lib/event_sales/analytics.ex
lib/event_sales/audit.ex
```

### Strict Tests

```text
Each Ash domain compiles.
Each domain is registered correctly.
No resource is placed directly in the web layer.
No WooCommerce code exists in LiveView/controllers except webhook intake.
```

### Performance & Scaling Review

```text
Data layer: structural.
Risk: bad boundaries cause future coupling.
Rule: workers orchestrate; Ash actions own domain mutation.
```

### Done When

```text
Domain modules compile
folder structure matches roadmap
tests prove resources are discoverable
```

---

## Slice 2 — Accounts, Roles, and Event-Scoped Access Foundation

### Goal

Prepare safe admin access now and future event/client dashboard access later.

### Outcome

Users can have roles, and event-scoped access grants exist even though the MVP launches admin-only.

### Build

```text
User
Role
UserRole
EventAccessGrant
basic auth setup
role constants
policy helpers
```

### Key Files

```text
lib/event_sales/accounts/resources/user.ex
lib/event_sales/accounts/resources/role.ex
lib/event_sales/accounts/resources/user_role.ex
lib/event_sales/accounts/resources/event_access_grant.ex
lib/event_sales/accounts/policies.ex
test/event_sales/accounts/
```

### Strict Tests

```text
Admin can access global admin resources.
Staff cannot access restricted admin actions unless permitted.
Event owner can only access assigned event records.
Event staff cannot access revenue by default.
Unauthenticated users are rejected.
Event access grant expiry is respected.
```

### Performance & Scaling Review

```text
Data layer: cold Postgres.
Required indexes:
- users.email unique
- user_roles.user_id
- event_access_grants.user_id
- event_access_grants.event_id
- event_access_grants.expires_at

Risk: future client dashboards leak data.
Rule: event scoping must be enforced by Ash policies, not LiveView routes.
```

### Done When

```text
Role model exists
event access grants exist
admin login path works
policy tests pass
```

---

## Slice 3 — Catalog: Source, Events, Ticket Types, and Mappings

### Goal

Represent the business reality: WooCommerce products/variations map to ticket types under events.

### Outcome

Admins can create internal events and ticket types and map WooCommerce product/variation IDs.

### Build

```text
SourceSystem
Event
TicketType
ProductMapping
EventDashboardSetting
manual capacity
mapping status foundation
```

### Key Files

```text
lib/event_sales/catalog/resources/source_system.ex
lib/event_sales/catalog/resources/event.ex
lib/event_sales/catalog/resources/ticket_type.ex
lib/event_sales/catalog/resources/product_mapping.ex
lib/event_sales/catalog/resources/event_dashboard_setting.ex
test/event_sales/catalog/
```

### Strict Tests

```text
Event requires source system.
TicketType belongs to Event.
ProductMapping requires product_id and optional variation_id.
ProductMapping uniqueness prevents duplicate active mappings.
Capacity can be nil.
Mapping can store original label and current label.
Event dashboard setting controls future revenue visibility.
```

### Performance & Scaling Review

```text
Data layer: cold Postgres, warm Redis later.
Required indexes:
- events.source_system_id
- events.slug
- events.starts_at
- ticket_types.event_id
- product_mappings.source_system_id
- product_mappings.woo_product_id
- product_mappings.woo_variation_id
- product_mappings.event_id
- product_mappings.ticket_type_id

Risk: unmapped or duplicate products corrupt metrics.
Rule: one active mapping per source/product/variation combination.
```

### Done When

```text
Events/ticket types/mappings can be created
mapping uniqueness is enforced
policy tests pass
```

---

## Slice 4 — Sales Storage: Orders and Order Items

### Goal

Create durable normalized sales records independent from WordPress.

### Outcome

WooCommerce order headers and line items can be stored without needing the dashboard or webhook yet.

### Build

```text
Order
OrderItem
CouponSnapshot
status model
minimal customer fields
ticket/non-ticket item classification
```

### Key Files

```text
lib/event_sales/sales/resources/order.ex
lib/event_sales/sales/resources/order_item.ex
lib/event_sales/sales/resources/coupon_snapshot.ex
test/event_sales/sales/
```

### Strict Tests

```text
Order is unique by source_system_id + woo_order_id.
OrderItem is unique by order_id + woo_line_item_id.
One order can contain multiple order items.
One order can contain items for multiple events.
Quantity greater than 1 is handled.
Completed status is stored.
Pending/failed/cancelled/refunded statuses are stored but not counted as sold.
Customer name/email is stored but policy-protected.
```

### Performance & Scaling Review

```text
Data layer: cold Postgres.
Required indexes:
- orders.source_system_id
- orders.woo_order_id
- orders.status
- orders.completed_at
- order_items.order_id
- order_items.event_id
- order_items.ticket_type_id
- order_items.mapping_status
- order_items.woo_product_id
- order_items.woo_variation_id

Risk: order-level revenue lies when one cart has multiple events.
Rule: reporting must split by order item, not only by order.
```

### Done When

```text
Orders and line items can be upserted idempotently
mixed-event order structure is supported
status rules are test-covered
```

---

## Slice 5 — Webhook Security and Intake

### Goal

Receive WooCommerce webhooks safely and return quickly.

### Outcome

Phoenix accepts valid webhooks, rejects invalid ones, stores raw payloads, enqueues Oban jobs, and does no heavy work inline.

### Build

```text
Webhook signature verification
WEBHOOK_PATH_TOKEN secondary check
WebhookEvent resource
Webhook controller
Oban enqueue
invalid signature logging
```

### Key Files

```text
lib/event_sales/ingestion/resources/webhook_event.ex
lib/event_sales/ingestion/security/webhook_signature.ex
lib/event_sales_web/controllers/webhook_controller.ex
lib/event_sales/ingestion/workers/process_webhook_worker.ex
test/event_sales/ingestion/webhook_signature_test.exs
test/event_sales_web/controllers/webhook_controller_test.exs
```

### Strict Tests

```text
Valid signature is accepted.
Invalid signature is rejected.
Wrong path token is rejected.
GET/PUT/PATCH/DELETE are rejected.
Valid webhook stores WebhookEvent.
Valid webhook enqueues Oban job.
Controller does not call WooCommerce REST.
Raw payload is retained for valid webhook.
Invalid payload does not store full raw body.
Response is fast and does not process business logic inline.
```

### Performance & Scaling Review

```text
Data layer:
- cold Postgres for WebhookEvent
- Oban queue for processing

Required indexes:
- webhook_events.status
- webhook_events.topic
- webhook_events.resource_id
- webhook_events.delivery_id
- webhook_events.received_at
- webhook_events.payload_hash

TTL:
- raw payload retention 90 days

Risk: slow webhook endpoint causes WooCommerce webhook disablement.
Rule: validate → store → enqueue → return.
```

### Done When

```text
Webhook intake is secure
job enqueue works
invalid requests are safely rejected
```

---

## Slice 6 — Idempotent Webhook Processing

### Goal

Process duplicate webhook deliveries safely.

### Outcome

The same webhook can arrive multiple times without duplicating orders, line items, or metrics.

### Build

```text
ProcessWebhookWorker
idempotency keys
payload hash
topic/resource handling
processed/failed statuses
retry with jitter
```

### Key Files

```text
lib/event_sales/ingestion/workers/process_webhook_worker.ex
lib/event_sales/ingestion/webhook_processor.ex
test/event_sales/ingestion/process_webhook_worker_test.exs
```

### Strict Tests

```text
Duplicate delivery_id does not create duplicate records.
Same order.updated event can be processed repeatedly safely.
Failed processing marks webhook event failed.
Retried processing can later succeed.
Worker uses Oban retry/backoff.
Invalid topic is safely ignored or marked unsupported.
Processing is idempotent by source/resource/hash.
```

### Performance & Scaling Review

```text
Data layer:
- cold Postgres for idempotency
- Oban webhooks queue

Required indexes:
- unique webhook delivery/resource/hash key
- orders source_system_id + woo_order_id
- order_items order_id + woo_line_item_id

Risk: duplicate webhooks inflate sales.
Rule: every external event must be replay-safe.
```

### Done When

```text
Duplicate webhook tests pass
retries are safe
failed events are visible
```

---

## Slice 7 — WooCommerce Order Normalization

### Goal

Turn WooCommerce order payloads into normalized orders and order items.

### Outcome

A realistic WooCommerce `order.created` or `order.updated` payload produces internal sales records.

### Build

```text
WooCommerce order parser
line item parser
status mapper
customer field sanitizer
coupon snapshot parser
money/decimal handling
```

### Key Files

```text
lib/event_sales/ingestion/parsers/woocommerce_order_parser.ex
lib/event_sales/sales/order_upserter.ex
test/fixtures/woocommerce/order_completed.json
test/fixtures/woocommerce/order_pending.json
test/fixtures/woocommerce/order_refunded.json
test/event_sales/ingestion/woocommerce_order_parser_test.exs
```

### Strict Tests

```text
Completed order parses correctly.
Pending order parses correctly.
Refunded/cancelled order parses correctly.
Line item quantity is preserved.
Product ID and variation ID are preserved.
Line subtotal/line total/discount are parsed as decimals.
Customer name/email are normalized.
Missing optional fields do not crash parser.
Malformed required fields return controlled error.
```

### Performance & Scaling Review

```text
Data layer: cold Postgres after parse.
Risk: WooCommerce payload shape varies.
Rule: parser must be tolerant but never silently corrupt money/status values.
```

### Done When

```text
realistic fixtures normalize into internal structs
parser errors are explicit
order upsert action works
```

---

## Slice 8 — Mapping Resolution and Unmapped Queue

### Goal

Connect order items to events/ticket types or flag them as unmapped.

### Outcome

Mapped products count toward event metrics; unmapped products appear in an admin queue.

### Build

```text
mapping resolver
order item mapping_status
unmapped item query
admin unmapped list
mapping correction action
mapping recalculation enqueue
```

### Key Files

```text
lib/event_sales/catalog/mapping_resolver.ex
lib/event_sales/sales/order_item_mapper.ex
lib/event_sales_web/live/admin/mappings_live.ex
test/event_sales/catalog/mapping_resolver_test.exs
test/event_sales_web/live/admin/mappings_live_test.exs
```

### Strict Tests

```text
Product-only mapping resolves correctly.
Product + variation mapping resolves correctly.
Variation-specific mapping wins over product-level mapping.
Unmapped item is stored and excluded from ticket metrics.
Non-ticket product is stored as non-ticket and excluded from ticket metrics.
Admin can create mapping.
Creating mapping enqueues recalculation job.
Mapping change is audited.
```

### Performance & Scaling Review

```text
Data layer:
- cold Postgres mappings
- warm cache possible for product mapping lookup

Cache:
- product mapping cache TTL 30m–24h
- invalidate on mapping create/update/delete

Risk: repeated DB lookup per line item during bursts.
Rule: mapping resolver may use Redis/ETS cache after correctness is proven.
```

### Done When

```text
mapped items count
unmapped items alert
mapping changes trigger recalculation
```

---

## Slice 9 — Completed-Only Metrics and Revenue Rules

### Goal

Make the dashboard mathematically trustworthy.

### Outcome

Tickets sold and revenue follow the locked business rules.

### Build

```text
completed-only ticket totals
completed-only basic revenue
status breakdown
ticket type totals
event totals
today vs total metrics
```

### Key Files

```text
lib/event_sales/analytics/metric_rules.ex
lib/event_sales/analytics/event_aggregator.ex
lib/event_sales/analytics/resources/event_aggregate.ex
lib/event_sales/analytics/resources/daily_sales_aggregate.ex
test/event_sales/analytics/metric_rules_test.exs
test/event_sales/analytics/event_aggregator_test.exs
```

### Strict Tests

```text
Completed order counts as sold.
Pending order does not count as sold.
Processing order is visible but does not count as sold.
Failed order is visible but does not count as sold.
Cancelled order is visible but does not count as sold.
Refunded order is visible but excluded from MVP sold/revenue.
Revenue uses completed ticket line total after discounts.
Non-ticket item does not count toward ticket revenue.
Unmapped item does not count toward ticket revenue.
Today metrics respect configured timezone.
```

### Performance & Scaling Review

```text
Data layer:
- hot ETS/Cachex for active dashboard counters
- warm Redis for event aggregate snapshots
- cold Postgres for durable records

TTL:
- dashboard counters 10s–5m
- event aggregate snapshots 30m–24h

Risk: live SUM/GROUP BY on every dashboard mount.
Rule: dashboards use cached/precomputed aggregates where possible.
```

### Done When

```text
metric rules are fully test-covered
status/revenue behavior is deterministic
```

---

## Slice 10 — Admin Dashboard First Useful Version

### Goal

Show the internal team a useful dashboard from internal data only.

### Outcome

Admin sees sales totals, order statuses, tickets by event/type, recent orders, and alerts.

### Build

```text
/admin/dashboard
KPI cards
status breakdown
tickets by event
tickets by type
recent orders
unmapped alerts
failed webhook/sync alerts
manual refresh button
```

### Key Files

```text
lib/event_sales_web/live/admin/dashboard_live.ex
lib/event_sales_web/live/components/stat_card.ex
lib/event_sales_web/live/components/status_badge.ex
lib/event_sales_web/live/components/order_table.ex
test/event_sales_web/live/admin/dashboard_live_test.exs
```

### Strict Tests

```text
Admin can view dashboard.
Unauthenticated user cannot view dashboard.
Non-admin access is restricted according to policy.
Dashboard renders completed ticket totals.
Dashboard renders revenue totals.
Dashboard renders order statuses.
Dashboard renders unmapped item alert.
Dashboard renders failed webhook alert.
Manual refresh reloads EventSales cache only.
Manual refresh does not call WooCommerce REST.
Manual refresh is rate-limited.
```

### Performance & Scaling Review

```text
Data layer:
- reads hot/warm cache first
- falls back to Postgres aggregate query only when safe

Risk: dashboard becomes accidental load generator.
Rule: no polling; PubSub + manual refresh only.
```

### Done When

```text
dashboard is useful with seeded/test order data
policy and refresh tests pass
```

---

## Slice 11 — PubSub and Dashboard Cache Updates

### Goal

Update dashboard values after processed orders without polling.

### Outcome

When a webhook is processed, aggregates update and LiveView receives a PubSub event.

### Build

```text
DashboardCache
PubSub topics
aggregate invalidation
LiveView handle_info
manual refresh fallback
```

### Key Files

```text
lib/event_sales/analytics/dashboard_cache.ex
lib/event_sales/analytics/cache_keys.ex
lib/event_sales_web/live/admin/dashboard_live.ex
test/event_sales/analytics/dashboard_cache_test.exs
test/event_sales_web/live/admin/dashboard_pubsub_test.exs
```

### Strict Tests

```text
Processed order invalidates affected event cache.
Processed order broadcasts dashboard update.
Dashboard receives PubSub message.
Dashboard updates assigns without full page reload.
Manual refresh works if PubSub was missed.
Cache TTL is configured.
Cache keys include event scope where needed.
```

### Performance & Scaling Review

```text
Hot:
- ETS/Cachex 10s–5m

Warm:
- Redis 30m–24h

Invalidation:
- order processed
- mapping changed
- CSV import applied
- reconciliation applied

Risk: stale cache lies.
Rule: every mutation path must invalidate affected aggregates.
```

### Done When

```text
order processed → dashboard update is tested end-to-end
```

---

## Slice 12 — Event Detail Page

### Goal

Give admins a per-event operational view.

### Outcome

An admin can inspect one event’s capacity, sold count, remaining count, ticket type breakdown, orders, and unmapped issues.

### Build

```text
/admin/events
/admin/events/:id
event summary
capacity
sold/remaining
ticket type breakdown
order status breakdown
recent orders stream
CSV/export buttons placeholder
```

### Key Files

```text
lib/event_sales_web/live/admin/events_live.ex
lib/event_sales_web/live/admin/event_detail_live.ex
lib/event_sales_web/live/components/sales_chart.ex
test/event_sales_web/live/admin/event_detail_live_test.exs
```

### Strict Tests

```text
Admin can view event list.
Admin can view event detail.
Event with nil capacity renders without remaining count.
Event with capacity renders remaining count.
Ticket type breakdown is correct.
Mixed-event orders show only relevant line items.
Unmapped event items are visible.
Event access policy is enforced.
```

### Performance & Scaling Review

```text
Data:
- event aggregates from Redis/Postgres
- recent orders paginated/streamed

Risk: loading every order item for event detail.
Rule: paginate and stream recent order rows.
```

### Done When

```text
event detail page answers “how is this event selling?”
```

---

## Slice 13 — Webhook Debug and Replay UI

### Goal

Make ingestion observable and recoverable.

### Outcome

Admins can see webhook deliveries, failures, and replay failed events.

### Build

```text
/admin/webhooks
webhook list
status filter
topic filter
failed replay action
payload metadata
raw payload access admin-only
confirmation modal
audit log
```

### Key Files

```text
lib/event_sales_web/live/admin/webhooks_live.ex
lib/event_sales/ingestion/webhook_replay.ex
test/event_sales_web/live/admin/webhooks_live_test.exs
test/event_sales/ingestion/webhook_replay_test.exs
```

### Strict Tests

```text
Admin can view webhook log.
Webhook log uses pagination or streams.
Failed webhook can be replayed.
Processed webhook cannot be accidentally replayed unless explicitly allowed.
Replay enqueues Oban job, does not process inline.
Replay requires confirmation.
Replay is rate-limited.
Replay writes audit log.
Non-admin cannot view raw payload.
```

### Performance & Scaling Review

```text
Data:
- cold Postgres webhook events
- LiveView streams for logs

Risk: raw payload display leaks PII.
Rule: raw payload visible only to admin and preferably collapsed/explicit.
```

### Done When

```text
failed ingestion can be diagnosed and replayed safely
```

---

## Slice 14 — WooCommerce REST Client Boundary

### Goal

Create the REST fallback layer without harming WordPress.

### Outcome

EventSales can fetch WooCommerce orders/products through a controlled client, but only workers use it.

### Build

```text
WooCommerceClient
auth config
timeouts
pagination helpers
error classification
rate/concurrency guard
test mocks
```

### Key Files

```text
lib/event_sales/ingestion/clients/woocommerce_client.ex
lib/event_sales/ingestion/clients/woocommerce_error.ex
test/event_sales/ingestion/woocommerce_client_test.exs
```

### Strict Tests

```text
Client builds authenticated request.
Client handles pagination metadata.
Client handles 401/403.
Client handles 404.
Client handles 429.
Client handles 500.
Client handles timeout.
Client returns typed errors.
Client never raises uncontrolled exceptions for normal HTTP failures.
LiveViews do not call WooCommerceClient.
```

### Performance & Scaling Review

```text
REST concurrency:
- max 2

Timeout:
- short and explicit

Risk: EventSales DDoSes WordPress.
Rule: REST is worker-only and concurrency-capped.
```

### Done When

```text
REST client is safe, typed, and testable
```

---

## Slice 15 — Reconciliation and Sync Runs

### Goal

Catch missed/changed WooCommerce orders.

### Outcome

Admins can queue a scoped reconciliation; scheduled shallow reconciliation can run safely.

### Build

```text
SyncRun
SyncCursor
ReconcileOrdersWorker
manual scoped sync
hourly shallow sync
off-peak deep sync foundation
pause behavior
```

### Key Files

```text
lib/event_sales/ingestion/resources/sync_run.ex
lib/event_sales/ingestion/resources/sync_cursor.ex
lib/event_sales/ingestion/workers/reconcile_orders_worker.ex
lib/event_sales_web/live/admin/sync_live.ex
test/event_sales/ingestion/reconcile_orders_worker_test.exs
test/event_sales_web/live/admin/sync_live_test.exs
```

### Strict Tests

```text
Sync run requires event/date scope for manual action.
Sync run stores cursor.
Sync resumes from cursor.
Sync processes modified orders only.
Sync uses REST concurrency max 2.
Sync pauses on 429.
Sync pauses on repeated 500/timeouts.
Sync records counts and failures.
Admin manual sync requires confirmation.
Manual sync is rate-limited.
Manual sync writes audit log.
```

### Performance & Scaling Review

```text
Data:
- cold Postgres sync runs/cursors
- Oban reconciliation queue

REST:
- max concurrency 2
- shallow hourly
- deep off-peak

Risk: reconciliation hurts checkout performance.
Rule: pause on slow/error responses and never full-scan during peak.
```

### Done When

```text
missed orders can be reconciled safely
sync behavior is visible in UI
```

---

## Slice 16 — Product Updated Handling

### Goal

Handle WooCommerce product/variation changes without corrupting historic reporting.

### Outcome

Product updates can refresh mapping labels/current metadata without rewriting history incorrectly.

### Build

```text
product.updated webhook handler
product metadata normalization
current label update
mapping alert if product unknown
optional product REST fetch
```

### Key Files

```text
lib/event_sales/ingestion/handlers/product_updated_handler.ex
lib/event_sales/catalog/product_metadata_updater.ex
test/event_sales/ingestion/product_updated_handler_test.exs
```

### Strict Tests

```text
Known product update refreshes current label.
Original order item label remains unchanged.
Unknown product update creates alert or ignored status.
Product update does not recalculate revenue unless mapping changed.
Product update does not call REST inside webhook controller.
Product update worker is idempotent.
```

### Performance & Scaling Review

```text
Data:
- cold Postgres mappings
- warm Redis mapping cache invalidation

Risk: product update webhook noise.
Rule: process only fields that matter for mapping/dashboard labels.
```

### Done When

```text
product updates improve labels/mappings without breaking history
```

---

## Slice 17 — CSV Import Dry-Run

### Goal

Support special-case backfills without trusting CSV blindly.

### Outcome

Admins can upload an event-scoped CSV and see validation results before applying.

### Build

```text
CsvImportBatch
CsvImportRow
CSV parser
dry-run validator
row errors
duplicate detection preview
admin import screen
```

### Key Files

```text
lib/event_sales/ingestion/resources/csv_import_batch.ex
lib/event_sales/ingestion/resources/csv_import_row.ex
lib/event_sales/ingestion/csv/parser.ex
lib/event_sales/ingestion/csv/dry_run_validator.ex
lib/event_sales_web/live/admin/imports_live.ex
test/event_sales/ingestion/csv_import_test.exs
```

### Strict Tests

```text
CSV import requires event scope.
Missing required columns fail validation.
Invalid money fails validation.
Invalid quantity fails validation.
Unknown ticket mapping fails validation.
Duplicate order/line item is detected.
Large CSV is streamed/chunked, not loaded blindly.
Dry-run does not mutate sales tables.
Dry-run stores row-level errors.
Non-admin cannot import.
```

### Performance & Scaling Review

```text
Data:
- cold Postgres import batches/rows

Risk: large CSV memory spike.
Rule: stream/chunk import processing.
```

### Done When

```text
CSV can be validated safely before writing sales records
```

---

## Slice 18 — CSV Apply Worker

### Goal

Apply validated CSV imports asynchronously and audibly.

### Outcome

CSV rows can create/update sales records through the same domain rules as webhooks/reconciliation.

### Build

```text
ProcessCsvImportWorker
idempotent import apply
batch status
row result status
audit log
cache invalidation
```

### Key Files

```text
lib/event_sales/ingestion/workers/process_csv_import_worker.ex
lib/event_sales/ingestion/csv/apply_import.ex
test/event_sales/ingestion/process_csv_import_worker_test.exs
```

### Strict Tests

```text
Only valid dry-run batch can be applied.
Apply runs through Oban, not LiveView.
Apply is idempotent.
Duplicate rows do not double-count.
Apply updates affected event aggregates.
Apply invalidates cache.
Apply writes audit log.
Apply records row-level success/failure.
Failed apply can be retried safely.
```

### Performance & Scaling Review

```text
Data:
- cold Postgres
- analytics cache invalidation

Risk: CSV import bypasses business rules.
Rule: CSV uses same order/order-item upsert and metric rules.
```

### Done When

```text
CSV import can backfill selected event data safely
```

---

## Slice 19 — Audit Logging Across Sensitive Actions

### Goal

Make the system accountable.

### Outcome

Manual syncs, replays, mapping changes, CSV applies, and future client access are traceable.

### Build

```text
AuditLog
audit helper
audit metadata rules
admin audit view optional
policy integration
```

### Key Files

```text
lib/event_sales/audit/resources/audit_log.ex
lib/event_sales/audit/logger.ex
test/event_sales/audit/audit_log_test.exs
```

### Strict Tests

```text
Mapping change writes audit log.
Webhook replay writes audit log.
Manual sync writes audit log.
CSV apply writes audit log.
Audit log stores user_id when available.
Audit log stores event_id when applicable.
Audit log does not store secrets.
Audit log metadata is bounded/sanitized.
```

### Performance & Scaling Review

```text
Data:
- cold Postgres

Required indexes:
- audit_logs.user_id
- audit_logs.event_id
- audit_logs.action
- audit_logs.inserted_at

Risk: audit logs leak sensitive payloads.
Rule: no secrets and no full raw payloads in audit metadata.
```

### Done When

```text
sensitive actions are traceable
```

---

## Slice 20 — PII Masking and Access Safety

### Goal

Prevent future event/client dashboard data leaks.

### Outcome

Customer name/email visibility is role-controlled.

### Build

```text
PII masking helpers
Ash policies/field policies
role-based rendering helpers
tests for admin/staff/event_owner/event_staff
```

### Key Files

```text
lib/event_sales/accounts/pii_policy.ex
lib/event_sales_web/presenters/customer_presenter.ex
test/event_sales/accounts/pii_policy_test.exs
```

### Strict Tests

```text
Admin can see full customer email.
Staff sees masked or configured email view.
Event owner does not see email by default.
Event staff does not see email.
Aggregate dashboards expose no PII.
Raw webhook payload is admin-only.
Exports respect PII policy.
```

### Performance & Scaling Review

```text
Data:
- cold Postgres PII fields
- role-aware projection in app layer

Risk: future client dashboard accidentally reuses admin component.
Rule: admin components and client-safe components must be separated.
```

### Done When

```text
PII behavior is deterministic and test-covered
```

---

## Slice 21 — Event-Scoped Dashboard Infrastructure

### Goal

Add the foundation for future password/token-protected client dashboards without launching them.

### Outcome

The schema and policy layer can support event owner dashboards later.

### Build

```text
EventDashboardSetting
event access grants
dashboard visibility settings
revenue visibility setting
token/expiry placeholder or later-ready model
aggregate-only query path
```

### Key Files

```text
lib/event_sales/catalog/resources/event_dashboard_setting.ex
lib/event_sales/accounts/resources/event_access_grant.ex
test/event_sales/catalog/event_dashboard_setting_test.exs
test/event_sales/accounts/event_access_policy_test.exs
```

### Strict Tests

```text
Event owner can access assigned event aggregate.
Event owner cannot access unassigned event.
Event staff cannot see revenue by default.
Revenue visibility setting controls access.
Expired event access grant denies access.
Aggregate query path excludes PII.
```

### Performance & Scaling Review

```text
Data:
- warm Redis event dashboard snapshots
- cold Postgres event settings/grants

Risk: client dashboards create many repeated reads.
Rule: future client views must read cached event aggregates.
```

### Done When

```text
future client dashboards can be built safely later
without changing the core schema
```

---

## Slice 22 — Exports

### Goal

Allow admins to export useful event sales data.

### Outcome

Admins can export event-level order/ticket summaries as CSV.

### Build

```text
event summary CSV export
order list CSV export
PII-aware export policy
streamed export response
audit log
```

### Key Files

```text
lib/event_sales/exports/event_sales_csv.ex
lib/event_sales_web/controllers/export_controller.ex
test/event_sales/exports/event_sales_csv_test.exs
test/event_sales_web/controllers/export_controller_test.exs
```

### Strict Tests

```text
Admin can export event summary.
Admin can export event order list.
Export respects event scope.
Export respects PII policy.
Export excludes unmapped items from ticket metrics.
Export includes status fields.
Export writes audit log.
Large export is streamed or paginated.
```

### Performance & Scaling Review

```text
Data:
- cold Postgres
- streaming output

Risk: export loads all rows into memory.
Rule: stream/paginate export data.
```

### Done When

```text
admin can safely export event sales summaries
```

---

## Slice 23 — Oban Web and Operational Admin Protection

### Goal

Expose operational visibility safely.

### Outcome

Oban Web is available only to protected admin users with extra protection.

### Build

```text
protected Oban Web route
admin-only access
optional basic auth/IP restriction
job queues visible
retry visibility
```

### Key Files

```text
lib/event_sales_web/router.ex
lib/event_sales_web/plugs/admin_only.ex
test/event_sales_web/oban_web_access_test.exs
```

### Strict Tests

```text
Unauthenticated user cannot access Oban Web.
Non-admin cannot access Oban Web.
Admin can access Oban Web.
Sensitive routes require admin session.
Oban Web is not mounted publicly in test/prod by accident.
```

### Performance & Scaling Review

```text
Data:
- Oban Postgres tables

Risk: exposing operational controls publicly.
Rule: admin-only and preferably extra protection in production.
```

### Done When

```text
operations are visible without creating a security hole
```

---

## Slice 24 — Maintenance Jobs

### Goal

Keep the system healthy over time.

### Outcome

Old raw payloads and stale cache/sync artifacts can be cleaned safely.

### Build

```text
PurgeRawPayloadsWorker
cache cleanup
stale sync cleanup
failed job alert foundation
```

### Key Files

```text
lib/event_sales/ingestion/workers/purge_raw_payloads_worker.ex
lib/event_sales/maintenance/cache_cleanup_worker.ex
test/event_sales/maintenance/purge_raw_payloads_worker_test.exs
```

### Strict Tests

```text
Raw payload older than 90 days is purged or redacted.
Recent raw payload is kept.
Purge job does not delete normalized orders.
Purge job records audit/maintenance log.
Purge job is idempotent.
```

### Performance & Scaling Review

```text
Data:
- cold Postgres cleanup
- Redis cache cleanup

TTL:
- raw webhook payload 90 days
- dashboard cache 10s–24h depending on layer

Risk: maintenance deletes useful normalized data.
Rule: purge raw payload only, not sales truth.
```

### Done When

```text
retention policy is enforced safely
```

---

## Slice 25 — Full End-to-End Webhook-to-Dashboard Acceptance

### Goal

Prove the MVP’s main reason for existing.

### Outcome

A completed WooCommerce order fixture flows through the entire system into the dashboard.

### Build

```text
end-to-end integration test
fixture webhook
stored webhook
Oban processing
order/order item upsert
mapping resolution
aggregate update
dashboard render
```

### Key Files

```text
test/event_sales/e2e/webhook_to_dashboard_test.exs
test/fixtures/woocommerce/
```

### Strict Tests

```text
Valid completed order webhook returns 2xx.
WebhookEvent is stored.
Oban job processes event.
Order is created.
OrderItem is created.
OrderItem maps to event/ticket type.
Ticket sold total increments by quantity.
Revenue total increments by completed ticket line total.
Dashboard renders updated values.
Duplicate webhook does not change totals.
Pending version of same order does not count as sold.
Completed update of same order counts once.
```

### Performance & Scaling Review

```text
Full path:
- webhook request stays fast
- processing async
- dashboard reads cache/Postgres only
- no REST call unless explicitly required

Risk: system works only in isolated unit tests.
Rule: full path must be tested as one slice.
```

### Done When

```text
one realistic order proves the entire architecture
```

---

## Slice 26 — Railway Deployment and Production Smoke Test

### Goal

Deploy the MVP to Railway and verify production behavior.

### Outcome

EventSales runs on Railway with Postgres/Redis, receives a real/sandbox WooCommerce webhook, and displays it.

### Build

```text
Railway service config
production env variables
health check
release command
migrations
Oban in production
Redis connection
webhook URL
smoke test guide
rollback guide
```

### Key Files

```text
docs/deployment/railway.md
docs/runbooks/production-smoke-test.md
docs/runbooks/webhook-troubleshooting.md
```

### Strict Tests

```text
Build succeeds on Railway.
Migrations run.
Health route passes.
App connects to Postgres.
App connects to Redis.
Oban starts.
Webhook endpoint reachable over HTTPS.
Invalid webhook rejected in production.
Valid WooCommerce test webhook stored.
Admin dashboard accessible.
Oban Web protected.
```

### Performance & Scaling Review

```text
Data:
- Railway Postgres
- Railway Redis

Risk:
- wrong env vars
- missing release command
- app sleeps/scales unexpectedly
- webhook URL misconfigured
- Oban not running

Rule:
- production smoke test must prove webhook → dashboard path.
```

### Done When

```text
production deployment receives and displays a test order safely
```

---

## Slice 27 — Hardening and Launch Readiness

### Goal

Make the MVP safe enough to trust during a real event.

### Outcome

The system has guardrails, alerts, docs, and recovery procedures.

### Build

```text
runbooks
admin checklist
alert thresholds
failed webhook review
sync review
backup assumptions
load/burst test
security review
```

### Key Files

```text
docs/runbooks/event-launch-checklist.md
docs/runbooks/reconciliation.md
docs/runbooks/csv-import.md
docs/runbooks/security.md
docs/runbooks/incident-response.md
```

### Strict Tests

```text
Webhook burst test does not duplicate data.
REST sync concurrency never exceeds 2.
Manual sync rate limit works.
CSV import large-file test passes.
Policy tests pass for all roles.
PII masking tests pass.
Cache invalidation tests pass.
Failed webhook replay works.
Raw payload purge works.
```

### Performance & Scaling Review

```text
Launch-day risks:
- webhook bursts
- duplicate deliveries
- slow WordPress REST
- bad mappings
- stale cache
- accidental client data exposure

Required protections:
- Oban queues
- idempotency
- cache invalidation
- rate limits
- audit logs
- admin alert screens
```

### Done When

```text
the system can be trusted during a real ticket sales period
```

---

# 9. Roadmap Order Summary

```text
0. Bootstrap and guardrails
1. Domain skeleton
2. Accounts/roles/access foundation
3. Catalog/events/ticket mappings
4. Sales orders/order items
5. Webhook security/intake
6. Idempotent webhook processing
7. WooCommerce order normalization
8. Mapping resolution/unmapped queue
9. Completed-only metrics/revenue rules
10. Admin dashboard
11. PubSub/cache updates
12. Event detail page
13. Webhook debug/replay UI
14. WooCommerce REST client
15. Reconciliation/sync runs
16. Product updated handling
17. CSV dry-run
18. CSV apply worker
19. Audit logging
20. PII masking/access safety
21. Event-scoped dashboard infrastructure
22. Exports
23. Protected Oban Web
24. Maintenance jobs
25. Full webhook-to-dashboard acceptance
26. Railway deployment/smoke test
27. Launch hardening
```

---

# 10. Critical Path

These slices must happen in this order:

```text
0 → 1 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 25
```

This is the minimum path to prove the product.

These can happen in parallel after the main resources exist:

```text
2 Accounts/roles
13 Webhook debug UI
14 REST client
17 CSV dry-run
19 Audit logging
20 PII masking
23 Oban Web
24 Maintenance jobs
```

Do not launch without:

```text
idempotency
completed-only metrics
mapping queue
admin dashboard
webhook log
manual reconciliation
policy tests
```

---

# 11. Minimum Launch Checklist

Before using EventSales for a real event, verify:

```text
[ ] Railway production deployment works.
[ ] Postgres migrations run successfully.
[ ] Redis connects successfully.
[ ] Oban is processing jobs.
[ ] WooCommerce webhook URL is correct.
[ ] Invalid webhook signatures are rejected.
[ ] Valid webhook is stored.
[ ] Duplicate webhook does not duplicate records.
[ ] Completed order counts as sold.
[ ] Pending/failed/cancelled/refunded orders do not count as sold.
[ ] Product mappings are configured.
[ ] Unmapped items are visible.
[ ] Dashboard loads from EventSales data only.
[ ] Manual refresh does not call WooCommerce.
[ ] REST reconciliation max concurrency is 2.
[ ] Manual sync is rate-limited and audited.
[ ] CSV dry-run works.
[ ] Oban Web is protected.
[ ] PII masking tests pass.
[ ] Raw webhook payload purge works.
[ ] Full end-to-end webhook-to-dashboard test passes.
```

---

# 12. What Success Looks Like

A good implementation will feel boring and reliable:

```text
A WooCommerce order comes in.
EventSales stores the raw webhook.
Oban processes it once, even if WooCommerce sends it twice.
Mapped ticket items update event and ticket totals.
Unmapped items are visible and do not corrupt metrics.
Completed orders count as sold.
Pending/failed/cancelled/refunded orders are visible but excluded from sold totals.
Admins can see dashboard, logs, sync status, and failed events.
Manual actions are rate-limited and audited.
WordPress is not queried by dashboard page loads.
REST reconciliation runs slowly and safely.
Railway deployment is repeatable.
Tests prove the important rules.
```

The main trap to avoid is building pretty dashboards before the ingestion, idempotency, mapping, and metric rules are trustworthy.

For this project, **correctness is the feature**.

