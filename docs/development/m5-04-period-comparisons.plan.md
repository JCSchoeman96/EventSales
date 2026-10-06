# M5-04 period comparisons plan (M5-04A audit + JC-310 authority + JC-312 kernel + JC-314 schema + JC-317 event projection)

> JC-309 audited conformance. JC-310 records locked owner comparison semantics. JC-312 (M5-04B) implements the pure comparison time/metric kernels and locks exact rolling-edge architecture. JC-312 merged as PR #287. JC-314 (M5-04C) adds the three schema resources and generated migration only.

### Revision log

- `v1` — M5-04A audit (JC-309)
- `v2` — JC-310 owner comparison authority merged to `main`
- `v3` — JC-312 comparison kernels, rolling-edge lock, M5-04C contribution contract (this revision)
- `v4` — JC-312 review correction: durable generation/readiness coherence, locked AnalyticsContributionFact contract, request-anchor scope, PR #287 rebase base
- `v5` — remove stale “one coherent generation” and “unresolved bucket resolution” wording (final re-review doc cleanup)
- `v6` — remove remaining stale design-gate wording; scope generation mismatch to atomic identity sets
- `v7` — record the verified JC-312 merge and JC-314 M5-04C schema names and status
- `v8` — record PR #288 re-authorization, non-empty coverage identity constraints, and corrected D/E/F index authority
- `v9` — record merged JC-314 authority and JC-317 event bucket invalidation, rebuild, and query-plan evidence
- `v10` — correct current C/D authority, record source lock ordering and contribution identity validation, and separate event from dimensional write-query evidence

- `v11` records the verified JC-317 merge and JC-319 dimensional period population and reconciliation.
- `v12` — JC-321 M5-04F `PeriodComparisonReader` and `PeriodReadPlan`, bounded unnest edge reads, policy/redaction tests, and query-plan evidence.
- `v13` — JC-321 review correction: fixed projection scope AND, readiness envelope states, operand metadata coherence, edge envelope coverage, edge metadata fail-closed, decode fix, interior-hour plan fix, ATV nil semantics, EXPLAIN evidence, isolation/RR tests, explicit PostgreSQL `SET TRANSACTION` coherent-read preparation (`prepare_coherent_transaction!/0`), project index regeneration.

**Plan version:** `v13`

```text
PLAN_VERSION = v13
```

**Status:** JC-319 M5-04E merged; JC-321 M5-04F reader correction pass in review (do not merge until CI green)
**Last updated:** 2026-10-04
**Change summary (v13):** Records PR #295 review fixes (S1 isolation, F correctness gates, truthful edge EXPLAIN, PostgreSQL repeatable-read preparation before projection statements, plan v13 metadata); M5-04F durable authority remains pending merge.

**Goal:** Define a canonical, currency-safe period comparison read model for event and required dimensional grains without promoting the legacy daily-v1 snapshot or inventing comparison semantics.

**Architecture:** Keep `TimeRules` and the certified `EventAggregator.financial_summaries_for_event_period/2` as the current semantic and event-level query authorities. The additive Postgres time-bucket resources store event and dimensional primitives; a later projection-only reader will derive Net, ATV, comparison deltas, and percentages. Previous-equivalent comparison semantics are locked by owner decision (JC-310). Exact rolling-edge resolution is durable authority from merged PR #287: `FIXED_INTERIOR_BUCKETS_PLUS_DURABLE_EXACT_CONTRIBUTION_EDGE`. JC-314 provides the schema; JC-317 owns event-period population, invalidation, and bounded replacement, while M5-04E owns dimensional population and M5-04F owns readers.

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

JC-312 PR #287 rebase preflight (unrelated `origin/main` movement PR #285 / JC-311):

```text
REAUTHORIZED_BASE_SHA  = 4404865dc7f29ab6922853253f57d171f6698d36
REAUTHORIZED_BASE_TREE = c5a17ebf3265f753112311687ce5bf3707a0a5be
BASE_MOVEMENT_CLASS    = NON-CONFLICTING / UNRELATED TO JC-312
```

JC-314 PR #289 re-authorization after PR #288 / JC-313:

```text
JC_314_REAUTHORIZED_BASE_SHA  = a641e7a9e9fd25ebffbb10b1ae6cde850c3be78e
JC_314_REAUTHORIZED_BASE_TREE = 0b7b8b22cad31d98e83d35ee80b9dc2cf8255620
BASE_MOVEMENT_CLASS           = NON-CONFLICTING / WP-SOURCE-03 ONLY
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
JC_312_STATUS = MERGED
JC_312_MERGE_SHA = 325b752d41b051a95339234605983f666a907dbc
M5_04B_IMPLEMENTED_ON_BRANCH = YES
M5_04B_DURABLE_AUTHORITY = YES
M5_04C_AUTHORIZED = YES
M5_04C_STATUS = MERGED
JC_314_STATUS = MERGED
JC_314_MERGE_SHA = eebb9a83563e2ce0e40dd9a4e069567d89acd28f
M5_04C_DURABLE_AUTHORITY = YES
ROLLING_EDGE_STRATEGY = FIXED_INTERIOR_BUCKETS_PLUS_DURABLE_EXACT_CONTRIBUTION_EDGE (JC-312)
ROLLING_EDGE_SCHEMA_FOUNDATION = M5-04C
ROLLING_EDGE_POPULATION = JC-317 event period / M5-04E dimensional period
ROLLING_EDGE_READ = M5-04F
STOP_CONDITION_TRIGGERED = NONE
```

### 1.6 JC-314 M5-04C schema authority

JC-312 is merged at `325b752d41b051a95339234605983f666a907dbc`. JC-314 is merged at `eebb9a83563e2ce0e40dd9a4e069567d89acd28f`. Its resource and table names are:

