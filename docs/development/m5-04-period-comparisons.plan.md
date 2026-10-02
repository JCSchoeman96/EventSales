# M5-04 period comparisons plan (M5-04A audit + JC-310 authority + JC-312 B kernel)

> For agentic workers: JC-309 audited conformance. JC-310 records locked owner comparison semantics. JC-312 (M5-04B) implements the pure comparison time/metric kernels, locks exact rolling-edge architecture, and updates this plan. M5-04C+ creates resources and migrations only after B is merged.

### Revision log

- `v1` — M5-04A audit (JC-309)
- `v2` — JC-310 owner comparison authority merged to `main`
- `v3` — JC-312 comparison kernels, rolling-edge lock, M5-04C contribution contract (this revision)

**Plan version:** `v3`
**Status:** M5-04B implemented on branch; M5-04C not started
**Last updated:** 2026-10-02
**Change summary (v3):** Record JC-312 APIs, hybrid rolling-edge decision, remove B merge gate, extend C scope for durable contribution projection.

**Goal:** Define a canonical, currency-safe period comparison read model for event and required dimensional grains without promoting the legacy daily-v1 snapshot or inventing comparison semantics.

**Architecture:** Keep `TimeRules` and the certified `EventAggregator.financial_summaries_for_event_period/2` as the current semantic and event-level query authorities. The recommended target is a new additive Postgres time-bucket projection family for event and dimensional rows, with Net, ATV, comparison deltas, and percentages derived by a projection-only reader. Previous-equivalent comparison semantics are locked by owner decision (JC-310). Exact rolling-edge bucket resolution remains an M5-04B design gate.

**Tech stack:** Ash 3.x, AshPostgres, PostgreSQL 18, Ecto query plans, Oban `RefreshSnapshotWorker`, Phoenix PubSub, ETS `DashboardCache`, optional existing Redis snapshot adapter, and the existing `Policies`, `FinancialPrimitives`, `MetricRules`, `TimeRules`, `EventAggregator`, and `DimensionAggregator` modules.

---

## 1. Authority and verified base

### 1.1 Accepted base

The branch was created only after the required preflight commands ran:

```text
git fetch origin
git rev-parse origin/main
git rev-parse origin/main^{tree}
git status --short
```

Observed values at M5-04A preflight (historical):

```text
BASE_SHA  = 388938a8c443ecfca3fa63476ecbcfc452b456a9
BASE_TREE = 29e183da52d9bd193fcc3cae239d9c4d021feb13
WORKTREE  = clean at preflight
BRANCH    = docs/jc-309-m5-04a-period-comparisons
```

JC-310 authority recording preflight (re-authorized base after unrelated `origin/main` movement):

```text
REAUTHORIZED_BASE_SHA  = 89c19bacbb48b29b0e372d31fa544f316de029e8
REAUTHORIZED_BASE_TREE = 388c89c524fb8324120b8e83e932ee054ef42584
PREVIOUS_BASE_SHA      = 959e1b307bc801a4049a55195c94b8ff892e8b77
BASE_MOVEMENT_CLASS    = NON-CONFLICTING / UNRELATED TO JC-310 (PR #284)
WORKTREE               = clean at preflight
BRANCH                 = docs/jc-310-m5-04-comparison-owner-authority
```

JC-312 (M5-04B) implementation preflight (JC-310 merged on `main`):

```text
BASE_SHA  = 3bb62061f5ff01cbe3f670944f4ad04d6f346882
BASE_TREE = d84cd88f1b1b74b75110e5eee341c6ad41844ba0
WORKTREE  = clean at preflight
BRANCH    = feature/jc-312-m5-04b-comparison-kernel
LINEAR    = JC-312
```

If `origin/main` moves before any implementation slice starts, that slice must stop and re-verify its own accepted base.

### 1.2 Linear and scope

```text
LINEAR_M5_04A = JC-309
LINEAR_M5_04_AUTHORITY = JC-310
LINEAR_M5_04B = JC-312
TITLE_JC-309  = EventSales M5-04A - Period comparisons planning and conformance audit
TITLE_JC-310  = EventSales M5-04 owner decision - Previous-equivalent period contract
TITLE_JC-312  = EventSales M5-04B - Comparison kernel and exact rolling-edge contract
SCOPE_JC-309  = documentation and repository conformance only (merged)
SCOPE_JC-310  = record approved owner comparison authority in this plan only (merged)
SCOPE_JC-312  = pure comparison kernels, tests, rolling-edge architecture lock, plan update (no resources/migrations)
```

JC-310 changes only this file. There are no production, test, migration, index, dependency, cache, Redis, worker, scheduler, or UI changes in JC-310.

### 1.3 Authority order

The audit follows the repository authority order in `AGENTS.md`:

1. `docs/path-1/path-1-phase-breakdown.md`
2. `docs/path-1/m1-07-timestamp-johannesburg-period-and-freshness-contract.md`
3. `docs/development/pre-m5-time-foundation-implementation.plan.md`
4. `docs/evidence/pre-m5-time-g-certification.md`
5. `docs/development/pre-m5-02-metrics-foundation.plan.md`
6. `docs/evidence/pre-m5-02f-metrics-certification.md`
7. `docs/development/m5-01-base-event-aggregates.plan.md`
8. `docs/development/m5-02-ticket-product-variation-aggregates.plan.md`
9. `docs/development/m5-03-revenue-refund-dimensional-aggregates.plan.md`
10. M5-02 and M5-03 certification evidence
11. Current production modules and focused tests named by JC-309

The repository also contains older VS-27B.1 and VS-27B.2 planning packs in `slices/*.zip`. Their `pack.json` files explicitly set `execution_authority: false`, and their README files authorize reconnaissance and planning only. They are useful evidence of prior intended comparison and bucket rules, not current implementation authority.

### 1.4 Certified facts used by this plan

- `TimeRules` owns sale/refund effective clocks and period boundaries.
- Reporting periods are half-open `[start_utc, end_utc)`.
- `today` and `yesterday` use `Africa/Johannesburg` civil midnights converted once to UTC.
- Rolling 7-day and 30-day periods use exact UTC durations ending at `now`.
- Sale placement uses `COALESCE(Order.paid_at, Order.completed_at)` and withholds a recognised sale with neither clock.
- Historical sale recognition uses the canonical predicate `Order.status == "completed" OR Order.completed_at is present`. A later `refunded` or `cancelled` status does not erase historical Gross while `completed_at` remains present. A financial recognition transition occurs only when this predicate changes from true to false or from false to true; non-completed status labels or status-only downgrades do not establish that change without evaluating `completed_at`.
- Refund placement uses `Refund.source_created_at` and withholds a qualifying refund without that clock.
- Gross remains in the sale period when a refund is posted in another period.
- `CUSTOM_RANGE_MAX = 90` Johannesburg civil days is an owner decision, but `EventAggregator.financial_summaries_for_event_period/2` deliberately rejects `:custom`.
- `EventAggregator.financial_summaries_for_event_period/2` is canonical for supported preset event-level financials and has bounded/indexed query-plan evidence.
- `DailySalesAggregateSnapshot` v1 is legacy and non-canonical for M5 period reporting.
- `EventAggregateSnapshot` v2 is one row per `(event_id, currency)` and stores additive event primitives only.
- `EventDimensionAggregateSnapshot` is the normalized parallel family for `ticket_type`, `source_product`, and `source_variation`; its M5-03 refund fields are additive primitives.
- Refund quantities and values are stored as positive qualifying magnitudes; Net subtracts those magnitudes from Gross.
- `MetricRules` and `FinancialPrimitives` derive Net and ATV. Neither treats Net or ATV as additive storage.
- `SnapshotRefresh` writes event and dimension projections under the existing per-event advisory fence and coherent transaction.
- Existing readers perform authorization before projection work, use coherent reads, and redact monetary values through `Policies.can_view_revenue?/2`.

### 1.5 Prior blocking result (resolved by JC-310)

M5-04A recorded an older VS-27B.1 `COMPARISON_CONTRACT.md` as non-authoritative planning evidence. It conflicted with current M1-07/M5-03 in two material ways: full civil `:today` versus a partial `today_to_now` comparison window, and refund attribution back to sale windows versus independent `Refund.source_created_at` placement.

The owner approved the JC-310 recommended contract without modification. That decision is locked in Section 7 and does not rewrite M1-07. Management "today" comparison uses a separate elapsed-day scope; canonical M1-07 `:today` remains a full Johannesburg civil day.

