# EventSales — Hardened V2.1 Review and Corrections

This V2 pass hardens the remaining weak points found after reviewing the hardened pack:

1. **Phoenix/Ecto infrastructure made explicit**: `EventSales.Repo`, `EventSales.Release`, direct DB URL for migrations, pooled DB URL for app traffic, and PgBouncer-safe settings are now named.
2. **Oban + PgBouncer strategy clarified**: transaction pooling can break PostgreSQL `LISTEN/NOTIFY`; the docs now require an explicit notifier/pooling choice and tests for job execution under the chosen production topology.
3. **Webhook raw-body signature verification hardened**: WooCommerce HMAC verification must use the exact raw request body, not re-encoded JSON.
4. **Redis fallback durability clarified**: Redis buffer fallback is only allowed when its persistence/durability risk is explicit. Otherwise the endpoint must return non-2xx so WooCommerce retries.
5. **Out-of-order webhook handling hardened**: order updates must use source timestamps/hash/version guards so older payloads cannot overwrite newer state.
6. **Webhook replay and idempotency expanded**: delivery ID, resource ID, source updated timestamp, payload hash, and processing state are all part of the design.
7. **Rate limiting and backpressure made explicit**: separate webhook intake rate limiting, manual-action rate limiting, REST concurrency cap, and circuit-breaker behavior are named.
8. **Money/quantity invariants tightened**: order item quantity must be positive for sale line items; refunds/negative adjustments are not modeled as positive ticket sales in MVP.
9. **Cache and aggregate consistency tightened**: hot aggregate updates happen only after durable write commit; aggregate events require idempotency keys.
10. **Docs now warn against overusing PgBouncer transaction mode** for all workloads without considering Oban notifier/session requirements.

These V2 corrections override any earlier wording that is looser or ambiguous.


## V2.1 Final Hardening Corrections

This V2.1 pass is a cleanup pass, not a new architecture expansion. It hardens the coding-agent handoff by removing ambiguity and making the final launch-blocking rules explicit.

1. **WooCommerce REST boundary clarified**: controllers, LiveViews, components, and `MappingResolver` must never call WooCommerce REST. Only workers and approved ingestion service modules may use `WooCommerceClient`.
2. **OrderItem quantity rule corrected**: sale line items require `quantity > 0`; zero or negative quantities must be explicitly classified and must never count as sold tickets.
3. **ProductMapping uniqueness hardened**: nullable `woo_variation_id` requires partial unique indexes or an equivalent expression index to prevent duplicate product-level mappings.
4. **PaperTrail scope tightened**: use PaperTrail for mapping/access/config resources by default; defer PaperTrail on high-volume `Order`/`OrderItem` records for MVP unless a real audit requirement appears.
5. **Role scoping clarified**: `admin` and `staff` are global roles; `event_owner` and `event_staff` are event-scoped grants unless a future SaaS model explicitly changes this.
6. **Redis degraded-mode wording tightened**: return 2xx only after Postgres persistence or an explicitly enabled, bounded, monitored Redis fallback path whose risk has been accepted.
7. **Raw-body HMAC plug order made explicit**: raw-body capture must run before JSON body parsing; do not verify WooCommerce HMAC against decoded/re-encoded JSON.
8. **Single canonical critical path**: older critical path wording is removed; V2.1 uses only the corrected path.
9. **Business timezone and currency added**: `EVENTSALES_BUSINESS_TIMEZONE=Africa/Johannesburg` and `EVENTSALES_DEFAULT_CURRENCY=ZAR` are required runtime config items.
10. **Real payload fixture verification added**: sanitized real WooCommerce payloads must be captured and compared against fixtures before parser implementation.

---
# EventSales — Hardened V2.1 Vertical Slice Development Roadmap
# Hardened Weak Points

This pack hardens the previously identified weak points before coding starts.

## Hardened areas

1. **Domain dossiers expanded**: each resource now has module path, data layer, relationships, actions, validations, policies, indexes, state-machine guidance, PaperTrail usage, cache/PubSub triggers, and test requirements.
2. **Auth/web structure added**: AshAuthentication plumbing, auth controllers/live views/plugs, and current-user loading are explicitly represented.
3. **Phoenix config corrected**: `dev.exs`, `prod.exs`, `runtime.exs`, and `test.exs` are included.
4. **Fixture catalogue expanded**: mixed-event orders, non-ticket items, missing product recovery, product updates, variation updates, and CSV fixtures are included.
5. **Slice filenames cleaned**: generated slice docs avoid commas and shell-unfriendly punctuation.
6. **State-machine ownership clarified**: Slice 4.0 introduces sales statuses; Slice 8.6 hardens all state machines across ingestion, sync, CSV, and mapping.
7. **Missing doc skeletons included**: telemetry, historical reporting, PgBouncer, security, reconciliation, CSV import, smoke test, and incident runbooks are included as Markdown skeletons.
8. **Flash-sale intake hardened**: DB pool saturation, PgBouncer, optional Redis buffer fallback, and drainer behavior are explicitly planned.
9. **HotStateAggregator hardened**: Redis-first restore, warming state, async rebuild, anti-stampede lock, and telemetry are required.
10. **Ash ecosystem integrated**: AshAuthentication, AshAdmin, AshStateMachine, and AshPaperTrail are explicit baseline decisions.