```text
EventPeriodAggregateSnapshot
  analytics_event_period_aggregate_snapshots

EventDimensionPeriodAggregateSnapshot
  analytics_event_dimension_period_aggregate_snapshots

AnalyticsContributionFact
  analytics_contribution_facts
```

Both fixed-bucket resources persist `bucket_kind`, `bucket_start_utc`, `bucket_end_utc`, `bucket_timezone`, `generation_id`, `semantic_version`, `coverage_identity`, `projection_state`, `refreshed_at`, and nullable `source_watermark_at`. Supported bucket kinds are `utc_hour` and `johannesburg_day`. Allowed projection states are `current`, `stale`, `refresh_pending`, `rebuilding`, and `unavailable`.

All three resources require a non-empty string `coverage_identity`, enforced by Ash `min_length: 1` and a named PostgreSQL CHECK constraint. No further string grammar is imposed in M5-04C.

`AnalyticsContributionFact` persists `generation_id`, `semantic_version`, `coverage_identity`, `refreshed_at`, and nullable `source_watermark_at`; it has no `projection_state`. Its unique source identity is `(contribution_kind, source_contribution_id)`, with sale IDs from `OrderItem.id` and refund IDs from `RefundLine.id`.

An `EventPeriodAggregateSnapshot` row in `current` state is the durable completeness envelope for its full event/currency bucket, including an explicit all-zero bucket. No row or a non-current state is missing/not ready, not zero. `AnalyticsContributionFact` absence is not proof of zero; an edge read may treat missing contribution facts as zero only after the containing required event bucket is current and coverage-compatible.

A CURRENT event bucket row, including an all-zero row, is the complete-coverage envelope. An absent or non-CURRENT row is not zero. Contribution facts do not independently indicate complete coverage. JC-314 added schema only; subsequent slices own population, rebuild, readers, and certification.

### 1.7 JC-317 M5-04D event-period projection status

```text
LINEAR = JC-317
JC_314_STATUS = MERGED
JC_314_MERGE_SHA = eebb9a83563e2ce0e40dd9a4e069567d89acd28f
JC_314_MERGE_TREE = 489dc3843679d7477f706a5ab24de1b0310f8674
M5_04C_DURABLE_AUTHORITY = YES
M5_04D_AUTHORIZED = YES
M5_04D_STATUS = MERGED
JC_317_STATUS = MERGED
JC_317_MERGE_SHA = 5f2acf53b97b974f6abf4c3bb271e2e843fc282c
JC_317_MERGE_TREE = c6d58c43499233c22be34cdc0551d0fbae255224
M5_04D_DURABLE_AUTHORITY = YES
M5_04E_AUTHORIZED = YES
M5_04E_STATUS = IN_PROGRESS
M5_04F_AUTHORIZED = NO
```

M5-04D adds these modules:

```text
BUCKET_RULES_MODULE = EventSales.Analytics.PeriodBucketRules
INVALIDATION_MODULE = EventSales.Analytics.PeriodProjectionInvalidator
REFRESH_MODULE = EventSales.Analytics.PeriodProjectionRefresh
```

`PeriodBucketRules` derives exactly one UTC hour and one canonical Johannesburg civil day per qualifying effective instant. Both use half-open intervals; the day bounds reuse `TimeRules.custom_civil_bounds/3`. Source mutations compare captured BEFORE and AFTER contribution truth, then invalidate the exact union of affected buckets. Missing clocks create no synthetic bucket; `AnalyticsReadinessResolver` remains the event-level fail-closed authority through `:effective_time_incomplete` and non-current historical coverage/reconciliation. A recognized, mapped sale with incomplete money fields still invalidates its known bucket; existing event financial completeness checks keep refresh from publishing CURRENT until those fields are repaired.

`EventPeriodAggregateSnapshot.projection_state = :refresh_pending` is durable rebuild intent. Existing rows retain their last completed values and generation while pending. A previously absent bucket receives a zero-valued pending placeholder with its exact bucket, event, currency, semantic-version, and coverage identity. The placeholder is not readable as zero because it is non-CURRENT. A successful transaction replaces pending rows with one CURRENT generation; failure rolls back contribution and bucket writes while leaving previously committed intent pending.

The source transaction uses `EventSnapshotRefreshFence.lock_events_in_transaction/1`, whose transaction advisory locks use the exact event key held by the existing worker session fence. Multi-event IDs are UUID-canonicalized, deduplicated, and sorted before acquisition. The existing event job remains unchanged; `SnapshotRefresh.refresh_event/2` discovers pending rows inside the existing fenced coherent transaction.

```text
SOURCE_MUTATION_LOCK_ORDER = source row locks / accepted source mutation -> HistoricalCoverageFence -> EventSnapshotRefreshFence period transaction lock -> RefreshSnapshotWorker scheduler/enqueue lock
WORKER_EVENT_LOCK = EventSnapshotRefreshFence session advisory lock
```

The refresh reconstructs committed source truth for the union of pending Johannesburg-day windows using separate bounded sale and refund SQL paths. It issues one sale population query and one refund population query per event refresh, plus one affected-fact read; query count does not grow with contribution cardinality.

```text
SALE_POPULATION_QUERY_COUNT = 1
REFUND_POPULATION_QUERY_COUNT = 1
AFFECTED_FACT_READ_COUNT = 1
IDENTITY_VALIDATION_QUERY_COUNT = 0 additional; joins are included in both population queries
```

Sale identity is `(:sale, OrderItem.id)`, refund identity is `(:refund, RefundLine.id)`. Exact-equal facts are untouched, changed facts are replaced, and facts no longer qualifying are deleted. Only pending event buckets are replaced; an empty affected bucket becomes an explicit CURRENT zero bucket.

