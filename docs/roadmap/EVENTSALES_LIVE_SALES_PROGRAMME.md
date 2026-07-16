# EventSales Live Sales Programme

## Purpose

EventSales is the internal sales-intelligence and reconciliation layer for the existing production WooCommerce + Tickera site.

```text
Production WordPress/Tickera catalog
-> EventSales discovers and safely maintains local catalog truth
-> WooCommerce webhooks deliver near-live order changes
-> bounded REST catch-up repairs missed updates
-> Ash/Postgres stores durable sales truth
-> aggregate/read models serve bounded decision queries
-> LiveView updates automatically through PubSub
-> management and marketing inspect all-event and event-specific performance
-> controlled backfill, import, export, correction, audit, and notifications support operations
```

WooCommerce remains the sales engine. EventSales does not become payment, ticket-issuance, scanner, or customer-delivery authority.

## Source and Workflow Hierarchy

The programme uses four deliberately separate artefacts:

```text
GitHub repository
= canonical technical and product-contract truth

Canonical feature-pack folder in GitHub
= reviewed source for one vertical slice

Versioned immutable ZIP
= exact execution capsule supplied to an agent

Linear
= workflow, dependencies, blockers, ownership, hand-offs, and evidence status
```

A ZIP never replaces the repository. Linear never replaces the feature pack or reviewed PR.

## Canonical Repository Rules

Every slice must follow:

- `AGENTS.md`
- `docs/agent/01_PROJECT_WIDE_RULES.md`
- `docs/EventSales_Hardened_V2_1_Vertical_Slice_Roadmap.md`
- `docs/EventSales_Hardened_V2_1_Folder_Structure.md`
- `docs/EventSales_Hardened_V2_1_Domain_Mapping_Ash_Resource_Dossiers.md`
- `docs/feature_packs/EVENTSALES_FEATURE_PACK_STANDARD.md`
- `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md`

Non-negotiable programme rules:

1. Build and validate one vertical slice at a time.
2. Refresh each detailed pack against the exact current `main` SHA.
3. Require an agent plan and human review before implementation or production execution.
4. Write or adjust tests before business logic.
5. Postgres/AshPostgres remains durable truth.
6. Redis, ETS, Cachex, and `HotStateAggregator` remain read models only.
7. LiveView, controllers, components, and `MappingResolver` must not call WooCommerce REST.
8. Only approved ingestion services and Oban workers may call `WooCommerceClient`.
9. Durable mutations belong in Ash actions or explicit domain services.
10. Webhook, catch-up, reconciliation, and backfill paths must be idempotent and source-version guarded.
11. WooCommerce REST concurrency remains bounded to a maximum of two unless a reviewed contract explicitly changes it.
12. No secrets, customer PII, raw protected payloads, or production credentials may enter code, tests, packs, logs, screenshots, or evidence.
13. A merge is not completion. Required deployment and production evidence must pass before the slice closes.

## Current Operational Baseline

As confirmed on 16 July 2026:

- EventSales is deployed on Railway but has not yet been adopted operationally by the company.
- PostgreSQL is hosted on Railway.
- Deployment is GitHub to Railway when a PR is merged.
- The production WordPress + Tickera site has operated for a long period and is actively selling tickets.
- The production plugin and WooCommerce webhooks already send data to EventSales on Railway.
- EventSales currently contains real data, but that data does not need to be preserved. Correct repeatable sync and later controlled backfill take priority.
- The source has approximately twenty currently live/public events; exact ticket-product, variation, and special-product counts still require discovery.
- PgBouncer usage, a direct/session-capable migration URL, and whether PR #111 migrations have run are not yet verified.
- Catalog Sync has likely been tried against production before, but its exact result and current database state are not trusted as a certified baseline.

These unknowns are first-slice preflight requirements, not assumptions an agent may fill in.

## Locked Product Direction

The detailed record is in `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md`. The cross-programme rules are:

### Catalog and event lifecycle

- A Tickera event is the primary event identity.
- WooCommerce products and optional variations are linked ticket-selling entities.
- New catalog automation concerns live/public events, not draft or private events.
- Private events remain represented and must be clearly marked private in EventSales rather than silently appearing current/public.
- Event date and lifecycle must support current and previous event views.
- WordPress write-back may be considered later, but is not part of the current critical path.

### Sales truth

- Only completed orders contribute to sold-ticket and recognised-sales totals.
- Pending, on-hold, failed, cancelled, and refunded states must still be ingested and visible as operational context.
- On-hold commonly represents EFT awaiting verification and must not count as completed sales.
- Prices and sales are currently tax-inclusive.
- Fees and tax breakdowns are desired, but their exact source fields and accounting display contract must be verified before implementation.
- The metric-contract slice must distinguish the timestamp used for completed-sale windows from the source-update timestamp used for freshness and status changes.

