# EventSales Live Sales Programme

## Purpose

This programme turns the existing EventSales foundation into the operational product required by management and marketing:

```text
Tickera/WooCommerce catalog changes
-> EventSales discovers and safely creates or updates local catalog records
-> WooCommerce order webhooks update EventSales within seconds
-> REST catch-up repairs missed webhook gaps
-> durable Postgres sales truth feeds event-scoped aggregates
-> LiveView pages update through PubSub
-> management and marketing can inspect current event performance
-> historical backfill, imports, exports, and reconciliation remain available
```

The programme is deliberately divided into small vertical slices. Only one slice may be active at a time. Every slice receives a repository-specific feature pack before implementation begins.

## Canonical Repository Rules

Every slice must follow:

- `AGENTS.md`
- `docs/agent/01_PROJECT_WIDE_RULES.md`
- `docs/EventSales_Hardened_V2_1_Vertical_Slice_Roadmap.md`
- `docs/EventSales_Hardened_V2_1_Folder_Structure.md`
- `docs/EventSales_Hardened_V2_1_Domain_Mapping_Ash_Resource_Dossiers.md`

Non-negotiable programme rules:

1. Build one vertical slice at a time.
2. Write or adjust tests before business logic.
3. Postgres/AshPostgres remains durable truth.
4. Redis, ETS, Cachex, and `HotStateAggregator` remain read models only.
5. LiveView, components, controllers, and `MappingResolver` must not call WooCommerce REST.
6. Only approved ingestion services and Oban workers may call `WooCommerceClient`.
7. Durable domain mutations belong in Ash actions or explicit domain services, not LiveViews.
8. Webhook processing must remain idempotent and source-version guarded.
9. Existing payment, scanner, ticket issuance, refund, revocation, PDF, wallet, and delivery authority is out of scope unless a slice explicitly owns it.
10. No customer PII, secrets, tokens, raw provider payloads, or production values may enter code, fixtures, logs, docs, prompts, or evidence.
11. No feature is complete at merge. The slice closes only after its required production validation is recorded.

## Current Repository Baseline

The programme starts from an already substantial foundation.

### Catalog foundation already present

- Sanitized WordPress/Tickera catalog feed plugin.
- Signed EventSales feed client and discovery adapter.
- Dry-run planning and immutable plan snapshots.
- Findings, review UI, exact-hash Apply gate, revocation, and manual mapping workflows.
- Generation-fenced Discovery ownership and retry lifecycle.
- Atomic queued run plus real Oban job persistence.
- Safe finding replacement and durable readiness.
- One queue-blocking catalog run per source system.
- Event lifecycle metadata, ticket naming guardrails, and mapping conflict review.

### Sales ingestion already present

- Exact raw-body WooCommerce webhook signature verification.
- Durable webhook event persistence before async processing.
- Duplicate delivery and stale source-version protection.
- Oban-backed order processing.
- `order.created`, `order.updated`, and `product.updated` handling.
- Existing `OrderUpserter` as the normalized order/order-item write boundary.
- Completed-only ticket and revenue metric rules.
- Unmapped-item queue and reviewed recovery workflows.

### Analytics and UI already present

- Event and daily aggregate snapshots.
- ETS/Redis-backed hot and warm read models.
- Event-scoped PubSub updates after durable order writes.
- Admin dashboard and event detail pages.
- Current/past event views.
- Total sold, revenue, capacity, remaining, ticket-type breakdown, recent orders, and unmapped items.
- Existing CSV import dry-run/apply and event exports.
- Event-scoped authorization and revenue-visibility policy foundations.

### Important gaps remaining

- A newly created or published Tickera event is not yet automatically applied into EventSales.
- Catalog automation is not yet scheduled or event-triggered.
- Webhooks remain the primary order path without an automatic updated-since REST repair cursor.
- The event detail page lacks decision-grade time windows such as last hour, rolling comparisons, and real chart buckets.
- Management/marketing access is not yet delivered as the final safe event-scoped product surface.
- The placeholder `BackfillOrdersWorker` does not yet provide historical REST backfill.
- Routine and historical exports do not yet cover all planned time-window and filtered decision views.
- The compact source-shaped webhook contract remains open hardening work.