The sale and refund queries join `catalog_events` and `catalog_ticket_types` for authoritative identity evidence. Normalization fails closed unless:

```text
CONTRIBUTION_IDENTITY_GUARD = set-based / fixed-count fail-closed validation
ticket_type.event_id == contribution.event_id
event.source_system_id == contribution.source_system_id
```

Inconsistent qualifying source rows remain in the query result and return a typed error before contribution or bucket writes.

Selective `EXPLAIN (FORMAT JSON)` tests certify indexed sale and refund population plans and fixed query counts while target contribution cardinality grows. The observed plans did not justify a new index: `NEW_INDEX = NONE`. M5-04D does not populate dimension-period rows, add a reader, alter worker arguments/queues, backfill history, or add cache/Redis/PubSub/UI behavior.

### 1.8 JC-319 M5-04E dimensional period projection

The owner authorized continuation after unrelated WordPress PR #292 moved main. The original preflight matched the required JC-317 merge, with a clean worktree. JC-319 recovered its tracked edits into an isolated worktree and preserved the original checkout and stashes.

```text
LINEAR_M5_04E = JC-319
ORIGINAL_BASE_SHA = 5f2acf53b97b974f6abf4c3bb271e2e843fc282c
ORIGINAL_BASE_TREE = c6d58c43499233c22be34cdc0551d0fbae255224
REAUTHORIZED_BASE_SHA = a8510f1093ca07c16108b70c556c0dbbaff1c024
REAUTHORIZED_BASE_TREE = 7dbf3882aaa2cc477d1aa48eb0807594c17d1499
PERIOD_DIMENSION_AGGREGATOR = EventSales.Analytics.PeriodDimensionAggregator.rows_for_pending_buckets/2
AGGREGATOR_SOURCE = normalized identity-validated M5-04D current_facts
DIMENSION_FAMILIES = ticket_type / source_product / source_variation
VARIATION_RECONCILIATION_RULE = exact variation-bearing contribution subset
DIMENSION_DELETE_QUERY_COUNT = 3
DIMENSION_INSERT_QUERY_COUNT = 1 when rows exist; 0 when dimension-empty
EVENT_DIMENSION_GENERATION_RULE = same transaction, generation_id, semantic_version, coverage_identity, refreshed_at, source_watermark_at
ZERO_BUCKET_DIMENSION_RULE = delete old dimensions; insert none; CURRENT zero event row proves completeness
INDEX_DECISION = no new index; all three actual DELETE plans use existing family partial unique indexes
```

Every contribution participates in ticket type and source product. Only contributions with an exact non-nil variation participate in source variation. Each contribution uses `PeriodBucketRules.for_instant/1` and contributes only to bucket identities present in the pending event set. An unaffected hour stays untouched when its day is pending. Malformed identities or facts outside every pending bucket return a typed error.

Before persistence, ticket type and product each reconcile all four additive quantities and values against D's event totals. Variation reconciles against only variation-bearing contributions. The refresh transaction writes contribution changes, replaces dimensions with three family-specific set deletes and one bulk insert, then marks event buckets CURRENT. Any failure rolls back the entire replacement. Source invalidation still marks only event envelopes; no dimensional pending placeholders are added.

`PeriodDimensionProjectionQueryPlanTest` certifies `Repo.to_sql(:delete_all, query)` with JSON EXPLAIN against 1,200 dimensional noise buckets. The ticket type, source product, and source variation deletes each use their existing partial unique index and avoid sequential scans. Adding 20 distinct target sale grains increases dimensional row count while retaining three deletes, one insert, one sale read, one refund read, and one existing-fact read. Empty replacement performs three deletes and no insert. Exact replay performs no writes. These fixtures certify query shape and count, not final 100k scale.

JC-319 adds no raw financial or ProductMapping reads, invalidation change, worker, Oban arguments, reader, historical backfill, cache, Redis, PubSub, or UI behavior. The lifetime DimensionAggregator contract remains unchanged. M5-04G owns scale certification.

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
7. Publish coherent replacement transactions for affected bucket/contribution identities under the existing event fence.
8. Read only projection components after UUID validation, authorization, readiness checks, and one coherent DB snapshot.
9. Add hot or warm acceleration only after measured demand proves the cold projection read insufficient.

Step 4 is locked by JC-312 on PR #287.

JC-314 implementation preflight:

```text
BASE_SHA  = 325b752d41b051a95339234605983f666a907dbc
BASE_TREE = de43a5247bd3cd08615e3eb5a042845e22e6badd
LINEAR    = JC-314
SCOPE     = M5-04C schema/resources only
```

JC-314 is merged and supplies the durable schema. JC-317 merged event-period population, invalidation, and bounded source queries in PR #291. M5-04E owns dimensional period population, M5-04F owns projection and edge reads, and M5-04G owns certification. Step 1 authority is recorded; do not infer product rules from stale planning packs.

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

### 5.3 Period projection resources (JC-314 schema contract)

The target is a new period projection family, not an extension of current/lifetime rows. Two resources preserve the certified event and dimensional ownership boundaries.

#### `EventPeriodAggregateSnapshot` (JC-314 schema)