## Ultimate goal

Build EventSales as a flash-sale-safe, observable, Ash-native, cache-aware reporting system for WooCommerce + Tickera. WooCommerce remains the sales engine; EventSales becomes the reporting, reconciliation, analytics, and admin visibility layer.

## MVP definition

The MVP is done when a completed WooCommerce order webhook is validated, durably accepted, processed by Oban, normalized into Ash/Postgres, mapped to the correct event/ticket type, counted under completed-only rules, reflected in hot dashboard state, visible in LiveView, observable through debug/sync screens, recoverable through replay/reconciliation, and protected by tests.

## Core architectural rules

# EventSales — Project-Wide Coding Agent Rules

## Non-negotiable architecture rules

- Build one vertical slice at a time.
- Do not implement business logic before its tests exist.
- Do not call WooCommerce REST from LiveView, components, controllers, or `MappingResolver`.
- Only Oban workers and approved ingestion service modules may call `WooCommerceClient`.
- The webhook controller may receive WooCommerce webhooks, but it must not call WooCommerce REST.
- Do not make Redis, ETS, or Cachex an Ash data layer.
- Postgres/AshPostgres is the durable source of truth.
- Redis, ETS, Cachex, and the HotStateAggregator are read models and hot/warm state only.
- Oban workers orchestrate async work; Ash actions own durable domain mutations.
- AshAdmin is internal protected visibility only, not the product UI.
- AshAuthentication is the default auth approach.
- AshStateMachine governs internal state transitions; external source sync must be explicit and auditable.
- AshPaperTrail tracks resource mutation history; `AuditLog` tracks operational/security actions.
- Dashboard refresh reads EventSales state only; manual refresh must never call WooCommerce.
- REST max concurrency to WooCommerce is 2.
- Required business config: `EVENTSALES_BUSINESS_TIMEZONE=Africa/Johannesburg` and `EVENTSALES_DEFAULT_CURRENCY=ZAR`.
- Return 2xx only if the webhook was persisted to Postgres, or if the explicitly enabled, bounded, monitored Redis degraded-mode buffer accepted it and its durability risk has been accepted. If neither condition is true, return non-2xx so WooCommerce retries.

## Canonical Critical Path

```text
Slice 0.0 — Project Bootstrap
→ Slice 0.2 — Repo, PgBouncer, Release, and DB Topology Baseline
→ Slice 0.4 — Ash Ecosystem Baseline
→ Slice 0.8 — Telemetry and Operational Metrics Foundation
→ Slice 1.0 — Domain Skeleton and Ash Boundaries
→ Slice 1.5 — End-to-End Acceptance Harness
→ Slice 1.6 — Real WooCommerce Payload Fixture Verification
→ Slice 2.0 — Authentication, Roles, and Event Access
→ Slice 3.0 — Catalog Resources and Product Mapping
→ Slice 4.0 — Sales Storage and Status State Machines
→ Slice 5.0 — Webhook Security and Intake
→ Slice 5.1 — Raw Body Signature and Replay Guard
→ Slice 5.5 — Flash-Sale Webhook Intake Protection
→ Slice 5.7 — Oban/PgBouncer Production Topology Smoke Test
→ Slice 6.0 — Idempotent and Out-of-Order Webhook Processing
→ Slice 7.0 — WooCommerce Order Normalization
→ Slice 7.5 — WooCommerce REST Client Boundary
→ Slice 8.0 — Mapping Resolution and Unmapped Queue
→ Slice 8.5 — Missing Catalog / Mapping Recovery Worker
→ Slice 8.6 — State Machine Hardening
→ Slice 8.8 — PaperTrail and Operational Audit Split
→ Slice 9.0 — Completed-Only Metric Rules
→ Slice 9.5 — HotStateAggregator GenServer
→ Slice 9.6 — HotStateAggregator Rebuild Safety
→ Slice 9.7 — Historical Reporting Snapshots / Materialized Views
→ Slice 10.0 — Admin Dashboard First Useful Version
→ Slice 11.0 — PubSub and Cache Integration
→ Slice 23.0 — Full Webhook-to-Dashboard Acceptance
→ Slice 24.0 — Railway Deployment and Production Smoke Test
→ Slice 25.0 — Launch Hardening
```

## Slice sequence

---

## Slice 0.0 — Project Bootstrap

### Goal
Create the clean Phoenix/Ash application foundation.