```text
OWNER_DECISION_REQUIRED = NO
OWNER_DECISION = APPROVED
COMPARISON_AUTHORITY_LOCKED = YES
M1_07_REWRITE = NO
CUSTOM_COMPARISON = DEFERRED
M5_04B_AUTHORIZATION_PENDING_MERGE = NO
JC_310_MERGED = YES (MERGE_SHA 3bb62061f5ff01cbe3f670944f4ad04d6f346882)
IMPLEMENTATION_READY = M5-04C (resources/migrations) after JC-312 merge
ROLLING_EDGE_STRATEGY = FIXED_INTERIOR_BUCKETS_PLUS_DURABLE_EXACT_CONTRIBUTION_EDGE (JC-312)
ROLLING_EDGE_IMPLEMENTATION_DEFERRED_TO = M5-04C
STOP_CONDITION_TRIGGERED = NONE
```

## 2. Ultimate goal

An authorized management caller must read deterministic financial comparisons for one event, one currency, and a requested reporting period without a raw-history dashboard scan. The result must contain:

```text
current period:
  gross_ticket_quantity
  refund_ticket_quantity
  net_ticket_quantity
  gross_ticket_value
  refund_ticket_value
  net_ticket_value
  average_ticket_value

comparison period:
  the same fields, when the comparison is available and comparable

comparison:
  absolute deltas where both values exist
  percentage deltas only when the denominator is mathematically defined
```

The event-level result may also include `recognised_order_count` only if its
event-bucket additivity and coverage contract are certified. It is not a
required dimensional metric in the M5 MVP.

If dimensional comparison remains in M5, the same result must be available independently for `ticket_type`, `source_product`, and `source_variation`. The families are parallel views. A reader must never sum all three families into one management total.

Currency conversion is outside the goal. `ZAR` and `USD` remain independent partitions.

## 3. Backward planning

The target is reached in this order:

1. ~~Reconcile the older comparison contract with current M1-07 and M5-03 authority.~~ Done (JC-310 owner decision recorded in Section 7).
2. Lock a single captured `now`, current bounds, previous bounds, and comparison output states. Done for semantics (JC-310); M5-04B implements helpers and tests.
3. Keep effective-time, recognition, refund qualification, and currency rules unchanged.
4. Choose an additive bucket identity that can represent each approved period exactly, including rolling boundary behavior.
5. Persist only additive primitives at event and dimensional grains.
6. Rebuild every affected old and new bucket after source mutations.
7. Publish one coherent generation for event and dimensional rows under the existing event fence.
8. Read only the period projection after UUID validation, authorization, readiness checks, and generation validation.
9. Add hot or warm acceleration only after measured demand proves the cold projection read insufficient.

Steps 4 through 9 remain blocked until M5-04B locks exact bucket resolution for rolling windows and subsequent slices certify resources, rebuilds, and readers. Step 1 authority is recorded; do not infer product rules from stale planning packs.

## 4. Current repository truth

### 4.1 Time and effective clocks

`lib/event_sales/analytics/time_rules.ex` is pure and side-effect free. It provides `TimeRules.Period`, sale/refund effective selectors, Johannesburg business dates, Today/Yesterday bounds, rolling bounds, custom civil normalization, half-open membership, source-freshness classification, and **`TimeRules.ComparisonWindows` via `comparison_windows/3`** (JC-312). `comparison_windows/3` derives management current/previous windows from one captured `now` for `:today` (elapsed Johannesburg day), `:yesterday`, and `{:rolling_days, 7|30}`. Canonical `today_bounds/2` remains a full Johannesburg civil day and is not overloaded for elapsed comparison.

### 4.2 Event period aggregation

`EventAggregator.financial_summaries_for_event_period/2` currently:

- accepts only `:today`, `:yesterday`, `{:rolling_days, 7}`, and `{:rolling_days, 30}`;
- rejects `:custom` with `{:error, :unsupported_period_kind}`;
- checks missing recognised-sale and qualifying-refund clocks before aggregation;
- applies sale-period predicates to `COALESCE(paid_at, completed_at)`;
- applies refund-period predicates to `source_created_at`;
- keeps gross and refunds in separate SQL queries to avoid join multiplication;
- returns currency-keyed financial summaries with Net and ATV derived by `MetricRules`;
- has event-first and refund-path `EXPLAIN (FORMAT JSON)` evidence in `EventAggregatorFinancialQueryPlanTest`.

This is a canonical event-level period source. It is not a persisted period read model and not a dimensional period API.

### 4.3 Dimensional aggregation

`DimensionAggregator.financial_rows_for_event/1` runs six bounded grouped queries:

```text
gross:  ticket_type, source_product, source_variation
refund: ticket_type, source_product, source_variation
```

The refund queries use the shared `EventAggregator.refund_primitives_filters/0`, the exact parent-line binder, and parent historical identities. M5-03 evidence proves value-only refunds, header-only refunds, voided and unresolved transitions, replay behavior, currency isolation, family non-additivity, and six-query plan bounds.

There is no period argument, bucket key, or period-dimension reader in this module.

### 4.4 Existing projections and readers

`EventAggregateSnapshot` is canonical v2 event/currency storage. `EventDimensionAggregateSnapshot` is canonical dimensional storage. `DailySalesAggregateSnapshot` v1 stores legacy scalar fields:

```text
total_sold
total_revenue
today_sold
today_revenue
```

Its refresh path filters rows by `completed_at`, uses scalar legacy semantics, and has the identity `(event_id, business_date, business_timezone)`. It does not store the M5-03 additive financial primitives, independent refund effective time, comparison identity, or the currency-safe canonical v2 contract.

`SnapshotReader.daily_summary_for_event/3` remains a compatibility reader for Daily v1. It must not be reused as the M5-04 period authority.

`SnapshotRefresh.refresh_event/2` calculates event and dimensional projections, replaces the full dimensional set, invalidates `DashboardCache` after commit, and runs under `EventSnapshotRefreshFence`.

`SnapshotReader` and `DimensionSnapshotReader` are cold projection readers. `DimensionSnapshotReader` reads all dimensional rows in one coherent transaction, validates generation timestamps, performs bounded catalogue enrichment, and does not itself consult `AnalyticsReadinessResolver`.

### 4.5 Invalidation and operational seams

M5-01 B23 and M5-03 reuse `RefreshSnapshotWorker` and existing mutation candidate resolvers. Relevant order, attribution, mapping recovery, and refund mutations enqueue event refresh intent transactionally. ProductMapping-only catalogue changes and TicketType display-only changes do not enqueue refresh.

`HotStateAggregator` and `DashboardCache` own current hot summaries, not period truth. The existing Redis adapter is optional and currently receives a one-hour TTL for hot snapshots when configured. Phoenix PubSub broadcasts after durable/read-model changes. Browser polling is not the update mechanism.

## 5. Domain and resource map

### 5.1 Existing durable source resources

| Resource | Purpose | Canonical grain and identity | Source-of-truth relationship | Mutation ownership | Read ownership | Lifecycle/invalidation |
| --- | --- | --- | --- | --- | --- | --- |
| `Event` | Event scope and authorization target | `event.id` | Catalog durable truth | Catalog writers and audited attribution seams | Policies and management facades | Affected period rows follow order-item event candidates |
| `TicketType` | Internal reportable ticket category | `ticket_type.id` within an event | Catalog identity, not historical line authority | Catalog writers | Bounded reader enrichment | Name/capacity/active changes do not alter historical period grain |
| `Order` | Sale lifecycle, currency, paid/completed clocks | `(source_system_id, woo_order_id)` | Sales durable truth | `OrderUpserter` | Aggregators and refresh workers only | Sale-clock correction invalidates old and new buckets |
| `OrderItem` | Historical ticket attribution and financial primitives | `(order_id, woo_line_item_id)` | Sales durable truth for event and dimension identity | `OrderUpserter`, attribution correction, mapping recovery | Aggregators and rebuilds only | Event, ticket, product, variation, quantity, or value changes invalidate before/after identities |
| `Refund` | Independent financial adjustment header | Source-scoped refund identity | Sales durable truth | `RefundUpserter` | Refund aggregators and rebuilds only | Active/complete, unresolved, and voided transitions invalidate refund buckets |
| `RefundLine` | Exact bound refund-line primitives | Refund-line identity plus exact parent binder | Sales durable truth | `RefundUpserter` and binder | Refund aggregators only | Binder changes can move an adjustment between event/dimension identities |

