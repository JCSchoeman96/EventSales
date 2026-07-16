# EventSales Product and Operational Decisions

## Purpose

This document records programme-level decisions confirmed by the product owner. It prevents later feature packs from repeatedly reopening settled questions or silently inventing answers.

These decisions guide future slices, but they do not override current repository truth. A detailed slice still requires a fresh repository audit and may identify source limitations that require a reviewed clarification.

Recorded: 16 July 2026.

## 1. Infrastructure and Current Environment

### Locked decisions/facts

- EventSales is deployed on Railway.
- PostgreSQL is hosted on Railway.
- Deployment occurs from GitHub to Railway when a PR is merged.
- The company has not yet adopted EventSales as an operational reporting tool.
- The production WordPress + Tickera site has been running for a long time and actively sells tickets.
- The production plugin and webhooks already send data to EventSales on Railway.
- Existing Railway EventSales data is real but does not need to be preserved.
- Correct repeatable synchronisation and later controlled backfill take priority over preserving current EventSales data.
- The source has approximately twenty live/public events.

### Unknowns that must remain explicit

- Whether Railway is using PgBouncer or another connection pooler.
- Whether a separate direct/session-capable migration connection exists.
- Whether all migrations from merged PR #111 have run.
- Exact current catalog-sync run/index/database state.
- Exact counts of WooCommerce ticket products, variations, memberships, subscriptions, payment-plan products, bundles, and add-ons.

These unknowns are owned by VS-26E.0 preflight. Agents must not guess them.

## 2. Catalog and Event Identity

### Locked decisions

- A Tickera event is the primary event entity.
- WooCommerce products are linked to the Tickera event.
- A ticket product may have WooCommerce variations.
- Automatic catalog creation is for live/public events.
- Draft events must not become active/public EventSales events.
- Private events must not be treated as current public events.
- When an event is moved to private, EventSales must clearly represent it as private.
- Event date and lifecycle must support current and previous-event views.
- Catalog automation must respect publication/private/draft status changes and product-to-event relationships.

### Deferred direction

- EventSales may write information back to WordPress later.
- No current slice may introduce write-back without a separate contract covering authority, idempotency, conflict handling, and audit.

## 3. Order and Sales Truth

### Locked decisions

- Only completed WooCommerce orders count as sold tickets and recognised sales/revenue totals.
- All relevant order states must still be ingested and visible.
- Required operational states include at least pending, on-hold, completed, failed, cancelled, and refunded.
- On-hold commonly represents EFT awaiting verification and must not count as completed sales.
- Completed-only totals must not hide the operational context of failed, cancelled, refunded, pending, or EFT/on-hold orders.
- Current prices and sales are inclusive of tax.
- Ticket fees should be reportable when the source contract is verified.
- Tax should be reportable when source fields and display semantics are verified.

### Timestamp decision to finalise in VS-27B.1

A single timestamp must not be overloaded for all purposes.

Recommended contract direction:

- Completed-sale windows should use the authoritative payment/completion timestamp available from WooCommerce.
- Freshness and source-change activity should use the latest authoritative source-updated timestamp.
- On-hold, failed, cancellation, and refund activity may need separate status-transition/update views.

VS-27B.1 must verify exact repository/source fields and lock the final contract before aggregate implementation.

## 4. Freshness, Catch-Up, and LiveView Behaviour

### Locked decisions

- Normal sales-data visibility should be less than five minutes.
- Data is stale when freshness exceeds ten minutes.
- The dashboard must expose a refresh request when stale or when an operator needs a catch-up.
- Manual refresh must queue bounded asynchronous work.
- LiveView, controllers, and components must not call WooCommerce REST inline.
- When queued refresh/catch-up produces new data, the already-open page must update automatically.
- The stale banner and queued-state UI must clear/update automatically without a full browser reload.
- Event sales changes should continue to update open pages automatically through PubSub/read-model notifications.

### Design implication

VS-26F.2 owns the missing end-to-end queued-refresh status path, including start/progress/completion/failure notifications and affected read-model refresh.

## 5. Reporting and Filtering

### Locked core requirements

EventSales must support:

- all-event reporting;
- event-specific reporting;
- total tickets sold;
- total revenue;
- product/ticket-type totals;
- status context;
- bounded date/time filtering;
- recent velocity and comparisons;
- freshness and stale-state visibility.

### Performance boundary

- Filters must have reasonable limitations.
- The UI must not allow requests that cause unbounded raw-order scans or unbounded source calls.
- Durable hourly/daily aggregates or equivalent bounded read models should support decision dashboards.
- Custom ranges and dimensions must define maximum periods/cardinality.

### Planned later dimensions

After baseline correctness and source persistence are proven, reporting should consider:

- coupon;
- UTM parameters;
- campaign/source;
- other acquisition attribution dimensions.

These dimensions must not be added merely because WooCommerce metadata contains arbitrary keys. Cardinality, identity, privacy, and query bounds must be contracted first.

## 6. Targets and Notifications

### Locked product direction

- Event/ticket sales targets should be configurable.
- The system should support notifications when performance is under or over target.
- Threshold crossings, pacing changes, and meaningful stale/operational conditions may also be notification inputs.
- Target and pacing alerts for an event must remain disabled until the event's required data-completeness/backfill watermark is certified; partial history must never be presented as authoritative under/over-target performance.

### Required future contract

VS-27D must define:

- target identity and scope;
- evaluation cadence;
- data-completeness eligibility;
- deduplication and cooldown;
- notification channels;
- recipient/role permissions;
- escalation and acknowledgement;
- audit evidence;
- failure/retry behaviour.

Notifications never become sales truth.

## 7. Users, Roles, and Data Visibility

### Locked current state

- Current access is admin-focused.

### Planned direction

- Add other roles.
- Support event-scoped access.
- Support explicit revenue visibility permissions.
- Management and marketing views must not expose customer PII by default.

### Still to decide in VS-27C

- Exact role names.
- Whether marketing can see revenue for all assigned events.
- Whether external organisers will ever receive access.
- Who may export order/customer-level information.
- Whether any non-admin role may request backfill, refresh, or corrections.

Default until reviewed: deny broader access and exclude customer PII.

## 8. Backfill and Launch History

### Locked decisions

- Initial launch backfill is only for currently public events.
- Backfill starts from each selected event's creation date.
- Private events are excluded from initial backfill.
- Older events that are not required for launch do not need to be backfilled.
- Backfill must be bounded, durable, restartable, and idempotent.
- The programme does not need to preserve current Railway EventSales data before building the trustworthy baseline.

### Safety implications

- The backfill workflow must preview selected events and date boundaries before execution.
- The source/event mapping must be verified before order ingestion.
- Backfill must use the existing order parser and `OrderUpserter`, not a parallel writer.
- Cursor/progress must advance only after durable success.
- Successful backfill must record a data-completeness watermark that downstream target/notification logic can require.

## 9. Corrections, Audit, Import, and Export

### Locked decisions

- Incorrect/unmapped items must be flaggable and reviewable.
- Corrections should be possible where required.
- Corrections must preserve audit history and reasons.
- The ideal outcome is correct automatic mapping from the start; manual correction is a controlled exception.
- CSV and Excel/XLSX are the initial supported import formats.

### Required future contract

VS-28B must define:

- dry-run/Apply rules;
- field and row-level validation;
- idempotency keys;
- correction authority;
- immutable before/after evidence;
- error/retry reporting;
- export range and dimension bounds;
- PII rules for imports/exports.

## 10. Source Systems and Future Expansion

### Locked v1 direction

- One production WordPress/WooCommerce/Tickera site is authoritative for v1.

### Future direction

- A second source may be added later.
- The second source may not be WordPress.

### Architectural implication

Source-system identity and per-source cursors/watermarks must remain explicit even while v1 has only one source. Do not prematurely build a generic integration platform, but do not hard-code durable identity in a way that makes a second source impossible.

## 11. Capacity and Performance Targets

### Locked initial targets

- Largest expected current sale volume: approximately 10,000 tickets sold over several weeks.
- Initial concurrent dashboard-viewer target: fifty.

### Non-negotiable design direction

- Performance and optimisation remain required regardless of current volume.
- Dashboard requests must be bounded and use read models/aggregates.
- WooCommerce REST concurrency remains limited.
- Workers require uniqueness/overlap protection.
- PubSub is notification, not durable truth.
- Representative query plans and load evidence are required where a slice introduces potentially expensive reads or indexes.
- Flash-sale-safe architecture must not be weakened merely because the initial business volume is modest.

## 12. Current Slice Boundary

The active slice is VS-26E.0.

It may:

- verify Railway deployment/database topology;
- identify the migration route;
- verify PR #111 migrations/indexes;
- run a controlled production catalog dry-run;
- support a separate human Apply decision;
- certify or reject the baseline with redacted evidence.

It may not:

- add automatic WordPress triggers;
- add schedules;
- add auto-apply;
- implement order catch-up/backfill;
- redesign dashboards;
- add roles, targets, notifications, UTM/coupon dimensions, or write-back;
- perform unrelated production-data cleanup.

## 13. Decision Change Process

When a programme-level decision changes:

1. update this document in a reviewed PR;
2. identify affected Linear issues and future slices;
3. determine whether the active feature pack is invalidated;
4. if invalidated, stop execution and issue a new semantic pack version;
5. never silently reinterpret an already-issued ZIP.