### Build
```text
Phoenix, Ash 3.x, AshPostgres, LiveView, Tailwind, Mishka Chelekom, Bandit, Oban, Postgres/Redis config, Railway runtime config, health route, test support.
```

### Strict tests
- Application boots in test
- Repo connects
- Redis config loads safely
- Oban starts in test mode
- Health route returns 200
- No secrets are hardcoded
- Runtime config reads env vars

### Guardrails / performance notes
No business logic. No WooCommerce calls. Config must include dev/prod/test/runtime.

---

## Slice 0.4 — Ash Ecosystem Baseline

### Goal
Install and prove Ash ecosystem dependencies that prevent reinventing infrastructure.

### Build
```text
ash_authentication, ash_authentication_phoenix if needed, ash_admin, ash_state_machine, ash_paper_trail.
```

### Strict tests
- Dependencies compile
- User resource can support AshAuthentication
- AshAdmin mounted behind protected/internal route
- AshStateMachine proven on sample/test resource
- AshPaperTrail proven on sample/test resource
- AshAdmin not publicly accessible

### Guardrails / performance notes
AshAdmin is not the product dashboard. Do not hand-roll auth.

---

## Slice 0.8 — Telemetry and Operational Metrics Foundation

### Goal
Add observability before ingestion gets complicated.

### Build
```text
EventSalesWeb.Telemetry, custom telemetry event names, webhook/REST/Oban/HotStateAggregator metric placeholders, docs.
```

### Strict tests
- Telemetry supervisor starts
- Custom telemetry event can be emitted and handled
- Webhook accepted/rejected counters defined
- REST latency/error telemetry defined
- Oban metrics documented

### Guardrails / performance notes
Metrics must exist before production debugging. No hard dependency on external SaaS metrics service.

---

## Slice 1.0 — Domain Skeleton and Ash Boundaries

### Goal
Create domain boundaries before implementation spreads across the app.

### Build
```text
Accounts, Catalog, Sales, Ingestion, Analytics, Audit domain modules and folders.
```

### Strict tests
- Each domain compiles
- Each domain is registered
- No resource in web layer
- No LiveView calls WooCommerce modules

### Guardrails / performance notes
Workers orchestrate; Ash actions own durable domain mutation.

---

## Slice 1.5 — End-to-End Acceptance Harness

### Goal
Create the failing/pending E2E test early to prevent architectural drift.

### Build
```text
Woo fixtures, webhook signing helper, Oban drain helper, mapping setup helper, E2E test skeleton.
```

### Strict tests
- E2E test describes valid webhook -> dashboard path
- Duplicate webhook expectation captured
- Pending order does not count as sold expectation captured
- Test can be tagged pending until implementation arrives

### Guardrails / performance notes
Do not wait until the end to write E2E intent.


---

## Slice 1.6 — Real WooCommerce Payload Fixture Verification

### Goal
Verify that sanitized real WooCommerce/Tickera payloads match the fixture shapes before implementing parsers and mapping logic.

### Build
```text
Sanitized real payload capture checklist
Fixture comparison notes
Fixture gap log
Parser assumptions document
```

### Strict Tests / Checks
- Capture or obtain sanitized real payloads for completed order, pending order, refunded order, mixed-event order, variation ticket order, non-ticket product order, product.updated, and variation updated.
- Compare each real payload against `test/fixtures/woocommerce/*`.
- Record every missing field, renamed field, nested metadata difference, Tickera-specific field, and plugin-specific payload shape.
- Do not implement final parser assumptions until fixture gaps are resolved or explicitly documented.
- Ensure fixtures contain no real customer data, production secrets, or live WordPress URLs.

### Guardrails / performance notes
Fixtures based on guesses are not good enough. Parser correctness depends on real WooCommerce/Tickera payload shape.

---

## Slice 2.0 — Authentication, Roles, and Event Access

### Goal
Create safe internal admin access and future event-scoped access.

### Build
```text
User, Role, UserRole, EventAccessGrant, AshAuthentication password strategy, role helpers, policies.
```

### Strict tests
- Admin can authenticate
- Unauthenticated rejected
- Admin accesses global admin
- Staff restricted
- Event owner only assigned event
- Event staff cannot see revenue by default
- Expired grants deny access

### Guardrails / performance notes
Auth must use AshAuthentication. Event scoping must live in policies, not routes.

---

## Slice 2.5 — Protected AshAdmin Internal Console

### Goal
Expose internal Ash resource visibility early, safely.

### Build
```text
AshAdmin route, admin-only protection, resource visibility settings.
```

### Strict tests
- Unauthenticated cannot access AshAdmin
- Non-admin cannot access AshAdmin
- Admin can access AshAdmin
- AshAdmin is not public/client UI

### Guardrails / performance notes
AshAdmin is a super-admin/debug tool only.

---

## Slice 3.0 — Catalog Resources and Product Mapping

### Goal
Model events, ticket types, and WooCommerce mappings.