## Programme Outcome

The programme is complete when all of the following are true:

1. A safe newly published Tickera event and its ticket products appear automatically in EventSales without manual JSON or database exports.
2. Risky catalog changes stop for review rather than being silently applied.
3. Order creation and updates normally reach EventSales through webhooks within seconds.
4. Missed webhook updates are repaired automatically through a durable WooCommerce REST cursor.
5. Replaying, catching up, or backfilling never duplicates orders or order items.
6. Each event has a decision-grade page showing current totals, recent velocity, comparisons, ticket types, statuses, campaigns/coupons where supported, freshness, and operational warnings.
7. Management and marketing see only the event data and revenue allowed by policy, without customer PII.
8. Large historical backfills run through bounded Oban work with durable progress.
9. Imports and exports are reviewable, auditable, bounded, and event-scoped.
10. Operational freshness and source watermarks make stale data visible rather than presenting it as current.

## Ordered Vertical Slices

### Phase 0 — Establish the certified production baseline

#### VS-26E.0 — Catalog Lifecycle Deployment and Baseline Certification

**Outcome:** Deploy the merged catalog lifecycle safely, run the required migrations, execute one controlled authoritative full-feed dry-run, review its exact hash/findings, and establish a certified catalog baseline.

**Why first:** Automatic catalog work must not begin on an unknown or unvalidated production baseline.

**Primary deliverables:**

- Deployment and migration runbook.
- Read-only preflight checks.
- Controlled queueing instructions.
- Exact-hash review checklist.
- Sanitized evidence template.
- Rollback/stop conditions.
- Production baseline sign-off.

**Likely repository scope:**

- `docs/ops/`
- `docs/roadmap/`
- existing production smoke/cutover scripts only when a missing safe check is proven

**Must not:**

- Change catalog semantics.
- Auto-apply anything.
- modify production mappings or orders outside the exact approved Apply.
- cancel/edit production Oban jobs casually.
- run broad historical corrections.

**Exit gate:** Production catalog lifecycle is deployed, migration/index state is verified, one authoritative baseline has an approved result, and no unresolved blocker remains.

---

### Phase 1 — Automatic catalog creation and maintenance

#### VS-26E.1 — Targeted WordPress Catalog Change Trigger

**Outcome:** A catalog change in WordPress/Tickera produces a small authenticated notification that queues a targeted EventSales catalog discovery.

**Expected trigger coverage:**

- Tickera event created or updated.
- Ticket product created or updated.
- Ticket variation created or updated.
- Publication/private/draft status changed.
- Product-to-event relationship changed.

**Design constraints:**

- The notification is a trigger, not catalog authority.
- EventSales still fetches the authoritative sanitized catalog feed.
- No full catalog payload is pushed through the notification.
- Trigger delivery must be idempotent and bounded.
- WordPress save hooks must not block on a long EventSales operation.
- EventSales queues Oban work; it does not perform discovery inline in the HTTP request.
- Existing full/product/event/updated-since feed scopes should be reused.

**Likely files:**

- `integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php`
- plugin README and catalog feed docs
- a dedicated EventSales trigger controller/intake boundary
- catalog sync queue facade and worker tests
- router/runtime config only when required

**Out of scope:**

- Auto-apply policy.
- Scheduled reconciliation.
- Order webhooks.
- Woo order catch-up.
- Dashboard redesign.

**Exit gate:** A safe targeted notification creates at most one appropriate active discovery run, duplicate notifications are harmless, and no catalog mutation occurs without the existing dry-run/apply machinery.

#### VS-26E.2 — Conservative Catalog Auto-Apply

**Outcome:** Low-risk additive catalog changes apply automatically; ambiguous, risky, destructive, private, draft, subscription, payment-plan, or conflicting changes remain review-only.