| Field | Planned contract |
| --- | --- |
| Purpose | Durable additive event values for a fixed time bucket |
| Grain | `(event_id, currency, bucket_kind, bucket_start_utc, bucket_end_utc)` |
| Identity | Exact event, currency, bucket kind, and UTC bounds only. **Not** `captured_now_utc`. |
| Relationships | `belongs_to :event`; no Product or TicketType relationship |
| Stored fields | Gross/refund quantities and values only; `recognised_order_count` remains deferred until bucket additivity is certified |
| Generation metadata | `generation_id` (one atomic bucket replacement identity), `semantic_version`, `coverage_identity`, `projection_state`, `refreshed_at`, and nullable `source_watermark_at` |
| Source truth | `Order`, `OrderItem`, `Refund`, and `RefundLine`; projection is derived |
| Mutation owner | Existing order/refund/attribution seams through `RefreshSnapshotWorker` and `SnapshotRefresh` |
| Read owner | Period comparison reader after policy/readiness checks |
| Lifecycle | `ABSENT` means no row; persisted states are `current`, `stale`, `refresh_pending`, `rebuilding`, and `unavailable` |
| Invalidation | Every affected before and after event bucket |

#### `EventDimensionPeriodAggregateSnapshot` (JC-314 schema)

| Field | Planned contract |
| --- | --- |
| Purpose | Durable additive values for a bucket at each parallel dimension family |
| Grain | Event plus `ticket_type`, `source_product`, or `source_variation` identity |
| Identity | Event, currency, bucket, dimension kind, and exact historical dimension tuple |
| Relationships | Event plus conditional TicketType/SourceSystem relationships matching M5-02/M5-03 checks |
| Stored fields | Gross/refund quantities and values only |
| Generation metadata | Same `generation_id`, `semantic_version`, `coverage_identity`, `projection_state`, `refreshed_at`, and nullable `source_watermark_at` contract as event period rows; no request `captured_now_utc` in bucket identity |
| Source truth | Historical `OrderItem` identities and exact bound `RefundLine` parent identities |
| Mutation owner | Existing order/refund candidates with before/after period and identity unions |
| Read owner | Period comparison reader; no LiveView raw joins |
| Lifecycle | Same persisted state vocabulary as event period rows; not tied to a single comparison request anchor |
| Invalidation | Full old/new bucket and old/new dimension identity union; families are never summed |

M5-04A did not create either resource. JC-314 adds their schema foundations; it does not populate or read them.

#### `AnalyticsContributionFact` (locked JC-312 contract for M5-04C)

Resource name (conceptual): `AnalyticsContributionFact` (`lib/event_sales/analytics/resources/analytics_contribution_fact.ex`).

JC-312 locked this contract. JC-314 creates the Ash resource and schema only; population and edge reads remain later work.

**Lifecycle:** one durable normalized contribution per resolved source financial contribution. Uniqueness prevents multiple live rows for the same canonical source contribution identity.

**Sale contribution identity**

```text
contribution_kind = :sale
source_contribution_id = OrderItem.id
effective_at = COALESCE(Order.paid_at, Order.completed_at)
```

Historical recognition unchanged: `Order.status == :completed OR Order.completed_at != nil`. A later `refunded` / `cancelled` status does not erase the contribution when durable historical completion remains.

Primitives on a qualifying sale line:

```text
gross_ticket_quantity = historically recognised ticket quantity
gross_ticket_value = tax-inclusive historical sale value
refund_ticket_quantity = 0
refund_ticket_value = 0
```

**Refund contribution identity**

Only an exact qualifying active+complete bound refund line produces a row:

```text
contribution_kind = :refund
source_contribution_id = RefundLine.id
effective_at = Refund.source_created_at
gross_ticket_quantity = 0
gross_ticket_value = 0
refund_ticket_quantity = qualifying refunded quantity
refund_ticket_value = qualifying tax-inclusive refund value
```

Value-only refund (`refund_ticket_quantity = 0`, `refund_ticket_value > 0`) is valid. No clamp.

**Refund exclusions (no allocated financial contribution row)**

```text
reference_only refund detail
unresolved refund detail
header-only amount without exact line attribution
missing exact parent OrderItem binder
voided refund
```

Transitions:

```text
active+complete -> voided     => remove/replace prior contribution (BEFORE+AFTER invalidation)
active+complete -> unresolved => remove/replace prior contribution
unresolved -> complete        => add contribution
exact replay unchanged truth  => no semantic change
```

**Required fields (JC-314 schema)**

```text
id

contribution_kind
source_contribution_id

event_id
currency
effective_at

ticket_type_id

source_system_id
woo_product_id
woo_variation_id

gross_ticket_quantity
gross_ticket_value
refund_ticket_quantity
refund_ticket_value

semantic_version
coverage/readiness metadata per approved projection lifecycle

inserted_at
updated_at
```

**Historical dimension identity at write time (all columns on the row)**

```text
ticket_type family: ticket_type_id
source_product family: source_system_id + woo_product_id
source_variation family: source_system_id + woo_product_id + woo_variation_id (non-null variation only)
```

ProductMapping, display names, SKUs, or current catalogue bindings must never rewrite contribution history. Edge aggregation groups each family set-wise without another raw source join.

**Edge query contract**

Set-based reads only:

```text
event + currency + effective_at range
```

plus grouped sums for `ticket_type`, `source_product`, and `source_variation`. Query count must not grow with dimension row cardinality.