### Build
```text
SourceSystem, Event, TicketType, ProductMapping, EventDashboardSetting.
```

### Strict tests
- Event belongs to SourceSystem
- TicketType belongs to Event
- ProductMapping supports product and optional variation
- Duplicate active mapping rejected
- Capacity may be nil
- Dashboard settings store revenue visibility

### Guardrails / performance notes
Mapping changes must enqueue recalculation and invalidate caches.

---

## Slice 4.0 — Sales Storage and Status State Machines

### Goal
Store normalized order and line-item data correctly and introduce sales state machines.

### Build
```text
Order, OrderItem, CouponSnapshot, Order status state machine, OrderItem mapping_status state machine.
```

### Strict tests
- Order unique by source + woo_order_id
- OrderItem unique by order + line item
- Quantity > 1 preserved
- Mixed-event orders supported
- Completed stored
- Other statuses visible but excluded
- Invalid internal transitions rejected
- External source sync can mirror newer Woo truth

### Guardrails / performance notes
Slice 4.0 owns initial sales state machines. Slice 8.6 later hardens all state machines across domains.

---

## Slice 5.0 — Webhook Security and Intake

### Goal
Receive WooCommerce webhooks safely and return quickly.

### Build
```text
WebhookSignature, WebhookEvent, WebhookController, WEBHOOK_PATH_TOKEN, Oban enqueue, invalid metadata logging.
```

### Strict tests
- Valid signature accepted
- Invalid signature rejected
- Wrong path token rejected
- Only POST accepted
- Valid webhook stores WebhookEvent
- Valid webhook enqueues Oban job
- Controller does not call REST
- No inline business processing
- Invalid payload does not store full body

### Guardrails / performance notes
Normal path: validate -> small durable insert -> enqueue -> return.

---

## Slice 5.5 — Flash-Sale Webhook Intake Protection

### Goal
Protect webhook intake during high-concurrency bursts.

### Build
```text
PgBouncer-safe notes, DB pool saturation handling, optional Redis buffer fallback, RedisWebhookBuffer, RedisWebhookBufferDrainer, backpressure telemetry.
```

### Strict tests
- Normal webhook persists to Postgres
- DB saturation + Redis fallback buffers payload
- Buffered payload later persists to Postgres
- If neither path accepts, return non-2xx
- Redis buffer bounded
- Drainer idempotent
- DB saturation does not crash app
- Backpressure telemetry emitted

### Guardrails / performance notes
Redis fallback is a degraded-mode safety valve, not canonical durable truth. Return 2xx only after Postgres persistence or after an explicitly enabled, bounded, monitored Redis fallback accepts the payload and its durability risk has been accepted.

---

## Slice 6.0 — Idempotent Webhook Processing

### Goal
Ensure duplicate webhook deliveries do not duplicate data.

### Build
```text
ProcessWebhookWorker, WebhookProcessor, delivery/resource/hash idempotency, statuses, retry with jitter.
```

### Strict tests
- Duplicate delivery_id no duplicates
- Same order.updated safe repeatedly
- Failed marks webhook failed
- Retry can succeed
- Unsupported topic handled safely
- Processing idempotent by source/resource/hash

### Guardrails / performance notes
Every external event must be replay-safe.

---

## Slice 7.0 — WooCommerce Order Normalization

### Goal
Parse realistic WooCommerce order payloads into internal order data.

### Build
```text
WooCommerceOrderParser, status mapper, line item parser, decimal parser, customer sanitizer, coupon parser, OrderUpserter.
```

### Strict tests
- Completed order parses
- Pending order parses
- Refunded/cancelled parses
- Quantity preserved
- Product/variation IDs preserved
- Line total after discount parsed
- Missing optional fields safe
- Malformed required fields controlled error

### Guardrails / performance notes
Parser tolerant, but never silently corrupts money/status.

---

## Slice 7.5 — WooCommerce REST Client Boundary

### Goal
Create a safe worker-only REST boundary before reconciliation and recovery.

### Build
```text
WooCommerceClient, WooCommerceError, order/product fetch, pagination, timeouts, typed errors, telemetry.
```

### Strict tests
- Fetch order by ID
- Fetch product by ID
- Handle 401/403/404/429/500/timeout
- Typed errors
- No LiveView calls client
- MappingResolver does not call client
- REST concurrency cap remains 2

### Guardrails / performance notes
Only workers may use this client.

---

## Slice 8.0 — Mapping Resolution and Unmapped Queue

### Goal
Resolve order items or mark them for recovery/unmapped handling.

### Build
```text
MappingResolver, OrderItemMapper, mapping_status, unmapped query, admin mapping queue.
```

### Strict tests
- Product-only mapping resolves
- Product + variation resolves
- Variation-specific wins
- Unknown becomes pending_mapping_resolution first
- Unmapped excluded from metrics
- Non-ticket excluded
- Mapping change enqueues recalculation