### 5.2 Existing analytics modules and projections

| Component | Current contract | Period role |
| --- | --- | --- |
| `TimeRules.ComparisonWindows` | Management current/previous half-open windows from one captured `now` | **Implemented (JC-312)** via `comparison_windows/3`; canonical preset bounds unchanged |
| `MetricRules` comparison helpers | Readiness precedence, comparability, decimal deltas | **Implemented (JC-312)** via `projections_comparable?/2`, `classify_comparison_state/1`, `derive_comparison_deltas/3` |
| `EventAggregator` | Bounded event financial aggregation, including supported presets | Reuse for parity and certification; not an interactive source fallback and not a dimensional store |
| `DimensionAggregator` | Bounded event/dimensional gross/refund aggregation | Extend only in an approved period projection slice |
| `EventAggregateSnapshot` | Lifetime/current event/currency v2 projection | Do not add period identity |
| `EventDimensionAggregateSnapshot` | Lifetime/current dimensional projection | Do not add period identity |
| `DailySalesAggregateSnapshot` | Legacy v1 daily scalar compatibility | Non-canonical for M5-04 |
| `SnapshotRefresh` | Coherent event and dimension replacement under fence | Reuse fence and transaction; no second scheduler |
| `SnapshotReader` | Snapshot-only event reads and Daily v1 compatibility | Add a separate period reader |
| `DimensionSnapshotReader` | Coherent dimensional reads with derivation/redaction | Add a period comparison reader with the same boundary rules |
| `Policies` | Event access and revenue visibility | Run before projection work; redact money when hidden |
| `DashboardCache` | ETS current-summary cache | Targeted invalidation if period data is cached |
| `HotStateAggregator` | Hot current-summary recompute, optional Redis mirror, PubSub | Not durable period truth |
| `RefreshSnapshotWorker` | Oban event refresh intent and rebuild | Reuse with explicit bucket scope after an approved slice |
| `DashboardPubSub` | Post-commit live update notification | Notify after period generation commit |

### 5.3 Proposed period projection resources

The target is a new period projection family, not an extension of current/lifetime rows. Two resources preserve the certified event and dimensional ownership boundaries.

#### `EventPeriodAggregateSnapshot` (proposed)

| Field | Planned contract |
| --- | --- |
| Purpose | Durable additive event values for a fixed time bucket |
| Grain | `(event_id, currency, bucket_kind, bucket_start_utc, bucket_end_utc)` |
| Identity | Exact event, currency, bucket kind, and UTC bounds |
| Relationships | `belongs_to :event`; no Product or TicketType relationship |
| Stored fields | Gross/refund quantities and values; event `recognised_order_count` only if bucket additivity is certified |
| Generation metadata | `generation_id`, captured `now_utc`, timezone, scope/version, semantic version, coverage/readiness, refreshed-at, and source watermark; either stored on each row or in a generation envelope referenced by each row |
| Source truth | `Order`, `OrderItem`, `Refund`, and `RefundLine`; projection is derived |
| Mutation owner | Existing order/refund/attribution seams through `RefreshSnapshotWorker` and `SnapshotRefresh` |
| Read owner | Period comparison reader after policy/readiness checks |
| Lifecycle | Absent, current, stale, rebuilding, unavailable; metadata can express this without a state enum |
| Invalidation | Every affected before and after event bucket |

#### `EventDimensionPeriodAggregateSnapshot` (proposed)

| Field | Planned contract |
| --- | --- |
| Purpose | Durable additive values for a bucket at each parallel dimension family |
| Grain | Event plus `ticket_type`, `source_product`, or `source_variation` identity |
| Identity | Event, currency, bucket, dimension kind, and exact historical dimension tuple |
| Relationships | Event plus conditional TicketType/SourceSystem relationships matching M5-02/M5-03 checks |
| Stored fields | Gross/refund quantities and values only |
| Generation metadata | Same generation envelope as the event row, including captured `now_utc`, timezone, scope/version, semantic version, coverage/readiness, refreshed-at, and source watermark |
| Source truth | Historical `OrderItem` identities and exact bound `RefundLine` parent identities |
| Mutation owner | Existing order/refund candidates with before/after period and identity unions |
| Read owner | Period comparison reader; no LiveView raw joins |
| Lifecycle | Same generation as event period rows for each rebuilt bucket |
| Invalidation | Full old/new bucket and old/new dimension identity union; families are never summed |

M5-04A does not create either resource.

#### `AnalyticsContributionFact` (proposed, JC-312 locked contract for M5-04C)

| Field | Planned contract |
| --- | --- |
| Purpose | Durable normalized additive contribution rows for **exact partial-edge** period composition |
| Grain | Event (and later dimension identity) plus currency plus immutable contribution identity |
| Identity | Enough to attribute one additive sale or refund contribution with `effective_at`, sale vs refund role, ticket/product/variation historical identity, and primitive magnitudes |
| Source truth | Written when financial recognition/refund/binding is already resolved; not recomputed from raw history on reads |
| Read owner | Bounded edge composition in period reader/rebuild only; **not** full-window scans when interior fixed buckets exist |
| Lifecycle | Append/replace via the same invalidation seams as period buckets |

JC-312 locks the need for this projection; JC-312 does **not** create the Ash resource or migration.

Coverage metadata is required even when a bucket has no rows. A complete
generation with an explicit empty coverage result means zero activity; absent,
stale, rebuilding, or unavailable coverage means the comparison cannot
fabricate zero. The generation envelope must also bind current and comparison
rows to one captured `now_utc`, timezone, scope/version, and semantic version.

## 6. Period-kind authority matrix

| Period kind | Current boundary rule | Authority | Status |
| --- | --- | --- | --- |
| `today` | Johannesburg civil day containing `now`, `[start, end)` | `TimeRules.today_bounds/2`, M1-07 T17-T20, TIME-G | `LOCKED` (M1-07; unchanged) |
| `today` management comparison (elapsed) | Johannesburg civil midnight today through captured `now` | JC-310 Section 7 | `LOCKED` (M5-04; distinct from M1-07 `:today`) |
| `yesterday` | Preceding Johannesburg civil day, `[start, end)` | `TimeRules.yesterday_bounds/2`, M1-07 T20, TIME-G | `LOCKED` |
| rolling 7 days | Exact UTC `[now - 7*24h, now)` | `TimeRules.last_7_days_bounds/1`, M1-07 T21, TIME-G | `LOCKED` |
| rolling 30 days | Exact UTC `[now - 30*24h, now)` | `TimeRules.last_30_days_bounds/1`, M1-07 T22, TIME-G | `LOCKED` |
| `custom` | Johannesburg civil `[start, end)`, max 90 civil days | `TimeRules.custom_civil_bounds/3`, TIME-G owner decision | `DERIVED_FROM_LOCKED_RULE` for normalization; `OUT_OF_SCOPE` for financial aggregation |

The current boundary authority for preset **current** windows is complete. JC-310 locks **comparison** boundaries in Section 7. Do not silently redefine `TimeRules.today_bounds/2` to mean elapsed-day comparison.

## 7. Locked previous-equivalent-period contract (JC-310)

Owner decision recorded without modification. This section is current M5-04 comparison authority layered on locked M1-07. Do not edit `docs/path-1/m1-07-timestamp-johannesburg-period-and-freshness-contract.md` to retroactively embed these rules.

```text
OWNER_DECISION = APPROVED
COMPARISON_AUTHORITY_LOCKED = YES
M1_07_REWRITE = NO
CUSTOM_COMPARISON = DEFERRED
ONE_CAPTURED_NOW = REQUIRED
```

### 7.1 One captured clock anchor

Exactly one `now_utc` is captured once per comparison operation. Current and previous windows must derive from the same captured `now_utc`, timezone, comparison scope/version, and semantic version. Independent clock reads for current versus previous windows are forbidden. This is required for deterministic boundaries.

### 7.2 Today comparison (management elapsed-day scope)

Canonical M1-07 `:today` remains a **full** Johannesburg civil day. For management period **comparison**, use a separate elapsed-day scope (conceptually `today_to_now`). Do not conflate the two in implementation or API naming.

```text
TODAY_COMPARISON_CURRENT =
  Johannesburg civil midnight today -> captured now

TODAY_COMPARISON_PREVIOUS =
  Johannesburg civil midnight yesterday -> the same elapsed Johannesburg civil-time offset yesterday
```

```text
M1_07 :today = full Johannesburg civil day
M5_04 live comparison scope = elapsed Johannesburg day to captured now
```