**Auto-apply candidates:**

- New published Tickera event.
- New published simple ticket product.
- New unambiguous published variation.
- New ticket type with deterministic identity/name.
- Conflict-free ProductMapping creation.
- Safe additive metadata changes explicitly approved by policy.

**Must require review:**

- Blocking or review-required findings.
- Product/event moves.
- Duplicate or stale mapping conflicts.
- Private/draft records.
- Payment-plan, subscription, membership, add-on, bundle, or unknown semantics.
- Ambiguous ticket naming.
- Destructive deactivation or historical-impact changes.

**Likely files:**

- `lib/event_sales/catalog/tickera_catalog/auto_apply_policy.ex`
- `lib/event_sales/ingestion/tickera_catalog_auto_sync.ex`
- catalog worker/facade and LiveView status rendering
- policy, worker, and end-to-end tests

**Out of scope:**

- Changing Apply authority or exact-hash validation.
- Editing historical mapped OrderItems.
- Product semantics reclassification.
- Recurring scheduling.

**Exit gate:** Policy tests prove safe additive changes auto-apply and every risky category stops for human review.

#### VS-26E.3 — Periodic Catalog Reconciliation Sweep

**Outcome:** A durable periodic updated-since sweep catches missed catalog triggers without stampeding WordPress or overlapping active catalog runs.

**Initial operating target:**

- Trigger-driven discovery normally within two minutes.
- Reconciliation recovery within fifteen minutes.
- One active catalog run per source remains enforced.

**Required behavior:**

- Durable per-source watermark.
- Bounded scheduled Oban worker.
- Updated-since feed query.
- Uniqueness and queue-exclusivity integration.
- Safe retry lifecycle.
- Admin visibility for last successful sweep, next/active state, and bounded errors.

**Out of scope:**

- WooCommerce order catch-up.
- Full-feed scans every few minutes.
- Redis as catalog truth.
- Applying risky findings.

**Exit gate:** A missed targeted trigger is recovered by the sweep and repeated schedules remain idempotent and source-safe.

---

### Phase 2 — Reliable near-live order truth

#### VS-26F.1 — WooCommerce Order Catch-Up Core

**Maps to:** Existing issue `#80`.

**Outcome:** A durable updated-since cursor fetches missed or changed WooCommerce orders and routes every payload through the existing parser and `OrderUpserter` rather than creating a parallel sales writer.

**Required behavior:**

- Cursor per source system.
- Safe initial lookback.
- Bounded page size and REST concurrency maximum of two.
- Cursor advances only after successful processing.
- Stale source updates cannot overwrite newer local truth.
- Retries and repeated runs remain idempotent.
- Pending mappings remain pending rather than triggering catalog calls inline.
- Safe progress and bounded error codes.

**Likely files:**

- `lib/event_sales/ingestion/woo_order_catch_up.ex`
- `lib/event_sales/ingestion/workers/woo_order_catch_up_worker.ex`
- `lib/event_sales/ingestion/resources/woo_order_sync_cursor.ex`
- existing `WooCommerceClient`
- migration, resource, facade, and worker tests

**Out of scope:**

- Webhook intake behavior changes.
- New sales persistence path.
- Dashboard aggregate redesign.
- Historical multi-year backfill UX.

**Exit gate:** A missed update is repaired through REST, cursor advancement is crash-safe, and no duplicate order/item is created.

#### VS-26F.2 — Scheduled Catch-Up and Admin Operations

**Outcome:** The core cursor runs automatically on a conservative cadence and can be observed or manually requested safely by an administrator.

**Required behavior:**

- Periodic Oban schedule, initially around five minutes unless production evidence requires another cadence.
- One active catch-up run per source.
- Manual queue action with rate limit and active-run protection.
- Last successful cursor, active state, processed counts, lag, and safe error display.
- PubSub-driven status where appropriate; no LiveView polling loop.

**Out of scope:**

- Large historical backfill.
- Customer/order PII in status screens.
- Raw REST payload display.