Coverage metadata is required even when a bucket has no rows. A complete
generation with an explicit empty coverage result means zero activity; absent,
stale, rebuilding, or unavailable coverage means the comparison cannot
fabricate zero. Request-scoped comparison metadata binds `captured_now_utc`,
timezone, scope/version, and semantic version for **bounds derivation and reader
orchestration only**. It is not part of reusable fixed-bucket or contribution
row identity.

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
refresh_pending
rebuilding
unavailable
currency mismatch
semantic mismatch
incomplete coverage
atomic identity-set generation mismatch
```

`atomic identity-set generation mismatch` is invalid only where rows that belong to the same atomic bucket or contribution replacement are required to share that rebuild `generation_id`. Different `generation_id` values across independently refreshed reusable buckets are allowed when every required identity is CURRENT and has compatible `semantic_version` and `coverage_identity` (see §§12.2 and 13.2).

The reader must still fail closed for absent, stale, refresh_pending, rebuilding, unavailable, incomplete coverage, semantic incompatibility, and invalid generation coherence **inside one atomic identity set**. Do not treat differing historical `generation_id` values across unrelated CURRENT buckets as a comparison failure by itself.

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
| `not_comparable` | Both projections are ready, but comparable identity or scope cannot be established: currency mismatch, grain mismatch, period-scope mismatch, semantic-version mismatch, or **compatible-coverage mismatch** between ready projections. **`coverage_identity` compares compatible coverage contracts, not identical time bounds.** Does not apply to a projection that is itself stale, incomplete, or not ready; those use `current_missing` or `comparison_missing`. No cross-currency comparison. |

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

The proposed `EventPeriodAggregateSnapshot` and `EventDimensionPeriodAggregateSnapshot` store only additive primitives keyed by event, currency, fixed bucket identity, and required dimension identity. Net, ATV, deltas, and percentages remain reader-derived. Rows replaced in the same atomic transaction for one affected bucket identity share one `generation_id`; unrelated buckets may carry different `generation_id` values and remain jointly readable when all are CURRENT.

Performance is bounded by requested event, currency, bucket count, and dimension cardinality. Reads avoid raw `Order`, `OrderItem`, `Refund`, and `RefundLine` queries. Rebuilds may run bounded SQL in Oban. Migration is additive and does not change lifetime v2 rows or Daily v1. Exact rolling-boundary resolution is locked by JC-312: fully covered rolling interiors use fixed UTC-hour buckets, while partial boundary fragments use bounded reads from `AnalyticsContributionFact`. JC-314 defines the physical resources. JC-317 merged event-period population and bounded source queries in PR #291. M5-04E owns dimensional period population, and M5-04F owns projection and edge reads.

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
AnalyticsContributionFact
        ↓ coherent CURRENT projection components
          read in one DB snapshot
PeriodComparisonReader
        ↓ policy, readiness, derivation, redaction
management caller
```

```text
mixed historical generation_id values = ALLOWED
guard =
  every required identity CURRENT
  + compatible semantic_version
  + compatible coverage_identity
  + one coherent DB transaction snapshot
```

Do not reintroduce a whole-history generation epoch.

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

JC-314 implements the fixed-bucket and contribution schema foundations for exact edge composition. JC-317 merged event-period population and bounded rebuild queries in PR #291. M5-04E owns dimensional population, M5-04F owns edge reads, and M5-04G must certify edge-query cost, rebuild cost, latency, connection use, and fan-out before any scale claim.

**Bounded edge scope (locked)**

With UTC-hour interior buckets for rolling windows:

```text
MAX_PARTIAL_EDGE_SPAN = strictly less than one UTC hour per partial fragment
MAX_PARTIAL_EDGE_FRAGMENTS_PER_COMPARISON = 4
  (optional leading + optional trailing partial fragment for current rolling window
   + optional leading + optional trailing partial fragment for previous rolling window)
INTERIOR_RULE = fully enclosed UTC hours must be read from fixed buckets, not contribution scans
COMPARISON_PAIR_RULE = contribution scans only for partial boundary fragments required by the two windows; never full 7d/30d contribution history when interior buckets exist
RAW_HISTORY_INTERACTIVE_READ = FORBIDDEN
```

Elapsed civil-day comparisons may use full Johannesburg-day interior buckets where applicable; partial civil edges follow the same bounded contribution rule.

## 12.2 Request anchor, bucket identity, and generation semantics (JC-312 review lock)

```text
REQUEST_ANCHOR =
  captured_now_utc + timezone + comparison scope/version + semantic version
  (request-scoped only; derives bounds via TimeRules.comparison_windows/3)

DURABLE_BUCKET_IDENTITY =
  event + currency + bucket_kind + bucket_start_utc + bucket_end_utc
  (must NOT include captured_now_utc)

generation_id =
  identity of one atomic rebuild/replacement transaction for one affected bucket/contribution identity set
  (observability + verifying rows produced together in that transaction; NOT a whole-history epoch)

DURABLE_READINESS =
  coherent DB transaction snapshot
  + per-required-identity currentness (CURRENT vs STALE/REFRESH_PENDING/REBUILDING/UNAVAILABLE)
  + compatible semantic_version
  + compatible coverage contract

coverage_identity (MetricRules.projections_comparable?/2) =
  versioned coverage completeness/readiness contract under which operands were established
  (NOT bucket bounds, captured_now_utc, generation_id, or refreshed_at)
```

**Incremental refresh rule:** on relevant BEFORE/AFTER mutation, mark affected BEFORE and AFTER bucket/contribution identities STALE/REFRESH_PENDING. The worker replaces only that union inside the event fence and transaction. Unaffected buckets remain CURRENT and reusable. No global historical rebake.

**Reader coherence rule:** open one coherent DB snapshot; resolve all required interior buckets and edge contribution ranges; fail closed if any required identity is absent, stale, rebuilding, unavailable, semantically incompatible, or has incomplete coverage; compose only fully ready components; derive comparison state after readiness/comparability. Mixed readiness states are forbidden. Mixed historical `generation_id` values across reusable buckets are allowed when every selected identity is CURRENT and coverage-compatible.

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

**Write:** replace only affected BEFORE and AFTER bucket/contribution identities under the existing event advisory fence and one transaction. Mark those identities STALE/REFRESH_PENDING before they may be served as CURRENT again. Unaffected identities stay CURRENT.