### 7.3 Yesterday comparison

Half-open Johannesburg civil boundaries.

```text
YESTERDAY_COMPARISON_CURRENT =
  full Johannesburg civil yesterday

YESTERDAY_COMPARISON_PREVIOUS =
  full Johannesburg civil day immediately before yesterday
```

### 7.4 Rolling 7-day comparison

Using the single captured `now`:

```text
ROLLING_7D_COMPARISON_CURRENT  = [now - 7*24h, now)
ROLLING_7D_COMPARISON_PREVIOUS = [now - 14*24h, now - 7*24h)
```

Exact UTC-duration windows.

### 7.5 Rolling 30-day comparison

Using the same captured `now`:

```text
ROLLING_30D_COMPARISON_CURRENT  = [now - 30*24h, now)
ROLLING_30D_COMPARISON_PREVIOUS = [now - 60*24h, now - 30*24h)
```

Exact UTC-duration windows.

### 7.6 Custom comparison

```text
CUSTOM_COMPARISON = DEFERRED
```

`:custom` financial aggregation remains disabled. The approved 90 Johannesburg civil-day maximum is a future bound only. It does not authorize custom period financial aggregation or custom comparison support. No custom comparison algorithm is specified in JC-310.

### 7.7 Locked comparison matrix

| Period kind | Current window (comparison scope) | Previous-equivalent window | Status |
| --- | --- | --- | --- |
| Today (elapsed) | JHB midnight today -> captured `now` | JHB midnight yesterday -> same elapsed offset | `LOCKED` |
| Yesterday | Full preceding JHB civil day | Full JHB civil day before that | `LOCKED` |
| Rolling 7 days | `[now - 7*24h, now)` | `[now - 14*24h, now - 7*24h)` | `LOCKED` |
| Rolling 30 days | `[now - 30*24h, now)` | `[now - 60*24h, now - 30*24h)` | `LOCKED` |
| Custom | Financial API rejects `:custom` | Not offered | `DEFERRED` |

### 7.8 Zero and missing semantics

```text
ZERO_BASELINE_RULE =
  percentage unavailable when comparison denominator is zero
```

Forbidden outputs: `Infinity`, `-Infinity`, `NaN`, fabricated `100%`.

```text
MISSING_PROJECTION_RULE =
  only explicitly complete empty coverage means zero
```

The following do **not** mean zero and must fail closed into the appropriate comparison state:

```text
absent
stale
rebuilding
unavailable
currency mismatch
semantic mismatch
incomplete coverage
generation mismatch
```

Do not substitute zero for missing projection data.

### 7.9 Financial invariants unchanged by M5-04

M5-04 comparison authority does **not** alter certified M1-07/M5-03 financial semantics.

**Historical recognition:** `status == "completed" OR completed_at is present`. A later `refunded` / `cancelled` status does not erase historical Gross while completion evidence remains.

**Sale effective time:** `COALESCE(paid_at, completed_at)`.

**Refund effective time:** `Refund.source_created_at`. Refunds remain in their refund-effective period. Do not attribute refunds back into the original sale period.

**Gross:** remains in its original sale-effective period.

**Net:** `Net = Gross - Refund` with no clamp.

**ATV:** derived from rolled additive Net primitives `net_ticket_value / net_ticket_quantity` when mathematically valid. Never sum or average stored ATV values.

**Currency:** each currency is an independent partition. No implicit FX. No cross-currency comparison.

**Dimensions:** `ticket_type`, `source_product`, and `source_variation` remain independent parallel families. Never sum those families together. Historical dimensional identity remains parent `OrderItem` / `Order` source identity, not mutable `ProductMapping`.

```text
HISTORICAL_RECOGNITION_UNCHANGED = YES
REFUND_EFFECTIVE_TIME_UNCHANGED = YES
CURRENCY_PARTITION_UNCHANGED = YES
```

## 8. MVP period-kind decision

```text
PERIOD_MVP = presets only
```

MVP includes `today`, `yesterday`, rolling 7 days, and rolling 30 days. Custom remains disabled even though its 90-day maximum is known. The current rejection of `:custom` remains in force until comparison semantics, authorization, exact placement, bounded reads, and focused tests are approved.

The old pack's 15/30/60-minute windows are not part of the current M5-04 MVP. They require a separate current authority and are not inferred from the roadmap.

## 9. Event and dimensional grain matrix

| Scope | Canonical identity | Period identity | Currency rule | Family rule |
| --- | --- | --- | --- | --- |
| Event | `event_id` | `bucket_kind + bucket_start_utc + bucket_end_utc` | One row set per `Order.currency` | Event totals are not dimension-family totals |
| Ticket type | `event_id + currency + ticket_type_id` | Same bucket identity | Currency comes from parent `Order` | Sum only within the ticket-type family |
| Source product | `event_id + currency + source_system_id + woo_product_id` | Same bucket identity | Currency comes from parent `Order` | Source product is a separate family |
| Source variation | `event_id + currency + source_system_id + woo_product_id + woo_variation_id` | Same bucket identity | Currency comes from parent `Order` | Only non-null historical variations produce rows |

Historical `OrderItem` identities remain authoritative. ProductMapping, names, SKUs, and refund-line product evidence do not rewrite period identity. The three dimensional families must never be summed together.

### 9.1 Recognised order count

Distinct order count is additive across disjoint event time buckets because one recognised order has one selected sale-effective instant. It is not additive across ticket-type, source-product, or source-variation rows because one order can contain multiple lines in multiple dimensions. The MVP permits event-bucket recognised order count only after implementation proves the order clock and bucket replacement rules. Dimensional period rows omit recognised order count until a separate distinct-count contract exists.

## 10. Additive and derived metric matrix

| Metric | Storage decision | Arithmetic and guard |
| --- | --- | --- |
| `gross_ticket_quantity` | Persist additive primitive | Historical recognised ticket quantity; no status regression |
| `refund_ticket_quantity` | Persist additive primitive | Qualifying bound-line refund magnitude; value-only refund contributes zero quantity |
| `gross_ticket_value` | Persist additive primitive | Tax-inclusive `line_total + line_total_tax` in sale bucket |
| `refund_ticket_value` | Persist additive primitive | Positive tax-inclusive qualifying refund magnitude in refund bucket; Net subtracts it |
| `recognised_order_count` | Event bucket only if certified; omit dimensional MVP | Distinct by source-scoped order identity; never sum overlapping dimensions |
| `net_ticket_quantity` | Derived only | `gross - refund`, including negative results |
| `net_ticket_value` | Derived only | `gross - refund`, including negative results |
| `ATV` | Derived only | `net_ticket_value / net_ticket_quantity`; nil or N/A when net quantity is zero |
| Absolute delta | Derived only | `current - comparison` when both operands exist |
| Percentage delta | Derived only | Numeric only for a non-zero comparison denominator |

ATV is never persisted as additive truth, never summed, and never averaged across rows. Percentage values are also never persisted.

### 10.1 Comparison output states (locked public vocabulary)

```text
COMPARISON_STATE_VOCABULARY =
  available
  flat_zero
  new_activity
  baseline_zero
  current_missing
  comparison_missing
  not_comparable
```

| State | Meaning |
| --- | --- |
| `available` | Both operands are available and the comparison denominator is non-zero. Absolute and percentage deltas may be produced. |
| `flat_zero` | Current and comparison metric are both exactly zero within complete comparable projections. Percentage is not required to fabricate a mathematical ratio. |
| `new_activity` | The comparison grain has confirmed complete zero activity while the current grain has positive activity. Absolute delta is available. Percentage is unavailable. Do not fabricate `100%` or infinity. |
| `baseline_zero` | The comparison projection/grain exists and is complete, but the specific comparison metric denominator is zero. Percentage is unavailable. Distinct from missing projection data. |
| `current_missing` | Current projection is absent, stale, rebuilding, unavailable, or otherwise not ready. Do not substitute zero. |
| `comparison_missing` | Previous projection is absent, stale, rebuilding, unavailable, or otherwise not ready. Do not substitute zero. |
| `not_comparable` | Both projections are ready, but comparable identity or scope cannot be established: currency mismatch, grain mismatch, period-scope mismatch, semantic-version mismatch, or **compatible-coverage mismatch** between ready projections. Does not apply to a projection that is itself stale, incomplete, or not ready; those use `current_missing` or `comparison_missing`. No cross-currency comparison. |

### 10.2 Locked comparison-state precedence (JC-310)