**Exit gate:** Routine missed webhooks recover automatically and operators can see whether the source is current.

---

### Phase 3 — Correct business semantics before richer reporting

#### VS-26G — Ticket, Payment-Plan, Membership, Add-On, and Renewal Semantics

**Maps to:** Existing issue `#82`.

**Outcome:** Explicitly classify which products and order lines count as event tickets and revenue, preventing memberships, renewals, payment plans, and unrelated products from inflating event sales.

**Required decisions:**

- Ticket-count treatment for payment-plan initial checkout.
- Revenue treatment for later instalments/renewals.
- Membership/subscription reporting boundary.
- Add-on and bundle semantics.
- Historical data migration/reclassification policy.
- Dashboard and export inclusion rules.

**Conservative default:** Unknown or risky products do not count as tickets until reviewed.

**Out of scope:**

- Silent historical reclassification.
- Payment authority changes.
- Subscription billing implementation.

**Exit gate:** Metric rules and tests make ticket and revenue inclusion explicit before decision-grade analytics are expanded.

---

### Phase 4 — Decision-grade aggregates and event reporting

#### VS-27B.1 — Event Sales Metric and Time-Window Contract

**Outcome:** Define the exact business contract for totals and comparisons before building new tables or UI.

**Contract must define:**

- Total sold and revenue.
- Last 15, 30, and 60 minutes.
- Today and yesterday in `Africa/Johannesburg`.
- Rolling 7-day and selected-range totals.
- Current period versus previous equivalent period.
- Completed, pending, on-hold, cancelled, refunded, and failed display semantics.
- Refund/cancellation treatment.
- Ticket-type, product/variation, coupon, and campaign dimensions supported in v1.
- Source watermark, freshness, partial-data, and stale-data semantics.
- Revenue visibility and PII exclusion.

**This is a contract/planning slice:** Do not build the final UI or a new aggregate engine until the contract is accepted.

**Exit gate:** A reviewed document and contract tests define every metric displayed to management and marketing.

#### VS-27B.2 — Durable Hourly and Daily Event Sales Buckets

**Outcome:** Add bounded durable aggregate buckets that support time-window reporting without repeatedly scanning raw sales rows from LiveView.

**Expected dimensions:**

- Event.
- Business date/hour.
- Ticket type where required.
- Order-status contribution.
- Currency.
- Optional coupon/campaign dimension only when cardinality and source truth are proven.

**Rules:**

- Aggregate only after durable order writes.
- Updates must be idempotent under webhook retry and order update.
- Changed/refunded/cancelled orders must recompute affected buckets correctly.
- Postgres remains authoritative; hot caches mirror aggregate rows.
- Rebuild/backfill capability must exist for selected events/ranges.

**Out of scope:**

- Final dashboard layout.
- Arbitrary analytics warehouse.
- Unbounded dimensions.

**Exit gate:** Tests prove real-time update, correction, rebuild, and comparison accuracy across order lifecycle changes.

#### VS-27B.3 — Event Sales Decision Dashboard

**Outcome:** Enhance the event page into the primary decision surface for management and marketing.

**Required sections:**

- Total sold and revenue.
- Last hour sold/revenue.
- Today and yesterday.
- Rolling/selected period comparison.
- Sales velocity.
- Hourly/daily trend chart.
- Ticket-type performance.
- Order-status, refund, and cancellation context.
- Coupon/campaign performance where supported.
- Recent order activity without default PII exposure.
- Unmapped/partial-data warnings.
- Source watermark and last-updated state.

**Required filters:**

- Preset and custom date/time range.
- Ticket type.
- Order status.
- Coupon/campaign where supported.
- Product/variation where useful.
- Mapped/unmapped state for operational review.

**UI rules:**

- Phoenix LiveView, Tailwind v4, vendored DaisyUI, Mishka hooks, and existing Chart.js pattern only.
- No Woo/Tickera calls from UI.
- No raw sales table scans from components.
- PubSub updates only affected event data.