### Freshness and UX

- Normal data visibility target: less than five minutes.
- Stale threshold: ten minutes.
- Manual refresh queues work; it never performs WooCommerce REST inline from LiveView.
- A page that queues refresh must update automatically when new data becomes available and clear stale state without a browser reload.
- All-event and per-event views are required.

### Reporting and access

- Required core metrics include total tickets, revenue, product/ticket-type performance, status context, and bounded date/time filters.
- Date/time queries must have sensible limits and must not enable unbounded raw-order scans.
- Coupon, UTM, campaign/source, and related acquisition dimensions are planned after the trustworthy baseline and source contract exist.
- Initial access is admin-only; additional event-scoped roles and revenue permissions are planned.
- Targets, pacing, and under/over-performance notifications are a planned feature after decision-grade metrics exist.

### Backfill, import, correction, and scale

- Launch backfill covers currently public events only, from each event's creation date.
- Private events and old events that are not needed for launch are excluded from initial backfill.
- Corrections must be flaggable/reviewable and retain audit history.
- CSV and XLSX are the supported initial import formats.
- One source site is authoritative for v1; a second, possibly non-WordPress source may be added later.
- Initial scale target is roughly 10,000 ticket sales over several weeks and fifty concurrent dashboard viewers, while preserving bounded-query and flash-sale-safe architecture.

## Existing Repository Foundation

The repository already contains substantial capability that future slices must reuse rather than replace:

### Catalog

- Signed/sanitised WordPress + Tickera catalog feed.
- Discovery adapters, dry-run planning, findings, exact-snapshot/hash Apply gates, revocation, and mapping workflows.
- Retry-aware, generation-fenced Catalog Sync lifecycle from merged PR #111.
- One-active-run database authority and truthful admin states.

### Sales ingestion

- Exact raw-body webhook signature verification.
- Durable webhook intake before asynchronous processing.
- Duplicate and stale-source guards.
- Oban-backed `order.created`, `order.updated`, and `product.updated` processing.
- Existing `OrderUpserter` as the normalised order/order-item writer.
- Completed-only metric rules and unmapped-item recovery.

### Analytics and UI

- Hot/warm read models and snapshots.
- Event-scoped PubSub notification after durable writes.
- Admin dashboard and event detail views.
- Existing totals, ticket-type detail, statuses, recent orders, unmapped items, CSV import, and exports.
- Event-scoped dashboard facade and revenue-visibility foundations.

Known gaps include automatic catalog creation, periodic catalog repair, order catch-up, self-updating queued refresh states, real time-window buckets, management/marketing surfaces, launch backfill, richer exports, acquisition dimensions, and targets/notifications.

## Programme Success Criteria

The programme is complete when:

1. A new safe live/public Tickera event and its ticket products appear automatically in EventSales.
2. Draft/private/ambiguous/destructive catalog changes never auto-apply as safe public catalog truth.
3. Private events are visibly private and current/previous event classification is correct.
4. Order changes normally appear within five minutes and missed changes recover automatically.
5. Duplicate webhooks, catch-up, replay, reconciliation, and backfill never duplicate durable sales effects.
6. Completed-only sales totals are correct while all relevant statuses remain visible.
7. All-event and per-event dashboards expose bounded time windows, velocity, comparisons, product/ticket-type performance, and freshness.
8. Queued refreshes and new sales update open LiveViews automatically through PubSub.
9. Management/marketing access is event-scoped, revenue-aware, and PII-safe.
10. Targets and notification rules can be configured and produce auditable alerts.
11. Current public events can be backfilled from creation date with durable progress and safe restart.
12. CSV/XLSX import, exports, corrections, and reconciliation are bounded and audited.
13. The system supports the stated scale without raw-table dashboard scans or unbounded source calls.

## Ordered Vertical Slices

### Phase 0 — Certify the deployed baseline

#### VS-26E.0 — Catalog Lifecycle Deployment and Baseline Certification

**Outcome:** Validate the already-merged Catalog Sync lifecycle on Railway, verify migration/index state, run one controlled production full-feed dry-run, review the exact snapshot/findings, and either Apply an approved baseline or record a safe no-go.

**Dependencies:** PR #111 merged; planning PR #112 merged; Railway access; source plugin/webhooks available.

**Required scope:**

- Verify deployed commit and Railway topology.
- Determine whether a pooler is present and identify the approved direct/session-capable migration route.
- Verify whether PR #111 migrations ran.
- Read-only duplicate-active-run and index-validity preflight.
- Controlled dry-run against production source.
- Human review of findings and exact snapshot/hash.
- Separate Apply decision.
- Post-Apply event, ticket-type, mapping, lifecycle, and admin-visibility verification.
- Redacted evidence and explicit certification verdict.