Public state selection is deterministic. M5-04B/F **implements** this order; it does not invent alternate precedence.

Evaluate states in strict order; return the first match:

```text
COMPARISON_STATE_PRECEDENCE =

1. current_missing
   Current projection is absent, stale, rebuilding, unavailable,
   incomplete/not-ready, or otherwise unusable.

2. comparison_missing
   Current projection is ready, but previous projection is absent,
   stale, rebuilding, unavailable, incomplete/not-ready, or otherwise unusable.

3. not_comparable
   Both projections are ready, but comparable identity/scope cannot
   be established, including:
   - currency mismatch
   - grain mismatch
   - period-scope mismatch
   - semantic-version mismatch
   - compatible-coverage mismatch (incompatible ready coverage identities/scopes)

4. flat_zero
   Both projections are complete and comparable;
   current metric == 0 and comparison metric == 0.

5. new_activity
   Both projections are complete and comparable;
   comparison grain has confirmed zero activity;
   current metric > 0.

6. baseline_zero
   Both projections are complete and comparable;
   comparison denominator == 0;
   neither flat_zero nor new_activity applies.

7. available
   Both projections are complete/comparable and
   comparison denominator != 0.
```

Locked ordering rules:

```text
flat_zero PRECEDES baseline_zero
new_activity PRECEDES baseline_zero
readiness states PRECEDE metric-state evaluation
not_comparable PRECEDES percentage/delta state evaluation
STATE_PRECEDENCE_LOCKED = YES
```

When **both** current and comparison projections are unavailable or not ready, **`current_missing` wins** because step 1 is evaluated before step 2. This is intentional, not accidental.

`not_comparable` **compatible-coverage mismatch** means incompatible ready coverage identities or scopes between two ready projections. It does not subsume stale, incomplete, rebuilding, or unavailable coverage; those fail closed through `current_missing` or `comparison_missing` first.

No infinity, NaN, or fabricated 100% result is permitted. See Section 7.8 for zero-baseline and missing-projection rules.

## 11. Resource alternatives

### A. Extend existing current/lifetime snapshots

```text
DECISION = REJECT
```

Adding period identity to `EventAggregateSnapshot` breaks its certified uniqueness `(event_id, currency)`, v2 reader contract, and current hot-cache key. Adding period identity to `EventDimensionAggregateSnapshot` mixes lifetime rows and period rows under partial family indexes and makes generation/refresh semantics ambiguous. Both are current/lifetime projections, not time-series storage.

Performance remains bounded only if every reader carries extra bucket predicates. Migration requires semantic versioning and re-certification of all existing readers. Concurrency would couple lifetime refresh and period rebuilds. This is more risk than reuse provides.

### B. Rehabilitate or version `DailySalesAggregateSnapshot`

```text
DECISION = REJECT
```

Daily v1 has scalar legacy fields, a completed-at refresh path, no canonical refund primitive contract, no exact sale/refund placement, and no comparison identity. Silently reusing `total_sold`, `total_revenue`, `today_sold`, or `today_revenue` would redefine existing fields. A new version would still need a separate dimensional projection and rolling-boundary strategy. Leave v1 as compatibility data and create a new projection family.

### C. New canonical additive time-bucket projection

```text
DECISION = RECOMMEND / NEW
```

The proposed `EventPeriodAggregateSnapshot` and `EventDimensionPeriodAggregateSnapshot` store only additive primitives keyed by event, currency, fixed bucket identity, and required dimension identity. Net, ATV, deltas, and percentages remain reader-derived. Event and dimension rows share a generation token for a coherent refresh.

Performance is bounded by requested event, currency, bucket count, and dimension cardinality. Reads avoid raw `Order`, `OrderItem`, `Refund`, and `RefundLine` queries. Rebuilds may run bounded SQL in Oban. Migration is additive and does not change lifetime v2 rows or Daily v1. The unresolved design point is the atomic bucket resolution required to represent exact rolling windows without overcounting a partial boundary bucket.

### D. Request-time composition from `EventAggregator` only

```text
DECISION = REJECT AS FINAL M5-04 ARCHITECTURE
```

The current event period SQL is bounded, indexed, and useful as semantic parity evidence or a bounded pre-projection bring-up reference. It has no dimensional period API. A request-time dimensional implementation would multiply aggregate work for each comparison and family and would put raw-history work on the interactive path. That does not prove safety for management concurrency. It must not be the final management reader. Any temporary use is restricted to certification or an explicitly approved bounded bring-up path with EXPLAIN evidence.

## 12. Chosen architecture

The target architecture is a new additive time-bucket projection family in cold Postgres:

```text
Order / OrderItem / Refund / RefundLine
        ↓ effective-time and identity-aware rebuild
EventPeriodAggregateSnapshot
EventDimensionPeriodAggregateSnapshot
        ↓ one coherent generation
PeriodComparisonReader
        ↓ policy, readiness, derivation, redaction
management caller
```

The existing `EventAggregator.financial_summaries_for_event_period/2` remains the event-level semantic reference and can be used for parity or a temporary, explicitly approved bring-up check while the projection is certified. It is not a final interactive fallback and is not replaced by a second financial formula. Period-aware dimensional code must reuse `DimensionAggregator` recognition, refund, binder, currency, and identity rules.

### 12.1 Rolling-edge contract (locked in JC-312 / M5-04B)

Exact rolling windows end at an arbitrary captured UTC instant. Johannesburg civil-day buckets alone, UTC hour buckets alone, or UTC minute buckets alone cannot represent every approved window without rounding captured `now`, which is forbidden.

```text
ROLLING_EDGE_STRATEGY = FIXED_INTERIOR_BUCKETS_PLUS_DURABLE_EXACT_CONTRIBUTION_EDGE
INTERIOR_BUCKET_KIND = UTC hour buckets for fully covered rolling interior spans; Johannesburg civil-day buckets where a period is a full civil day
EDGE_SOURCE = durable normalized contribution projection (future AnalyticsContributionFact)
MAX_EDGE_SCOPE = partial leading/trailing buckets only; never scan contributions across full 7/30-day interiors when complete interior buckets exist
RAW_HISTORY_INTERACTIVE_READ = FORBIDDEN on management comparison path
```

**Accepted topology:**

```text
durable normalized contribution facts
              ↓
        exact effective_at
              ↓
   ┌──────────┴───────────┐
   ↓                      ↓
fixed aggregate buckets   exact partial-edge reads
(UTC hour / JHB day)      (contribution projection)
   ↓                      ↓
   └──────── composition ─┘
              ↓
       exact period result
```

**Rejected alternatives (JC-312):**

| Alternative | Why rejected |
| --- | --- |
| Single fixed bucket resolution only (hour/day/minute) | Cannot end at arbitrary captured `now` without rounding or unstable request-specific bucket identities |
| Request-specific aggregate fragments | Unbounded/unstable bucket identities; rebuild and read contracts explode |
| Raw `Order` / `OrderItem` / `Refund` / `RefundLine` edge reads on interactive path | Violates M5 management read contract; financial logic must be resolved at write time |
| Full-window contribution scans | Query cost scales with window width and cardinality; interior fixed buckets must absorb bulk span |

M5-04C implements fixed-bucket period snapshots **plus** the durable contribution projection required for exact edge composition. M5-04G must certify edge-query cost, rebuild cost, latency, connection use, and fan-out before any scale claim.

## 13. Lifecycle and state machines

### 13.1 Projection lifecycle

Use the existing M5-01/M5-02 lifecycle vocabulary without adding a persisted state enum unless metadata proves insufficient:

```text
ABSENT
  └─ successful complete generation ─> CURRENT
CURRENT
  └─ relevant durable mutation ─> STALE / REFRESH_PENDING
STALE / REFRESH_PENDING
  └─ worker claims event fence ─> REBUILDING
REBUILDING
  ├─ commit complete event+dimension generation ─> CURRENT
  └─ rollback or retryable failure ─> STALE (old generation retained)
ABSENT or STALE
  └─ required source/projection unavailable ─> UNAVAILABLE
```

| Transition | Guard | Durable effect | Recovery |
| --- | --- | --- | --- |
| Absent to current | All event and dimensional rows build successfully | Insert one complete generation in a transaction | Retry from durable source facts |
| Current to stale | B23 candidate resolver reports a relevant before/after mutation | Persist refresh intent after source transaction | Oban uniqueness coalesces pending work |
| Pending to rebuilding | Existing worker and per-event fence | No partial publish | Retry on worker failure |
| Rebuilding to current | Old/new buckets replace and generation validates | Commit, invalidate cache, broadcast PubSub | Reader accepts generation only after commit |
| Rebuilding to stale | Aggregation, validation, or persistence fails | Roll back; preserve prior generation | Oban retry or bounded operator rebuild |
| Any to unavailable | Required clock, currency, identity, or generation is missing | Return explicit unavailable/readiness result | Correct source or complete rebuild |