### Guardrails / performance notes
MappingResolver must not call WooCommerce REST.

---

## Slice 8.5 — Missing Catalog / Mapping Recovery Worker

### Goal
Handle webhook ordering races where order arrives before product metadata/mapping.

### Build
```text
MissingCatalogResolutionWorker, MissingCatalogResolver, ProductMetadataCache, metadata fetch via client, remap retry, fallback unmapped.
```

### Strict tests
- Unknown product creates pending item
- Worker fetches metadata through client
- Worker respects REST cap
- Metadata cached
- Affected item remapped
- Still missing becomes unmapped
- Duplicate recovery jobs safe

### Guardrails / performance notes
Queued, bounded, idempotent, observable.

---

## Slice 8.6 — State Machine Hardening

### Goal
Apply and harden AshStateMachine across resources with status lifecycles.

### Build
```text
WebhookEvent.status, Order.status, OrderItem.mapping_status, SyncRun.status, CsvImportBatch.status.
```

### Strict tests
- Invalid internal transitions rejected
- Webhook processed cannot move to received internally
- OrderItem mapped cannot move pending without remap action
- SyncRun cannot complete before running
- CSV cannot apply before dry-run success
- External source sync explicit and audited

### Guardrails / performance notes
Clarifies and completes state machines beyond sales storage.

---

## Slice 8.8 — PaperTrail and Operational Audit Split

### Goal
Separate resource version history from operational audit events.

### Build
```text
AshPaperTrail on selected resources, AuditLog resource, Audit.Logger.
```

### Strict tests
- ProductMapping change creates version
- EventAccessGrant change creates version
- Manual sync writes AuditLog
- Webhook replay writes AuditLog
- CSV apply writes AuditLog
- No secrets/full raw payload in audit metadata

### Guardrails / performance notes
PaperTrail is not a replacement for operational audit events.

---

## Slice 9.0 — Completed-Only Metric Rules

### Goal
Make sales math deterministic.

### Build
```text
MetricRules, completed-only sold/revenue, status breakdown, today vs total, timezone.
```

### Strict tests
- Completed counts sold
- Pending/processing/failed/cancelled/refunded not sold
- Refunded visible but excluded MVP revenue
- Revenue uses completed ticket line total after discounts
- Unmapped/non-ticket not counted
- Today respects timezone

### Guardrails / performance notes
Pure functions first; no dashboard shortcut math.

---

## Slice 9.5 — HotStateAggregator GenServer

### Goal
Create supervised hot-state process for dashboard counters.

### Build
```text
HotStateAggregator, AggregateEvent, DashboardCache, CacheKeys, ETS/Cachex write, Redis snapshot write, PubSub trigger.
```

### Strict tests
- Starts under supervision
- Accepts normalized order-change event
- Updates event/ticket/today totals
- Writes hot cache
- Writes Redis warm snapshot
- Broadcasts PubSub
- Duplicate aggregate event no double count
- Not durable truth

### Guardrails / performance notes
Postgres commit first, then hot update. No compensating hot-first totals.

---

## Slice 9.6 — HotStateAggregator Rebuild Safety

### Goal
Prevent cache stampede and blocking boot after restart/crash.

### Build
```text
Warming state, Redis-first restore, async Postgres rebuild, anti-stampede lock, bounded rebuild worker, telemetry.
```

### Strict tests
- Starts warming
- Redis snapshot restores quickly
- Missing Redis schedules async rebuild
- GenServer init no heavy query
- Only one rebuild runs
- Dashboard shows warming/stale safely
- Rebuild telemetry emitted

### Guardrails / performance notes
Never run heavy aggregate queries in GenServer init.

---

## Slice 9.7 — Historical Reporting Snapshots / Materialized Views

### Goal
Prevent long-term reports from repeatedly scanning order_items.

### Build
```text
EventAggregateSnapshot, DailySalesAggregateSnapshot, materialized view strategy docs, refresh worker, indexes.
```

### Strict tests
- Dashboard no full order_items scan on mount
- Snapshot refresh idempotent
- Refresh scoped by event/date
- Snapshot query returns expected totals
- Refresh invalidates relevant cache

### Guardrails / performance notes
Historical reporting path planned before data grows.

---

## Slice 10.0 — Admin Dashboard First Useful Version

### Goal
Give internal admins a useful dashboard from EventSales data only.

### Build
```text
/admin/dashboard, KPI cards, tickets/revenue/statuses/by event/by type, recent orders, alerts, manual refresh.
```

### Strict tests
- Admin can view
- Unauthenticated cannot
- Completed tickets/revenue rendered
- Statuses rendered
- Unmapped alerts rendered
- Manual refresh does not call Woo
- Manual refresh rate-limited

### Guardrails / performance notes
Dashboard reads cache/Postgres only.

---

## Slice 11.0 — PubSub and Cache Integration