**Read:** use one coherent DB transaction snapshot. Require every selected interior bucket and edge contribution range identity to be CURRENT with compatible `semantic_version` and `coverage_identity`. Do **not** require all buckets across a 7d/30d comparison to share one literal historical `generation_id`. Reject mixed readiness (for example one bucket CURRENT and another STALE). Reject orphan currency, missing required family, or incomplete coverage. Derive comparison metrics only after readiness and `MetricRules.projections_comparable?/2` succeed.

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
5. write event and dimensional rows for the affected identity union, sharing one `generation_id` per atomic replacement transaction;
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

The interactive path must use one projection query for event rows and one bounded batched query for each requested dimensional family, or an equivalent set-based query. Query count must not grow with the number of dimension rows. The reader must not calculate each row with an individual database call. The bounded edge read specified by JC-312 reads a durable contribution projection rather than raw financial history and remains part of the projection read contract.

## 18. TTL, invalidation, and PubSub rules

The durable period projection has no correctness TTL. A row is current, stale, rebuilding, or unavailable by generation metadata and source invalidation, not by wall-clock expiry.

If a period result is cached:

- the cache key includes event, currency, current/comparison period identity, dimension family, authorization-relevant scope, and generation;
- the value is invalidated only after the durable replacement transaction commits;
- a generation mismatch on a **single bucket identity** is a miss; differing `generation_id` values across independently refreshed buckets are not inherently invalid when all identities are CURRENT;
- cache stampedes are prevented with the existing event-scoped refresh/coalescing seam, not a global mutex;
- Redis remains optional and must not be added without measured need;
- any Redis TTL must be explicit, project/environment scoped, and shorter than the acceptable freshness window.

PubSub publishes an event-scoped committed-generation notification after the transaction. LiveView clients push a refresh or payload update from that notification. No polling loop is part of the design.

## 19. Query and index audit

Current repository evidence is sufficient for the existing event-level period source and current dimensional rebuilds:

- `EventAggregatorFinancialQueryPlanTest` proves selective sale and refund period paths use bounded indexed plans and reject broad sequential scans for the certified fixture.
- `DimensionAggregatorQueryPlanTest` proves the six current dimensional gross/refund paths are bounded for the selective fixture.
- M5-03 reconciliation tests prove exact refund binders, identity predicates, and currency predicates are present in the current query paths.

JC-317 merged event-period population and bounded source queries in PR #291. JC-319 implements dimensional population from the same normalized contribution facts. Projection and edge readers remain deferred to M5-04F.

Merged JC-317 certifies event-period population and rebuild query shapes. M5-04E must prove dimensional population and rebuild query shapes. M5-04F must prove projection and bounded edge-read query shapes. Any non-constraint index requires selective fixtures and EXPLAIN evidence against the actual implemented path.

```text
M5_04C_PERFORMANCE_INDEX_DECISION = NONE
AUTHORIZED_C_INDEXES = CONSTRAINT / CANONICAL IDENTITY ENFORCEMENT ONLY
REDIS_DECISION = NONE (JC-312 / M5-04B)
CACHE_CHANGE = NONE (JC-312 / M5-04B)
WORKER_CHANGE = NONE (JC-312 / M5-04B)
```

M5-04C adds no non-constraint performance indexes. Its authorized indexes enforce constraints or canonical identity only. Any later non-constraint index requires all of:

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
- exact rolling boundary composition uses hybrid interior buckets plus bounded contribution edge reads (JC-312); JC-314 adds fixed-bucket and contribution schemas, while population and reads remain later slices;

`EventAggregator.financial_summaries_for_event_period/2` is suitable for a bounded event-level comparison experiment and certification oracle. It is not sufficient evidence for dimensional period comparison at management concurrency and is not an interactive raw-history fallback. M5-04G must measure projection read latency, rebuild latency, connection use under fence contention, cache hit/miss behavior if enabled, and PubSub update fan-out before making a scale claim.

## 21. Gap ledger

| Gap | Evidence | Impact | Smallest resolution |
| --- | --- | --- | --- |
| ~~Previous-equivalent mapping is not locked in current authority~~ | JC-310 Section 7 | ~~Blocks comparison period kernel~~ | **Resolved (JC-310)** |
| ~~Exact bucket strategy for rolling windows was not locked~~ | JC-312 | ~~Blocks canonical bucket identity~~ | **Resolved by JC-312:** `FIXED_INTERIOR_BUCKETS_PLUS_DURABLE_EXACT_CONTRIBUTION_EDGE`. JC-314 supplies the schema foundation; JC-317 owns event-period population, M5-04E owns dimensional population, and M5-04F owns the bounded edge reader. |
| Custom financial aggregation is disabled | EventAggregator rejects `:custom`; only civil-bound normalization is certified | Blocks custom MVP and custom comparisons | `CUSTOM_COMPARISON = DEFERRED` until separately authorized |
| ~~Public comparison-state vocabulary is not locked~~ | JC-310 Sections 10.1–10.2 | ~~Blocks stable reader contract~~ | **Resolved (JC-310)**; precedence locked in Section 10.2 |
| Distinct-order dimensional semantics are not additive | One order can span multiple dimensions | Blocks dimensional recognized-order count | Omit dimensional count or define a separate non-additive contract |
| Event-period write-query plan | JC-317 merged and selectively certifies bounded source reads | Durable authority recorded | Complete in merged PR #291 |
| Dimensional-period write-query plan | JC-319 certifies actual family DELETE plans and fixed bulk write counts | Local dimensional write evidence exists | Review JC-319 and require exact-head CI |
| Period readiness metadata population and reader enforcement | Merged JC-317 event lifecycle and JC-319 atomic dimensional lifecycle; readers remain M5-04F | Reader enforcement remains deferred | Enforce Section 12.2 coherence rules in M5-04F when authorized |
| ~~Durable generation coherence conflict (single generation_id vs incremental bucket refresh)~~ | Plan Sections 13.2 and 12.2 previously conflicted | ~~Blocks M5-04C reader/rebuild design~~ | **Resolved (JC-312 review correction)** — per-identity readiness + coherent snapshot; mixed `generation_id` allowed |