**Exit gate:** An authorized user can keep the event page open and see safe, fresh, decision-useful updates after new sales arrive.

---

### Phase 5 — Management and marketing product access

#### VS-27C — Event-Scoped Management and Marketing Dashboard Access

**Outcome:** Deliver the decision dashboard through event-scoped authorization rather than requiring global-admin access.

**Role intent:**

- Management: tickets, revenue, refunds/cancellations, trends, filters, and exports where granted.
- Marketing: ticket counts, sales velocity, ticket/campaign performance, and revenue only when explicitly granted.
- Event staff/owners: only assigned events.

**Security rules:**

- Authorize before revealing whether an event UUID exists.
- Use `EventScopedDashboard`/policy boundaries.
- No customer names, email addresses, payment transaction IDs, raw payloads, tokens, or provider fields.
- Revenue must follow `can_view_revenue?/2`.
- Export authorization must match page authorization.

**Out of scope:**

- Public dashboards.
- Share-by-secret-link access.
- Editing durable totals from the dashboard.
- Customer CRM functionality.

**Exit gate:** Assigned management/marketing users can access only permitted event data with correct revenue visibility and no PII leakage.

---

### Phase 6 — Historical backfill, imports, reconciliation, and exports

#### VS-28A.1 — Historical WooCommerce REST Backfill Run Model

**Outcome:** Replace the placeholder backfill worker with a durable, bounded, operator-controlled historical order backfill.

**Required scope selectors:**

- Source system.
- Date/time range.
- Event/product/variation where the Woo API contract can support it safely.
- Explicit dry-run/estimate when practical.

**Required behavior:**

- Durable run lifecycle and progress.
- Keyset/page cursor rather than unbounded memory.
- Existing parser and `OrderUpserter` only.
- Restart/retry from durable progress.
- One bounded source-level operation where necessary.
- Safe partial/failure counts.
- No direct dashboard or LiveView REST calls.

**Exit gate:** A historical range can be imported safely without duplicate sales truth or an unobservable long-running request.

#### VS-28A.2 — Historical Backfill Admin Workflow

**Outcome:** Add safe queue, progress, failure review, and restart controls for historical backfill runs.

**Out of scope:**

- Raw Woo payload browser.
- Editing imported orders.
- Unbounded full-history button without confirmation and safeguards.

**Exit gate:** An operator can initiate and monitor an approved bounded backfill and recover safely after interruption.

#### VS-28B — Filtered Event Exports and Reconciliation Pack

**Outcome:** Export the same authorized metrics and filters shown on the event decision dashboard, with explicit source watermark and generation metadata.

**Expected exports:**

- Event summary.
- Hourly/daily trend.
- Ticket-type breakdown.
- Status/refund/cancellation breakdown.
- Coupon/campaign breakdown where supported.
- Orders export under existing authorization/PII policy.
- Unmapped/reconciliation report.

**Rules:**

- Export contract must match dashboard metric rules.
- Large exports must stream or run asynchronously.
- Audit export requests.
- No raw provider payloads or secrets.

**Exit gate:** Management can export a filtered report and reconcile it against the same durable metric contract shown in LiveView.

---

### Phase 7 — Payload minimization and source-side enrichment

#### VS-27A — Compact EventSales Order Webhook Contract

**Maps to:** Existing issue `#81`.

**Outcome:** WordPress emits a versioned, compact, PII-minimized order payload that preserves current EventSales order semantics and enriches line items with Tickera identity.

**Why later:** The existing full WooCommerce webhook path already supports near-live sales. This slice improves privacy, payload size, and explicit source identity after catalog, catch-up, and reporting correctness are established.

**Required compatibility:**

- Keep the existing Woo parser as fallback.
- Route by explicit contract version.
- Preserve order header, line financials, status timestamps, and coupons.
- Keep webhook HMAC, delivery-id, replay, stale-version, persistence, and Oban semantics unchanged.