### Goal
Update dashboard after processed orders without polling.

### Build
```text
PubSub topics, LiveView subscriptions, cache invalidation, handle_info updates, manual fallback.
```

### Strict tests
- Processed order invalidates cache
- Processed order broadcasts update
- Dashboard receives PubSub
- Assigns update without reload
- Manual refresh fallback
- Cache keys include event scope

### Guardrails / performance notes
No polling. No WooCommerce calls.

---

## Slice 12.0 — Event Detail Page

### Goal
Give admins a per-event sales view.

### Build
```text
/admin/events, /admin/events/:id, capacity, sold/remaining, type/status breakdown, recent orders, unmapped items, export/import buttons.
```

### Strict tests
- Admin event list/detail
- Nil capacity safe
- Remaining count with capacity
- Mixed-event orders filtered
- Unmapped visible
- Event policy enforced

### Guardrails / performance notes
Paginate/stream rows. Do not load all order items.

---

## Slice 13.0 — Webhook Debug and Replay UI

### Goal
Make webhook ingestion observable and recoverable.

### Build
```text
/admin/webhooks, filters, failed replay, metadata, raw payload admin-only, confirmation, audit.
```

### Strict tests
- Admin can view log
- List paginated/streamed
- Failed replay enqueues job
- Replay requires confirmation
- Replay rate-limited
- Replay audited
- Non-admin no raw payload

### Guardrails / performance notes
Raw payload handling must be explicit and admin-only.

---

## Slice 14.0 — Reconciliation and Sync Runs

### Goal
Catch missed/changed WooCommerce orders without hurting WordPress.

### Build
```text
SyncRun, SyncCursor, ReconcileOrdersWorker, scoped sync, shallow/deep sync, pause behavior, sync UI.
```

### Strict tests
- Manual sync requires event/date scope
- Cursor stored/resumed
- Modified orders only
- REST concurrency max 2
- Pause on 429/timeouts/500s
- Counts/failures recorded
- Confirmation/rate limit/audit

### Guardrails / performance notes
Never full-scan during peak.

---

## Slice 15.0 — Product Updated Handling

### Goal
Use product updates to improve metadata without corrupting history.

### Build
```text
product.updated handler, ProductMetadataUpdater, label update, unknown alert, cache invalidation.
```

### Strict tests
- Known product refreshes current label
- Original order item label unchanged
- Unknown product alert/ignored status
- No revenue recalc unless mapping changed
- Worker idempotent
- Controller no inline REST

### Guardrails / performance notes
Product updates are metadata, not sales truth.

---

## Slice 16.0 — CSV Import Dry-Run

### Goal
Allow safe event-scoped CSV validation before mutation.

### Build
```text
CsvImportBatch, CsvImportRow, CSV parser, dry-run validator, errors, duplicate preview, admin screen.
```

### Strict tests
- Requires event scope
- Missing columns fail
- Invalid money/quantity fail
- Unknown mapping fails
- Duplicate detected
- Large CSV streamed/chunked
- Dry-run no sales mutation
- Non-admin denied

### Guardrails / performance notes
Dry-run before apply. No automatic event/ticket creation in MVP.

---

## Slice 17.0 — CSV Apply Worker

### Goal
Apply validated CSV imports asynchronously and audibly.

### Build
```text
ProcessCsvImportWorker, ApplyImport, idempotent upsert, row statuses, cache invalidation, audit.
```

### Strict tests
- Only valid dry-run applies
- Runs through Oban
- Idempotent
- Duplicates no double-count
- Updates aggregates
- Invalidates cache
- Writes audit
- Retry safe

### Guardrails / performance notes
CSV uses same domain rules as webhook/reconciliation.

---

## Slice 18.0 — Exports

### Goal
Allow admins to export event sales summaries.

### Build
```text
Event summary CSV, order list CSV, PII-aware policy, streamed response, audit.
```

### Strict tests
- Admin exports summary/list
- Event scope respected
- PII policy respected
- Unmapped excluded from metrics
- Large export streamed/paginated
- Audit written

### Guardrails / performance notes
Do not load entire export into memory.

---

## Slice 19.0 — PII Masking and Access Safety

### Goal
Prevent accidental customer-data exposure.

### Build
```text
PIIPolicy, CustomerPresenter, role-based masking, export rules, admin/client component separation.
```

### Strict tests
- Admin sees full email
- Staff configured/masked
- Event owner no email by default
- Event staff no email
- Aggregates no PII
- Raw payload admin-only
- Exports respect PII

### Guardrails / performance notes
Do not reuse admin components in client dashboard later.

---

## Slice 20.0 — Event-Scoped Dashboard Infrastructure

### Goal
Prepare future client dashboards without launching them.

### Build
```text
EventDashboardSetting, EventAccessGrant hardening, visibility settings, aggregate-only query path, token placeholder if needed.
```