There is no terminal projection state. A prior coherent generation remains distinguishable from an in-progress or failed generation.

### 13.2 Coherent read and write

The writer replaces all affected event and dimension rows under the existing event advisory fence and one transaction. The reader uses coherent transaction options and accepts only one matching generation for the requested current and comparison buckets. Generation mismatch, orphan currency, or missing required family fails closed. The reader must not assemble one result from mixed generations.

## 14. Mutation and invalidation matrix

Every row below invalidates the union of before and after identities. A mutation that changes a period or dimension is never handled by one-sided invalidation.

| Mutation | Before event/bucket | After event/bucket | Before dimension identity | After dimension identity | Required action |
| --- | --- | --- | --- | --- | --- |
| New recognised sale | None | Sale-effective bucket | None | Ticket type/product/variation on line | Rebuild new event bucket and present family rows |
| Historical recognition predicate true to false | Prior sale-effective bucket | None | Prior historical line identities | None | Remove sale primitives only when `status == completed OR completed_at is present` changes from true to false; retain source evidence and mark coverage/readiness accordingly |
| Historical recognition predicate false to true | None | Selected sale-effective bucket | None | Historical line identities | Rebuild the new event and dimensional buckets; evaluate the full predicate because `status == completed` is sufficient while a non-completed status label alone is not |
| Completed to refunded or cancelled with `completed_at` retained | Same sale-effective bucket | Same sale-effective bucket | Same historical line identities | Same historical line identities | Financial recognition remains true; Gross and sale-period primitives are unchanged. Operational status context may change separately |
| `paid_at` or `completed_at` correction | Old selected sale bucket | New selected sale bucket | Same unless line also changed | Same unless line also changed | Rebuild both old and new buckets |
| Selected sale clock removed | Prior selected sale bucket | None | Prior historical line identities | None | Remove sale primitives and fail closed for the affected source fact |
| Event attribution correction A to B | Event A sale bucket | Event B sale bucket | Event A keys | Event B keys | Rebuild both events and identities |
| Ticket type correction | Same event bucket | Same event bucket | Old `ticket_type_id` | New `ticket_type_id` | Rebuild old/new ticket rows and event if primitives changed |
| Product/variation correction | Same event bucket | Same event bucket | Old source tuple | New source tuple | Rebuild old/new family rows; do not read current mapping |
| Currency correction | Old currency bucket | New currency bucket | Old currency family rows | New currency family rows | Rebuild both currency partitions; never merge or fabricate FX |
| Same-identity quantity/value/tax correction | Same bucket | Same bucket | Same historical identities | Same historical identities | Replace the bucket even when identity is unchanged |
| New recognised sale with missing clock | No authority | None | None | None | Persist source fact but withhold period projection/readiness |
| New refund | None | Refund `source_created_at` bucket | None | Exact bound parent identities | Rebuild event and qualifying families |
| Refund effective correction | Old refund bucket | New refund bucket | Same parent identities | Same parent identities | Rebuild both old and new refund buckets |
| Refund effective clock removed | Prior refund bucket | None | Prior qualifying keys | None | Remove refund primitives from the old bucket and fail closed |
| Refund amount/tax correction | Same refund bucket | Same refund bucket | Same qualifying keys | Same qualifying keys | Replace refund primitives in the same bucket |
| Refund active to voided | Prior active bucket | None | Prior qualifying keys | None | Rebuild old bucket; preserve sale Gross |
| Refund unresolved to complete | None | New refund bucket | None | Exact qualifying keys | Rebuild new bucket |
| Refund complete to unresolved | Prior refund bucket | None | Prior qualifying keys | None | Rebuild old bucket and remove refund primitives |
| Binder correction | Prior unallocated/old parent bucket | New exact parent bucket | Prior parent or none | New parent identity | Rebuild every before/after event and bucket |
| Value-only refund | None | Refund bucket | None | Exact bound parent identities | Refund value changes, refund quantity remains zero |
| Exact replay | Same | Same | Same | Same | No new generation or invalidation |
| Historical backfill/catch-up | All known old identities/buckets | All new identities/buckets | Union of old keys | Union of new keys | Batch affected unions; never global flush |

The event row is refreshed when its additive result changes or when the same-event detector reports a relevant historical line change, even if a coincidental total is unchanged. This preserves the M5-01 B23 rule.

## 15. Concurrency and transaction model

M5-04 should compose with the existing same-event advisory fence rather than introduce a global lock.

| Race | Required behavior |
| --- | --- |
| Same-event concurrent rebuilds | Serialize through the existing event fence; the later complete generation wins. |
| Overlapping bucket rebuilds | Claim one event fence and replace the affected old/new bucket union in one transaction. |
| Sale and refund race | Source transactions enqueue refresh intent; the worker reads committed source state and rebuilds both financial families without joining sale and refund rows into one multiplicative query. |
| Refund transition during rebuild | Re-read committed refund status and exact parent-line binder inside the fenced transaction; stale active or unresolved rows cannot survive a complete replacement. |
| Backfill while live sales continue | Backfill uses the same event fence and generation contract. It may be batched by event, but must not publish partial event/dimension generations. |
| Old/new bucket invalidation race | Candidate resolution carries both identities. A later correction cannot remove only the new bucket or only the old bucket. |
| Multi-node workers | Oban uniqueness plus the database fence coalesces duplicate intent and serializes per-event replacement across nodes. |

The known residual risk remains: dense same-event advisory-lock waiters can occupy database connections. M5-04 does not replace that pattern with a global lock. A later implementation slice may measure queue depth and connection pressure, but no redesign is authorized here.

The rebuild transaction must:

1. claim the existing event fence;
2. resolve the complete before/after event and dimension bucket union;
3. query committed source facts with separate sale and refund paths;
4. delete or replace only the affected projection identities;
5. write event and dimensional rows with one generation token;
6. commit before cache invalidation and PubSub;
7. release the fence.

## 16. Authorization and read boundary

The period reader must preserve the existing security ordering:

```text
UUID validation
-> event authorization
-> period and currency validation
-> projection readiness/generation checks
-> one coherent projection read
-> metric derivation
-> revenue redaction
```

`Policies.can_view_revenue?/2` controls every monetary current, comparison, and delta field. When revenue is hidden, the reader must not leak gross value, refund value, net value, ATV, or monetary deltas through an alternate field or comparison state. Ticket quantities may remain visible only according to the existing event dashboard policy.

The reader must not perform raw `Order`, `OrderItem`, `Refund`, or `RefundLine` work before policy checks. It must return no PII and must not use catalogue names as historical identity. A missing current or comparison projection is a readiness/result state, not an instruction to fall back silently to an unbounded raw-history query.

## 17. Hot, warm, and cold architecture

| Layer | Proposed role | 100k-concurrent-user assessment | Calls and invalidation |
| --- | --- | --- | --- |
| COLD | Postgres source truth, future durable contribution projection, future durable fixed-bucket aggregate projections | Safe only through indexed projection reads and bounded batch rebuilds; no dashboard raw-history scans | Source mutations and completed generations are authoritative |
| HOT | ETS/`DashboardCache` for high-demand current summaries only | Useful for repeated current reads; not period truth and not required for correctness | Invalidate after commit; no per-dimension database call |
| WARM | Existing Redis snapshot adapter only if measured read demand requires it | Not justified by this planning evidence; never the durable source | One project/environment namespace, explicit TTL, generation-aware replacement |
| REALTIME | Phoenix PubSub and LiveView push | Pushes committed generation notifications; browser polling remains out of scope | Broadcast after commit on an event-scoped topic |
| HEAVY REBUILD | Existing Oban `RefreshSnapshotWorker` seam | Asynchronous and bounded by event/bucket work; no new scheduler | Transactional intent and uniqueness coalesce duplicate work |

The interactive path must use one projection query for event rows and one bounded batched query for each requested dimensional family, or an equivalent set-based query. Query count must not grow with the number of dimension rows. The reader must not calculate each row with an individual database call. A bounded edge read, if approved in M5-04B, reads a durable contribution projection rather than raw financial history and remains part of the projection read contract.