**Out of scope:** automatic triggers, schedules, auto-apply policy, order backfill, dashboard work, and unrelated production-data correction.

**Exit gate:** `CERTIFIED — VS-26E.1 MAY START`, or a documented blocker/no-go that keeps downstream slices locked.

### Phase 1 — Automatic catalog creation and maintenance

#### VS-26E.1 — Targeted WordPress Catalog Change Trigger

**Outcome:** A Tickera event/product/variation lifecycle change sends a small authenticated trigger and queues targeted EventSales discovery.

Rules:

- Trigger is not catalog authority; EventSales fetches the signed authoritative feed.
- Cover create/update, publication/private/draft transition, variation change, and product-to-event relationship change.
- WordPress save requests do not wait for discovery.
- Duplicate notifications are harmless.
- No catalog Apply occurs inline.

**Exit gate:** a production live/public event change queues one bounded discovery, with private/draft transitions correctly represented for review.

#### VS-26E.2 — Conservative Catalog Auto-Apply

**Outcome:** Low-risk additive live/public catalog changes auto-apply; risky changes remain review-only.

Possible safe candidates:

- New live/public Tickera event.
- New unambiguous ticket product or variation.
- Conflict-free ticket type and ProductMapping creation.

Always review:

- Draft/private entities.
- Product/event moves.
- Conflicts, ambiguous naming, destructive changes, unknown semantics, memberships, subscriptions, payment plans, bundles, and add-ons.

**Exit gate:** policy and end-to-end tests prove safe additions apply and every risky class stops.

#### VS-26E.3 — Periodic Catalog Reconciliation Sweep

**Outcome:** A durable updated-since sweep recovers missed triggers without overlapping Catalog Sync runs or stampeding WordPress.

Initial target:

- Trigger-driven visibility within five minutes, preferably closer to two.
- Missed-trigger recovery within fifteen minutes.
- One queue-blocking catalog run per source.

**Exit gate:** a deliberately missed trigger is recovered and repeated schedules remain idempotent.

### Phase 2 — Reliable near-live order truth

#### VS-26F.1 — WooCommerce Order Catch-Up Core

**Maps to:** #80.

**Outcome:** A durable updated-since cursor fetches missed/changed orders through bounded REST and routes them through the existing parser and `OrderUpserter`.

Required invariants:

- Cursor per source.
- Maximum Woo REST concurrency two.
- Bounded pages and safe initial overlap/lookback.
- Advance cursor only after durable success.
- Stale updates cannot overwrite newer truth.
- Repeated runs do not duplicate orders/items.

**Exit gate:** a missed webhook update is repaired safely.

#### VS-26F.2 — Scheduled Catch-Up, Queued Refresh, and Live Status

**Outcome:** Catch-up runs automatically and manual refresh queues bounded work whose progress/result updates open LiveViews automatically.

Required behaviour:

- Conservative schedule around five minutes, adjusted by evidence.
- One active catch-up run per source.
- Rate-limited admin queue action.
- Last-success watermark, lag, active state, counts, and bounded errors.
- PubSub update when work starts/completes/fails and when affected read models refresh.
- Stale banner clears without browser reload after fresh data arrives.

**Exit gate:** missed updates recover and a queued refresh visibly completes in an already-open dashboard.

### Phase 3 — Product and order-line semantics

#### VS-26G — Ticket, Payment-Plan, Membership, Add-On, and Renewal Semantics

**Maps to:** #82.

**Outcome:** Explicitly classify which products/order lines contribute tickets, sales, fees, tax, and status context.

Conservative default: unknown/non-ticket semantics do not count as sold tickets until reviewed.

This slice must lock tax-inclusive display, fee handling, partial/full refund treatment, variations, bundles, memberships, subscriptions, and payment plans before richer reporting.

**Exit gate:** tests make every inclusion/exclusion rule explicit and auditable.

### Phase 4 — Decision-grade metrics and dashboards

#### VS-27B.1 — Event Sales Metric and Time-Window Contract

**Outcome:** Define exact metrics and timestamps before new aggregate tables or UI.

Must define:

- Completed-only ticket and revenue totals.
- Operational status counts for pending, on-hold, failed, cancelled, and refunded.
- Last 15/30/60 minutes; today/yesterday; rolling 7 days; bounded custom ranges.
- Which completed/payment timestamp controls sale windows.
- Which source-update timestamp controls freshness/status activity.
- Refund/cancellation effects.
- Tax-inclusive values and fee/tax presentation.
- Previous-equivalent-period comparisons.
- Stale threshold of ten minutes.
- Query-range limits and maximum dimensional cardinality.

**Exit gate:** reviewed contract and tests define every management-facing number.

#### VS-27B.2 — Durable Hourly and Daily Event Sales Buckets