### Strict tests
- Event owner assigned aggregate access
- Unassigned denied
- Event staff no revenue by default
- Revenue setting controls access
- Expired grant denied
- Aggregate path excludes PII

### Guardrails / performance notes
Build infrastructure only, not client portal UI.

---

## Slice 21.0 — Protected Oban Web

### Goal
Expose job visibility safely.

### Build
```text
Oban Web route, admin-only protection, optional basic auth/IP restriction, job visibility.
```

### Strict tests
- Unauthenticated denied
- Non-admin denied
- Admin allowed
- Not mounted publicly by accident

### Guardrails / performance notes
Operational controls must not be public.

---

## Slice 22.0 — Maintenance Jobs

### Goal
Keep system healthy over time.

### Build
```text
PurgeRawPayloadsWorker, cache cleanup, stale sync cleanup, failed job alert foundation.
```

### Strict tests
- Payload older than 90 days purged/redacted
- Recent payload kept
- Normalized orders not deleted
- Purge idempotent
- Maintenance telemetry emitted

### Guardrails / performance notes
Purge raw payload only, not sales truth.

---

## Slice 23.0 — Full Webhook-to-Dashboard Acceptance

### Goal
Prove the MVP core value end-to-end.

### Build
```text
Final E2E acceptance: webhook, Oban, upsert, mapping, aggregate, dashboard, duplicate check.
```

### Strict tests
- Completed webhook returns 2xx
- WebhookEvent stored
- Oban processes
- Order/Item created
- Item maps
- Tickets/revenue increment
- Dashboard renders
- Duplicate no total change
- Pending same order not sold
- Completed update counts once

### Guardrails / performance notes
This is the final green version of Slice 1.5 intent.

---

## Slice 24.0 — Railway Deployment and Production Smoke Test

### Goal
Deploy to Railway and prove production behavior.

### Build
```text
Railway config, Postgres/Redis, PgBouncer notes, env vars, health, migrations, Oban, webhook URL, smoke runbook.
```

### Strict tests
- Railway build succeeds
- Migrations run
- Health passes
- Postgres/Redis connect
- Oban starts
- Webhook HTTPS reachable
- Invalid rejected
- Valid test stored
- Admin dashboard accessible
- Oban Web protected

### Guardrails / performance notes
Railway is primary. VPS/systemd/Nginx not primary path.

---

## Slice 25.0 — Launch Hardening

### Goal
Make EventSales trustworthy during a real sales period.

### Build
```text
Launch checklist, incident/reconciliation/CSV/security runbooks, burst test, mapping review, alert thresholds.
```

### Strict tests
- Webhook burst no duplicates
- REST cap never exceeds 2
- Manual sync rate limit
- Large CSV test
- Policy/PII tests pass
- Cache invalidation works
- Replay works
- Payload purge works
- HotState rebuild safe
- Telemetry emits critical events

### Guardrails / performance notes
Do not launch before this passes.

---

## Non-negotiable launch tests

```text
[ ] invalid webhook signatures are rejected
[ ] duplicate webhooks do not duplicate orders/items/totals
[ ] completed-only sold/revenue rules pass
[ ] pending/failed/cancelled/refunded are visible but excluded from MVP totals
[ ] mixed-event orders split by line item
[ ] unmapped items do not affect ticket metrics
[ ] missing catalog recovery works
[ ] REST concurrency max is 2
[ ] DB saturation fallback behavior is tested
[ ] Redis fallback does not pretend to be canonical truth
[ ] HotStateAggregator rebuild does not block boot
[ ] cache invalidation works
[ ] Ash policies enforce event access
[ ] PII masking works
[ ] manual sync/replay/import/export are audited
[ ] PaperTrail versions important resource mutations
[ ] dashboard never calls WooCommerce directly
[ ] full webhook-to-dashboard E2E test passes
```


# V2.1 Hardening Addendum — Required Before Slice 0 Starts

## New Non-Negotiable Rules

```text
Webhook signature verification must use the raw request body.
WebhookController must not call WooCommerce REST.
No controller may call WooCommerce REST.
MappingResolver must remain pure/local and must not call WooCommerce REST.
Hot aggregate updates happen only after the durable write commits.
Redis webhook buffering is optional and must be explicitly configured as a degraded-mode safety valve.
If neither Postgres nor the explicitly enabled, bounded, monitored Redis degraded-mode buffer accepts a webhook, return non-2xx so WooCommerce retries.
PgBouncer transaction mode requires explicit compatibility settings and tests.
Oban must be tested under the chosen production DB/pooler/notifier topology.
```

---

## Slice 0.2 — Repo, PgBouncer, Release, and DB Topology Baseline

### Goal
Make the production database topology explicit before any Ash resources, Oban jobs, or Railway deployment work depends on it.