## 22. Owner decisions (JC-310 recorded)

```text
OWNER_DECISION_REQUIRED = NO
OWNER_DECISION = APPROVED
COMPARISON_AUTHORITY_LOCKED = YES
M5_04B_AUTHORIZATION_PENDING_MERGE = NO
JC_312_STATUS = MERGED
JC_312_MERGE_SHA = 325b752d41b051a95339234605983f666a907dbc
M5_04B_IMPLEMENTED_ON_BRANCH = YES
M5_04B_DURABLE_AUTHORITY = YES
M5_04C_AUTHORIZED = YES
M5_04C_STATUS = MERGED
JC_314_STATUS = MERGED
JC_314_MERGE_SHA = eebb9a83563e2ce0e40dd9a4e069567d89acd28f
M5_04C_DURABLE_AUTHORITY = YES
```

Remaining gates after JC-314:

1. JC-317 event-period invalidation and rebuild is merged and durable.
2. M5-04E dimensional period population and query-plan certification.
3. M5-04F projection and bounded edge reads, followed by M5-04G certification for latency, edge-query cost, rebuild cost, connection use, and fan-out.

Do not bypass the contribution projection when implementing exact rolling edges in C+.

## 23. M5-04B+ implementation sequence

The following sequence is conditional. Each phase starts only after the preceding authority and certification gates pass.

### M5-04B - comparison kernel and boundary contract (JC-312)

Scope: owner-approved previous mapping (Section 7), captured-now behavior, comparison states (Section 10.1–10.2), decimal comparison arithmetic, rolling-edge architecture lock (Sections 12.1–12.2), and locked **AnalyticsContributionFact** contract. Pure kernels on PR #287. No Ash resources or migrations until merge.

```text
TIME_COMPARISON_API = TimeRules.comparison_windows/3
COMPARISON_WINDOWS_REQUEST_TYPE = :today | :yesterday | {:rolling_days, 7 | 30}
COMPARISON_HELPER_API = MetricRules.projections_comparable?/2, classify_comparison_state/1, derive_comparison_deltas/3
ROLLING_EDGE_STRATEGY = FIXED_INTERIOR_BUCKETS_PLUS_DURABLE_EXACT_CONTRIBUTION_EDGE
JC_312_STATUS = MERGED
JC_312_MERGE_SHA = 325b752d41b051a95339234605983f666a907dbc
M5_04B_IMPLEMENTED_ON_BRANCH = YES
M5_04B_DURABLE_AUTHORITY = YES
M5_04C_AUTHORIZED = YES
M5_04C_STATUS = MERGED
JC_314_STATUS = MERGED
JC_314_MERGE_SHA = eebb9a83563e2ce0e40dd9a4e069567d89acd28f
M5_04C_DURABLE_AUTHORITY = YES
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

### M5-04C - additive period resources, contribution fact schema, and migration

Scope: implement fixed period bucket resources and the **AnalyticsContributionFact** resource schema, migration, and domain registration **only**. Rebuild population and invalidation belong to M5-04D/E.

Actual JC-314 schema files:

```text
lib/event_sales/analytics/resources/event_period_aggregate_snapshot.ex
lib/event_sales/analytics/resources/event_dimension_period_aggregate_snapshot.ex
lib/event_sales/analytics/resources/analytics_contribution_fact.ex
lib/event_sales/analytics.ex
priv/repo/migrations/20261002163658_m5_04c_period_aggregate_resources.exs
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
JC_312_STATUS = MERGED
JC_312_MERGE_SHA = 325b752d41b051a95339234605983f666a907dbc
M5_04B_DURABLE_AUTHORITY = YES
M5_04C_AUTHORIZED = YES
M5_04C_STATUS = MERGED
JC_314_STATUS = MERGED
JC_314_MERGE_SHA = eebb9a83563e2ce0e40dd9a4e069567d89acd28f
M5_04C_DURABLE_AUTHORITY = YES
ROLLING_EDGE_STRATEGY = FIXED_INTERIOR_BUCKETS_PLUS_DURABLE_EXACT_CONTRIBUTION_EDGE
```

## 27. Verdict

M5-04A audited the repository, identified the comparison-authority conflict, and rejected Daily v1 rehabilitation and an unbounded request-time comparison reader. JC-310 records the approved previous-equivalent contract without modifying M1-07. JC-312 implements pure comparison kernels and locks hybrid rolling-edge plus contribution contracts; PR #287 is merged and is durable authority. JC-314 implemented the authorized M5-04C schema slice and merged at `eebb9a83563e2ce0e40dd9a4e069567d89acd28f`. JC-317 merged the authorized M5-04D event-period rebuild and invalidation slice in PR #291 at `5f2acf53b97b974f6abf4c3bb271e2e843fc282c`. JC-319 merged the authorized M5-04E dimensional projection slice in PR #293. JC-321 implements the authorized M5-04F projection-only comparison reader (`PeriodComparisonReader`, `PeriodReadPlan`) on branch `feature/jc-321-m5-04f-period-comparison-reader`.

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
JC_312_STATUS = MERGED
JC_312_MERGE_SHA = 325b752d41b051a95339234605983f666a907dbc
M5_04B_IMPLEMENTED_ON_BRANCH = YES
M5_04B_DURABLE_AUTHORITY = YES
M5_04C_AUTHORIZED = YES
M5_04C_STATUS = MERGED
JC_314_STATUS = MERGED
JC_314_MERGE_SHA = eebb9a83563e2ce0e40dd9a4e069567d89acd28f
M5_04C_DURABLE_AUTHORITY = YES
M5_04D_AUTHORIZED = YES
M5_04D_STATUS = MERGED
JC_317_STATUS = MERGED
JC_317_MERGE_SHA = 5f2acf53b97b974f6abf4c3bb271e2e843fc282c
JC_317_MERGE_TREE = c6d58c43499233c22be34cdc0551d0fbae255224
M5_04D_DURABLE_AUTHORITY = YES
M5_04E_AUTHORIZED = YES
M5_04E_STATUS = MERGED
JC_319_STATUS = MERGED
JC_319_MERGE_SHA = 11f5bc3 (PR #293 merge commit on main)
M5_04E_DURABLE_AUTHORITY = YES
M5_04F_AUTHORIZED = YES
M5_04F_STATUS = IN_REVIEW
JC_321_STATUS = IN_REVIEW
ROLLING_EDGE_STRATEGY = FIXED_INTERIOR_BUCKETS_PLUS_DURABLE_EXACT_CONTRIBUTION_EDGE
ROLLING_EDGE_SCHEMA_FOUNDATION = M5-04C
ROLLING_EDGE_POPULATION = JC-317 event period / JC-319 dimensional period
ROLLING_EDGE_READ = M5-04F (PeriodComparisonReader)
STOP_CONDITION_TRIGGERED = NONE
```