## 18. TTL, invalidation, and PubSub rules

The durable period projection has no correctness TTL. A row is current, stale, rebuilding, or unavailable by generation metadata and source invalidation, not by wall-clock expiry.

If a period result is cached:

- the cache key includes event, currency, current/comparison period identity, dimension family, authorization-relevant scope, and generation;
- the value is invalidated only after the durable replacement transaction commits;
- a generation mismatch is a miss, never a reason to serve a mixed result;
- cache stampedes are prevented with the existing event-scoped refresh/coalescing seam, not a global mutex;
- Redis remains optional and must not be added without measured need;
- any Redis TTL must be explicit, project/environment scoped, and shorter than the acceptable freshness window.

PubSub publishes an event-scoped committed-generation notification after the transaction. LiveView clients push a refresh or payload update from that notification. No polling loop is part of the design.

## 19. Query and index audit

Current repository evidence is sufficient for the existing event-level period source and current dimensional rebuilds:

- `EventAggregatorFinancialQueryPlanTest` proves selective sale and refund period paths use bounded indexed plans and reject broad sequential scans for the certified fixture.
- `DimensionAggregatorQueryPlanTest` proves the six current dimensional gross/refund paths are bounded for the selective fixture.
- M5-03 reconciliation tests prove exact refund binders, identity predicates, and currency predicates are present in the current query paths.

The period projection write path is not yet implemented, so there is no honest EXPLAIN evidence for its bucket replacement query. M5-04B must add selective fixtures and plan assertions before proposing an index.

```text
INDEX_DECISION = NONE (JC-312 / M5-04B)
REDIS_DECISION = NONE (JC-312 / M5-04B)
CACHE_CHANGE = NONE (JC-312 / M5-04B)
WORKER_CHANGE = NONE (JC-312 / M5-04B)
```

No new index is justified by M5-04A or JC-312 B kernels. Any future index requires all of:

```text
selective fixture
EXPLAIN evidence on the actual critical path
measured deficiency against the existing indexes
```

The current read target is projection-only. The bounded EventAggregator SQL remains a semantic parity and bring-up reference, not a reason to add an index speculatively.

## 20. Performance and scaling review

The proposed projection is the only architecture in this plan that can satisfy the roadmap's pre-aggregated management-read intent for event and dimensional comparisons without raw-history work on every request. It still requires measurement before a 100k-concurrent-user claim:

- current reads are fixed by requested family and bucket count, not by one database call per row;
- event and dimensional projection reads are set-based and currency-partitioned;
- rebuilds are asynchronous, event-scoped, and bounded to affected old/new bucket identities;
- source history is not scanned on the interactive dashboard path;
- Net, ATV, deltas, and percentages are cheap deterministic reader derivations;
- a Redis representation is optional and has no correctness role;
- a cache stampede cannot publish incomplete generations;
- exact rolling boundary composition uses hybrid interior buckets plus bounded contribution edge reads (JC-312); physical resources deferred to M5-04C+;

`EventAggregator.financial_summaries_for_event_period/2` is suitable for a bounded event-level comparison experiment and certification oracle. It is not sufficient evidence for dimensional period comparison at management concurrency and is not an interactive raw-history fallback. M5-04G must measure projection read latency, rebuild latency, connection use under fence contention, cache hit/miss behavior if enabled, and PubSub update fan-out before making a scale claim.

## 21. Gap ledger

| Gap | Evidence | Impact | Smallest resolution |
| --- | --- | --- | --- |
| ~~Previous-equivalent mapping is not locked in current authority~~ | JC-310 Section 7 | ~~Blocks comparison period kernel~~ | **Resolved (JC-310)** |
| Exact bucket strategy for rolling windows is not locked | ~~Current rolling windows end at arbitrary UTC instants~~ | ~~Blocks canonical bucket identity~~ | **Resolved (JC-312)** — hybrid fixed interior + durable contribution edge; implement in M5-04C |
| Custom financial aggregation is disabled | EventAggregator rejects `:custom`; only civil-bound normalization is certified | Blocks custom MVP and custom comparisons | `CUSTOM_COMPARISON = DEFERRED` until separately authorized |
| ~~Public comparison-state vocabulary is not locked~~ | JC-310 Sections 10.1–10.2 | ~~Blocks stable reader contract~~ | **Resolved (JC-310)**; precedence locked in Section 10.2 |
| Distinct-order dimensional semantics are not additive | One order can span multiple dimensions | Blocks dimensional recognized-order count | Omit dimensional count or define a separate non-additive contract |
| Period write-query plans do not exist | No period projection resource or rebuild SQL is implemented | Blocks index decision and write certification | Implement selective proof in M5-04D/E |
| Period readiness metadata is not yet represented | Existing readers have generation checks but no period resource | Blocks coherent period read implementation | Reuse generation pattern in the approved resource slice |

## 22. Owner decisions (JC-310 recorded)

```text
OWNER_DECISION_REQUIRED = NO
OWNER_DECISION = APPROVED
COMPARISON_AUTHORITY_LOCKED = YES
M5_04B_AUTHORIZATION_PENDING_MERGE = NO
JC_312_STATUS = IN_REVIEW after PR open
```

Remaining gates after JC-312 merge:

1. M5-04C additive period resources, **contribution projection**, and migration.
2. M5-04D/E rebuild and invalidation with hybrid composition.
3. M5-04F reader and M5-04G certification (latency, edge-query cost, rebuild cost, connection use, fan-out).

Do not bypass the contribution projection when implementing exact rolling edges in C+.

## 23. M5-04B+ implementation sequence

The following sequence is conditional. Each phase starts only after the preceding authority and certification gates pass.

### M5-04B - comparison kernel and boundary contract (JC-312)

Scope: **shipped on branch** — owner-approved previous mapping (Section 7), captured-now behavior, comparison states (Section 10.1–10.2), decimal comparison arithmetic, rolling-edge architecture lock (Section 12.1). No Ash resources or migrations.

```text
TIME_COMPARISON_API = TimeRules.comparison_windows/3
COMPARISON_HELPER_API = MetricRules.projections_comparable?/2, classify_comparison_state/1, derive_comparison_deltas/3
ROLLING_EDGE_STRATEGY = FIXED_INTERIOR_BUCKETS_PLUS_DURABLE_EXACT_CONTRIBUTION_EDGE
M5_04B_AUTHORIZATION_PENDING_MERGE = NO
PRODUCTION_RESOURCE_CHANGE = NONE
MIGRATION = NONE
NEW_INDEX = NONE
REDIS_DECISION = NONE
CACHE_CHANGE = NONE
WORKER_CHANGE = NONE
```

Changed files (JC-312):

```text
lib/event_sales/analytics/time_rules.ex
lib/event_sales/analytics/metric_rules.ex
test/event_sales/analytics/time_rules_test.exs
test/event_sales/analytics/metric_rules_test.exs
test/event_sales/analytics/pre_m5_time_certification_test.exs
docs/development/m5-04-period-comparisons.plan.md
```

```text
M1_07_REWRITE = NO
CUSTOM_COMPARISON = DEFERRED
```

### M5-04C - additive period resources, contribution projection, and migration

Scope: add the approved event and dimensional period resources, **durable normalized contribution facts for exact edge composition**, exact identity, generation/freshness metadata, and migration. Persist primitives only.

Likely files:

```text
lib/event_sales/analytics/resources/event_period_aggregate_snapshot.ex
lib/event_sales/analytics/resources/event_dimension_period_aggregate_snapshot.ex
lib/event_sales/analytics.ex
priv/repo/migrations/*_create_period_aggregate_snapshots.exs
```

Do not alter the identity or semantics of `EventAggregateSnapshot`, `EventDimensionAggregateSnapshot`, or Daily v1.

### M5-04D - event period rebuild and invalidation

Scope: build event additive buckets, exact old/new invalidation, refund independence, source-clock fail-closed behavior, generation replacement, and Oban refresh integration.

Likely files:

```text
lib/event_sales/analytics/aggregators/event_aggregator.ex
lib/event_sales/analytics/snapshot_refresh.ex
lib/event_sales/analytics/workers/refresh_snapshot_worker.ex
lib/event_sales/ingestion/historical_order_mutation_detector.ex
lib/event_sales/ingestion/historical_refund_mutation_detector.ex
lib/event_sales/ingestion/historical_coverage_invalidator.ex
lib/event_sales/ingestion/historical_refund_coverage_invalidator.ex
test/event_sales/analytics/event_aggregator_test.exs
test/event_sales/analytics/event_aggregator_financial_query_plan_test.exs
```