**Outcome:** Durable bounded aggregates support all-event and event-level windows without scanning raw orders from LiveView.

Rules:

- Aggregate only after durable order writes.
- Correct affected buckets on status/refund changes.
- Idempotent under duplicate delivery and replay.
- Rebuild selected event/range safely.
- Postgres remains authority; caches mirror.

**Exit gate:** real-time, correction, comparison, and rebuild tests pass.

#### VS-27B.3 — Event Sales Decision Dashboard

**Outcome:** Deliver all-event and per-event decision surfaces.

Core UI:

- Total tickets and revenue.
- Last hour, today, yesterday, rolling and bounded selected range.
- Current versus previous equivalent period.
- Sales velocity and trend.
- Product/ticket-type performance.
- Status/refund/cancellation context.
- Fees/tax where the source contract supports them.
- Freshness watermark, ten-minute stale state, and queued-refresh status.
- Automatic PubSub-driven updates.

Later dimensions such as coupon, UTM, campaign/source must only be enabled after source cardinality and persistence contracts are proven.

**Exit gate:** bounded queries support fifty concurrent viewers and open pages update without reload.

### Phase 5 — Access, targets, and notifications

#### VS-27C — Event-Scoped Management and Marketing Access

**Outcome:** Add non-admin roles with event grants and revenue visibility rules, using the existing event-scoped facade and excluding customer PII.

**Exit gate:** positive and negative policy tests prove event isolation and revenue restrictions.

#### VS-27D — Targets, Pacing, and Notifications

**Outcome:** Allow authorised users to set event/ticket targets and receive auditable notifications for under/over-performance, threshold crossings, pacing changes, and selected operational freshness failures.

Rules:

- Use aggregate/read-model data, not raw order scans.
- Deduplicate alerts and apply cooldowns.
- Notifications never become sales truth.
- Delivery channels and escalation rules require a separate reviewed contract.

**Exit gate:** deterministic target evaluation and duplicate-safe alert evidence pass.

### Phase 6 — Launch backfill, import, export, and correction

#### VS-28A.1 — Current Public Event Backfill Core

**Outcome:** Backfill WooCommerce orders for selected currently public events from each event's creation date through bounded, restartable Oban work.

Explicit exclusions:

- Private events.
- Old events not required for launch.
- Unbounded multi-year/full-store import.

**Exit gate:** a selected public event backfills idempotently with durable progress and safe resume.

#### VS-28A.2 — Backfill Admin Workflow

**Outcome:** Admins can preview, queue, pause/cancel where safe, resume, and inspect event-scoped backfill without exposing raw payloads or PII.

**Exit gate:** human workflow is bounded, audited, and fail-closed.

#### VS-28B — CSV/XLSX Import, Filtered Exports, Reconciliation, and Corrections

**Outcome:** Extend existing import/export facilities for approved CSV/XLSX workflows, bounded filters, reconciliation evidence, issue flags, and audited corrections.

Rules:

- Dry-run before Apply.
- No silent overwrite of durable source history.
- Corrections preserve before/after audit and reason.
- Export ranges/dimensions are bounded.

**Exit gate:** imports, exports, flags, and corrections are reviewable and auditable.

### Phase 7 — Source-contract hardening

#### VS-27A — Compact EventSales Order Webhook Contract

**Maps to:** #81.

**Outcome:** Reduce webhook payload exposure and ambiguity after the stable parser/catch-up/backfill semantics are known.

This remains late in the critical path to avoid changing the source contract while baseline recovery is still being proven.

**Exit gate:** compact and legacy contracts coexist or migrate safely without data loss.

## Operational Hardening Backlog

- #100 — searchable/paginated unmapped catalog selectors when catalog cardinality requires it.
- #101 — bounded Oban unmapped recovery if production tuples threaten web-process limits.
- #70 — direct WordPress MySQL adapter remains contingency-only while the signed feed is viable.

Any production evidence that shows these are blockers may promote them ahead of the normal sequence.

## Per-Slice Delivery Flow

```text
Linear parent/child gate
-> current-main repository audit
-> canonical pack source PR
-> immutable versioned ZIP + SHA-256
-> independent pack review
-> planning/reconnaissance agent only
-> human plan review
-> implementation or bounded execution
-> independent exact-head review
-> merge
-> authorised deployment/migration
-> production validation
-> Linear and roadmap closeout
-> next pack
```

## Immediate Next Action

Only `VS-26E.0` is active.

1. Merge this planning PR after exact-head review and green CI.
2. Refresh the VS-26E.0 pack against the new `main` merge SHA.
3. Generate its immutable ZIP and record SHA-256 in Linear issue `JC-106`.
4. Complete independent pack review `JC-107`.
5. Give the approved ZIP to the planning agent for `JC-108` only.

Do not begin VS-26E.1 until VS-26E.0 is operationally certified.