JC-314 is complete. JC-317 and JC-319 merged event and dimensional period population. JC-321 delivers the authorized M5-04F reader; M5-04G certification remains next for latency, edge-query cost, and load evidence.

### M5-04F (JC-321) implementation record

```text
JC_319_STATUS = MERGED
JC_319_MERGE_SHA = 11f5bc36f351784696aaebb9ce74656e0210d59d
JC_319_MERGE_TREE = d11d980315fe55ea9a70ac7e3a5c29daea0d46e0
M5_04E_DURABLE_AUTHORITY = YES
M5_04F_AUTHORIZED = YES
M5_04F_STATUS = IN_REVIEW
M5_04F_DURABLE_AUTHORITY = PENDING_MERGE
M5_04G_AUTHORIZED = NO

REAUTHORIZED_BASE_SHA = f55ea2632ca9480412be4b086af1bd26b9b9889c
REAUTHORIZED_BASE_TREE = 52bbe026bf6d7d975ac6bf0dc03109b7ca3ecc9b

PERIOD_COMPARISON_READER = EventSales.Analytics.PeriodComparisonReader
PUBLIC_API = compare_event(event_id, currency, period_request, opts \\ [])

READ_PLAN = EventSales.Analytics.PeriodReadPlan.build/1 from TimeRules.comparison_windows/3

FIXED_QUERY_SCOPE_RULE = event_id AND currency AND (bucket OR …) — never OR bucket predicates outside tenant scope
READINESS_RESULT_RULE = missing/stale operands surface current_missing / comparison_missing in envelope; not {:error, :projection_not_ready}
OPERAND_METADATA_COHERENCE_RULE = mixed semantic_version or coverage_identity within one operand => operand not_ready
EDGE_DIMENSION_ENVELOPE_RULE = dimension coverage validates fixed buckets UNION edge-envelope UTC hours; interior composition uses fixed buckets only
EDGE_METADATA_MISMATCH_RULE = contribution facts with incompatible semantic/coverage in edge window => operand not_ready (no silent JOIN drop)
READY_GRAIN_ZERO_FILL_RULE = ready parent + absent grain in operand => zero primitives and grain ready (new_activity / flat_zero / etc.)
ATV_UNDEFINED_RULE = nil ATV operands => nil state and nil deltas (not :available)

FIXED_EVENT_QUERY_COUNT = 1
DIMENSION_COVERAGE_QUERY_COUNT = 1
DIMENSION_INTERIOR_QUERY_COUNT = 3
EDGE_EVENT_QUERY_COUNT = 0 (yesterday) | 2 (aggregate + metadata mismatch when edge fragments exist)
EDGE_DIMENSION_QUERY_COUNT = 0 (yesterday) | 3 (when edge fragments exist)

REVENUE_REDACTION_RULE = Policies.can_view_revenue?/2 hides all monetary metrics, deltas, and monetary comparison states

COHERENT_READ_ISOLATION = PostgreSQL REPEATABLE READ established explicitly via EventSnapshotRefreshFence.prepare_coherent_transaction!/0 inside the projection transaction before the first projection statement
COHERENT_TRANSACTION_OPTS_ALONE = NOT sufficient PostgreSQL isolation authority (Postgrex 0.22.4 BEGIN does not apply isolation_level option)
COHERENT_TRANSACTION_POSTGRES_ISOLATION = explicit SET TRANSACTION ISOLATION LEVEL REPEATABLE READ before first projection statement when use_repeatable_read_isolation?/0
READER_WRITER_FENCE = NONE (reader does not acquire writer advisory lock; MVCC snapshot isolation is the coherence mechanism)

EDGE_INDEX_DECISION = NONE (fixture EXPLAIN on event_id + currency + effective_at range showed selective plan without new index)
EDGE_INDEX_BEFORE_EXPLAIN = captured in test/event_sales/analytics/period_comparison_reader_query_plan_test.exs (EXPLAIN FORMAT JSON on captured edge SQL)
EDGE_INDEX_AFTER_EXPLAIN = not applicable (no index added)
EDGE_INDEX_EVIDENCE = period_comparison_reader_query_plan_test.exs EXPLAIN asserts analytics_contribution_facts + event_id in plan JSON
```