Separate sale and refund query paths. Add selective EXPLAIN evidence before any index proposal.

### M5-04E - dimensional period rebuild and reconciliation

Scope: ticket-type, source-product, and source-variation rows as parallel families; exact historical identity; refund-line binder; no cross-family summation; batch reads.

Likely files:

```text
lib/event_sales/analytics/aggregators/dimension_aggregator.ex
lib/event_sales/analytics/snapshot_refresh.ex
lib/event_sales/analytics/dimension_snapshot_reader.ex
test/event_sales/analytics/m5_04_period_dimension_reconciliation_test.exs
test/event_sales/analytics/dimension_aggregator_query_plan_test.exs
```

Dimensional recognized-order count remains out of scope unless separately certified as non-additive-safe.

### M5-04F - reader, comparison derivation, policy, and redaction

Scope: UUID/auth/readiness ordering, coherent current/comparison generation read, currency partition, primitive derivation, percentage guards, and monetary redaction.

Likely files:

```text
lib/event_sales/analytics/period_comparison_reader.ex
lib/event_sales/analytics/snapshot_reader.ex
lib/event_sales/analytics/dimension_snapshot_reader.ex
lib/event_sales/accounts/policies.ex
lib/event_sales_web/live/admin/dashboard_live.ex
lib/event_sales_web/live/admin/event_detail_live.ex
test/event_sales/analytics/period_comparison_reader_test.exs
```

No raw-history fallback on the interactive path. UI design remains outside M5-04A and should not be pulled into F beyond the reader contract.

### M5-04G - reconciliation, performance, and certification

Scope: historical backfill/catch-up, concurrency races, exact replay, late refunds, query plans, freshness, cache behavior if justified, PubSub notifications, and management-read load evidence.

Likely files:

```text
test/event_sales/analytics/m5_04_period_reconciliation_test.exs
test/event_sales/analytics/m5_04_period_query_plan_test.exs
test/event_sales/analytics/m5_04_period_concurrency_test.exs
docs/evidence/m5-04-period-comparisons-certification.md
```

This phase is the first point at which a scale statement or optional Redis representation can be considered.

## 24. File-level scope

### M5-04A (JC-309, merged)

```text
CHANGED_FILES = docs/development/m5-04-period-comparisons.plan.md (initial audit)
```

### JC-310 (this slice)

```text
CHANGED_FILES = docs/development/m5-04-period-comparisons.plan.md
PRODUCTION_CODE_CHANGE = NONE
TEST_CHANGE = NONE
MIGRATION = NONE
INDEX = NONE
DEPENDENCY = NONE
CACHE_CHANGE = NONE
REDIS_CHANGE = NONE
WORKER_CHANGE = NONE
SCHEDULER_CHANGE = NONE
UI_CHANGE = NONE
```

The generated indexes and manifests are intentionally untouched:

```text
INDEX.md
docs/architecture/domain_map.json
docs/architecture/module_manifest.json
```

## 25. Test and certification strategy

M5-04A focused validation:

```text
git diff --check
git status --short
git diff --name-only <BASE_SHA>...HEAD
```

JC-310 validation base:

```text
git diff --name-only 89c19bacbb48b29b0e372d31fa544f316de029e8...HEAD
```

Expected: exactly `docs/development/m5-04-period-comparisons.plan.md`.

No production test or migration is required for the plan itself. Conditional implementation certification must cover, at minimum:

- all four preset boundary mappings with one captured `now`;
- owner-approved previous-period semantics and explicit custom behavior;
- historical recognition predicate transitions, including selected-clock removal;
- completed to refunded/cancelled with `completed_at` retained leaves financial recognition and original sale-period Gross unchanged while the refund remains independently placed by `Refund.source_created_at`;
- sale paid-at precedence and completed-at fallback;
- missing sale/refund clocks fail closed;
- gross in sale period and late refund in refund period;
- positive refund magnitudes and same-identity quantity/value/tax corrections;
- normal, value-only, voided, unresolved-to-complete, complete-to-unresolved, binder-correction, header-only, and exact-replay refunds;
- event and all three dimensional families without cross-family totals;
- currency mismatch and absent-comparison states without fabricated zero;
- before/after bucket and identity invalidation;
- generation coherence under concurrent rebuild and reader access;
- authorization before expensive financial work and complete monetary redaction;
- selective EXPLAIN evidence for every new write/read critical path;
- bounded backfill and no raw-history interactive query;
- PubSub after commit and cache invalidation after commit if a cache is approved.

## 26. Risks and STOP conditions

### Risks

- A stale comparison pack may be mistaken for current product authority.
- A bucket resolution that cannot represent exact rolling edges may silently double-count or omit facts.
- Dimensional recognized-order counts may appear plausible while being non-additive.
- A fallback to bounded event SQL may be mistaken for proof of dimensional management-scale safety.
- A cache or Redis mirror may be introduced before measurement and become an accidental source of truth.
- Dense same-event advisory waiters may increase database connection pressure during backfill.

### STOP conditions

Stop the slice if any of the following occurs:

1. `origin/main` moves from the slice's accepted SHA/tree.
2. ~~Previous-equivalent semantics remain unapproved or current authority still conflicts with the candidate contract.~~ Cleared by JC-310 when merged; do not regress Section 7 semantics.
3. Custom must be enabled but its period, authorization, and bounded-read semantics are not locked.
4. Event, currency, period, or dimension identity cannot be represented without double-counting.
5. Correctness would require persisted Net, ATV, or percentage values.
6. ATV would be summed or averaged.
7. Late refunds require rewriting original Gross period history.
8. Effective-time corrections cannot invalidate both old and new buckets.
9. The management read path needs raw unbounded financial history.
10. Query count grows with dimension cardinality.
11. A new index lacks selective EXPLAIN proof.
12. Redis, cache, worker, scheduler, or UI work is proposed without current-slice authority and measured need.
13. M1-07 or M5-03 semantics need to change.
14. Production code, tests, migrations, or generated architecture files become necessary in M5-04A.
15. A secret, production endpoint, remote database, or non-local WordPress target is encountered.

For M5-04A, stop condition 2 was active until JC-310. JC-310 merge cleared comparison-semantics blocker. JC-312 locks rolling-edge architecture; C+ must implement without revisiting period semantics.

```text
STOP_CONDITION_TRIGGERED = NONE
IMPLEMENTATION_READY = M5-04C after JC-312 merge
M5_04B_AUTHORIZATION_PENDING_MERGE = NO
ROLLING_EDGE_STRATEGY = FIXED_INTERIOR_BUCKETS_PLUS_DURABLE_EXACT_CONTRIBUTION_EDGE
```

## 27. Verdict

M5-04A audited the repository, identified the comparison-authority conflict, and rejected Daily v1 rehabilitation and an unbounded request-time comparison reader. JC-310 records the approved previous-equivalent contract without modifying M1-07. JC-312 implements pure comparison kernels and locks hybrid rolling-edge architecture. The target remains a new additive event/dimensional time-bucket projection plus durable contribution edge reads, with projection-only comparison derivation.

```text
DAILY_V1_DECISION = LEGACY / NON-CANONICAL FOR M5 PERIOD REPORTING
CANONICAL_PERIOD_SOURCE = TimeRules + EventAggregator for current preset semantics; future approved additive period projection for management comparisons
PERIOD_MVP = today, yesterday, rolling 7 days, rolling 30 days
CUSTOM_RANGE_DECISION = DEFERRED; keep EventAggregator :custom rejection in force
CUSTOM_COMPARISON = DEFERRED
M1_07_REWRITE = NO
OWNER_DECISION_REQUIRED = NO
OWNER_DECISION = APPROVED
COMPARISON_AUTHORITY_LOCKED = YES
M5_04B_AUTHORIZATION_PENDING_MERGE = NO
ROLLING_EDGE_STRATEGY = FIXED_INTERIOR_BUCKETS_PLUS_DURABLE_EXACT_CONTRIBUTION_EDGE
ROLLING_EDGE_IMPLEMENTATION_DEFERRED_TO = M5-04C
IMPLEMENTATION_READY = M5-04C (resources/migrations) after JC-312 merge
```

The smallest next action after JC-312 merge is M5-04C: create approved fixed-bucket period resources, the durable contribution projection, migration, and rebuild/read paths—without revisiting comparison period semantics or storage model choice.