**Exit gate:** Compact and full payloads produce semantically equivalent durable orders/items/coupons while the compact payload excludes unnecessary PII and provider noise.

## Parallel Operational Hardening Backlog

The following open issues remain valuable but do not block the critical programme unless production scale makes them immediate:

- `#100` — Searchable/paginated catalog selectors for unmapped-alert resolution.
- `#101` — Bounded Oban recovery for large unmapped-alert workloads.

They should be scheduled when either:

- catalog/event count exceeds the current selector bounds;
- recovery sets approach LiveView timeout or memory risk;
- production evidence elevates them above the next critical-path slice.

The old direct WordPress MySQL evaluation (`#70`) should not be treated as the default path while the signed sanitized feed architecture remains viable.

## Dependency Graph

```text
VS-26E.0 Production baseline certification
  -> VS-26E.1 Targeted catalog trigger
  -> VS-26E.2 Conservative auto-apply
  -> VS-26E.3 Periodic catalog reconciliation
  -> VS-26F.1 Order catch-up core
  -> VS-26F.2 Scheduled/admin catch-up
  -> VS-26G Product semantics
  -> VS-27B.1 Metric/time-window contract
  -> VS-27B.2 Hourly/daily aggregates
  -> VS-27B.3 Decision dashboard
  -> VS-27C Event-scoped management/marketing access
  -> VS-28A.1 Historical backfill core
  -> VS-28A.2 Historical backfill admin workflow
  -> VS-28B Filtered exports/reconciliation
  -> VS-27A Compact webhook contract
```

Some implementation work may eventually be parallelizable, but this programme intentionally uses a single active-slice policy until production behavior is stable.

## Per-Slice Delivery Workflow

Every slice follows the same gates.

### Gate 1 — Repository audit

- Confirm clean worktree.
- Run `bash scripts/sync_with_origin_main.sh --check`.
- Record exact `main` SHA.
- Read `AGENTS.md` and canonical docs.
- Inspect every relevant current implementation and test file.
- Confirm related issue/PR state and production evidence.

### Gate 2 — Feature pack

Create a docs-only feature pack using `docs/feature_packs/EVENTSALES_FEATURE_PACK_STANDARD.md`.

The pack must include exact repo truth, files, contracts, invariants, TDD sequence, tests, verification, deployment, rollback, stop conditions, and coding-agent prompts.

No business implementation begins until the pack is reviewed and accepted.

### Gate 3 — TDD implementation

- Create a dedicated branch from the accepted baseline.
- Add failing tests first.
- Implement only the accepted slice.
- Keep unrelated refactors out.
- Generate only required Ash/project artifacts.

### Gate 4 — Local validation

At minimum:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
bash scripts/check_no_web_woocommerce_refs.sh
mix test <focused tests>
mix test
bash scripts/local_ci.sh
```

Add PHP, asset, migration, security, or performance commands required by the specific pack.

### Gate 5 — PR and independent review

- Push without force.
- Open/update PR with exact scope and evidence.
- Require green CI.
- Re-review the final exact head.
- Resolve every blocker/major finding.
- No merge on stale head or failed CI.

### Gate 6 — Deploy and production validation

- Follow the pack rollout plan.
- Apply migrations through the approved direct/session-capable path when needed.
- Run only authorized production actions.
- Capture sanitized evidence.
- Stop on defined safety conditions.

### Gate 7 — Close and advance

- Update the Kanban status and roadmap evidence.
- Close the owning issue only after production acceptance, not merely merge.
- Start the next feature pack only after the current slice reaches Done or is explicitly deferred with documented risk.

## Definition of Done

A slice is Done only when:

- Its feature pack was approved.
- Tests were written first or adjusted before logic.
- Required implementation is merged.
- Exact-head CI is green.
- Required migrations/config are deployed.
- Production validation passed or an explicit risk acceptance is recorded.
- Security/PII rules were checked.
- Operational runbooks and evidence are current.
- Roadmap/Kanban status is updated.
- No unresolved blocker remains for the next slice.