### Build
```text
EventSales.Repo
EventSales.Release
DATABASE_URL pooled/app connection path
DIRECT_DATABASE_URL direct migration/session path
PgBouncer-safe Repo config option
Oban DB/notifier topology decision
Railway migration command documentation
EVENTSALES_BUSINESS_TIMEZONE
EVENTSALES_DEFAULT_CURRENCY
```

### Strict Tests
```text
Repo compiles and starts in test.
Runtime config supports DATABASE_URL.
Runtime config supports DIRECT_DATABASE_URL for migrations if provided.
Release migration module can run migrations with the direct URL path.
PgBouncer mode setting is documented and does not silently enable unsafe defaults.
Oban starts and executes a test job under test configuration.
```

### Guardrails
```text
Do not assume transaction pooling is safe for every workload.
If PgBouncer transaction pooling is used, configure the Repo accordingly and test Oban behavior.
Use the direct database connection for migrations and other session-sensitive operations.
Do not run long aggregate rebuilds inside normal request DB transactions.
```

---

## Slice 5.1 — Raw Body Signature and Replay Guard

### Goal
Ensure webhook security uses the exact raw request body and rejects/flags suspicious replay patterns.

### Build
```text
RawBodyReader plug/helper
WebhookSignature verifier using raw body bytes
WebhookReplayGuard
sanitized headers snapshot
signature failure logging without raw payload
```

### Strict Tests
```text
Valid HMAC over raw body passes.
Same JSON re-encoded in a different key order does not falsely pass unless raw bytes match.
Missing signature is rejected.
Wrong signature is rejected.
Wrong path token is rejected.
Duplicate delivery ID is accepted idempotently, not reprocessed twice.
Suspicious stale replay is logged with metadata only.
Invalid request never stores full raw body.
```

### Guardrails
```text
RawBodyReader must run before JSON body parsing.
Do not rely on `conn.body_params` for HMAC verification.
Do not verify signatures against decoded/re-encoded JSON.
Store raw body only after signature validation succeeds.
Do not log secrets, authorization headers, or full invalid payloads.
```

---

## Slice 5.7 — Oban/PgBouncer Production Topology Smoke Test

### Goal
Prove background jobs work under the selected Railway/Postgres/PgBouncer setup before real ingestion depends on them.

### Build
```text
Production topology runbook
Oban notifier choice documentation
Queue execution smoke test
PgBouncer compatibility test notes
Fallback polling/notifier strategy if transaction pooling is used
```

### Strict Tests
```text
A test Oban job enqueues and executes in production-like config.
Queue scaling/retry behavior is observed or documented under the chosen notifier.
The app does not rely on LISTEN/NOTIFY through transaction pooling unless the notifier supports it.
Migrations run through direct DB URL or documented safe path.
```

### Guardrails
```text
Do not assume Oban notifications work through PgBouncer transaction pooling.
Do not use a pooled transaction URL for session-sensitive migration/maintenance tasks without testing.
```

---

## Slice 6.0 V2 Changes — Idempotent and Out-of-Order Webhook Processing

Add these tests to Slice 6.0:

```text
Older order.updated payload cannot overwrite newer source state.
order.created arriving after order.updated does not regress status or totals.
Payload hash prevents duplicate processing when delivery IDs differ.
Same Woo order with newer updated_at updates existing order once.
Same Woo order with older updated_at is ignored or stored as stale according to policy.
```

Add these fields to the relevant resource dossiers:

```text
orders.last_source_payload_hash
orders.last_webhook_event_id
orders.last_source_updated_at
webhook_events.source_updated_at where available
webhook_events.accepted_via enum postgres/redis_buffer
webhook_events.raw_body_size
webhook_events.signature_validated_at
```

---

## Slice 9.5 V2 Changes — Aggregate Event Idempotency

Every aggregate mutation event must include:

```text
aggregate_event_id
source_system_id
order_id
order_item_id where applicable
event_id
ticket_type_id
status_before/status_after where applicable
quantity_delta
revenue_delta
source_updated_at
payload_hash
```

Strict tests:

```text
Same aggregate_event_id does not double-apply.
Out-of-order stale aggregate event is ignored.
Rebuild from Postgres produces same totals as event stream.
Hot totals are updated only after durable write commit.
```

---

## V2 Launch Blockers

Do not launch unless these are true:

```text
[ ] raw-body webhook signature tests pass
[ ] raw-body reader runs before JSON body parsing
[ ] Oban execution works under selected production DB topology
[ ] PgBouncer mode and Ecto/Oban compatibility are documented
[ ] direct DB URL migration path is documented/tested
[ ] Redis fallback behavior is explicitly enabled or disabled
[ ] stale/out-of-order webhook tests pass
[ ] ProductMapping partial unique indexes prevent duplicate NULL-variation mappings
[ ] real sanitized WooCommerce/Tickera payload verification is complete
[ ] aggregate event idempotency tests pass
[ ] dashboard never calls WooCommerce REST
```
