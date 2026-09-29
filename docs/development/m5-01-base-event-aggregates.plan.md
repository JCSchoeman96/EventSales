---
Plan ID: m5-01-base-event-aggregates
Plan version: v2
Status: M5-01A conformance audit complete (revised) — planning only; M5-01 not COMPLETE
Scope: M5-01 base event-level canonical aggregate foundations (audit slice M5-01A)
Authority: `docs/path-1/path-1-phase-breakdown.md` (M5-01 row); PRE-M5-02F + PRE-M5-TIME-G evidence; M1-04–M1-08 contracts (locked)
Historical context: PRE-M5-02 metrics foundation plans and evidence; do not reopen locked PRE-M5 semantics
Last updated: 2026-09-29
Change summary (v2): PR #267 review — B23 orchestration gap; IMPLEMENTATION_REQUIRED (M5-01-G1); lifecycle wording corrected.
---

### Revision log

- v1 — M5-01A audit against `047b645` / tree `d188ce84`; B01–B22 matrix; CERTIFICATION_ONLY decision; next slice M5-01B.
- v2 — B23 durable snapshot refresh orchestration gap; `M5-01_DECISION = IMPLEMENTATION_REQUIRED`; distinguish certified refresh safety from missing post-mutation enqueue; next M5-01B implementation / M5-01C certification.

# M5-01 — Base event aggregates (conformance audit)

> Planning artifact only. M5-01A produced this document. No production code, migrations, tests, or dependency changes were made in M5-01A.

## 1. Certified starting state

```text
Repository:        JCSchoeman96/EventSales
Branch (audit):    path1/m5-01a-base-event-aggregate-audit
Required main SHA: 047b64541eeb7a98fa3a2501d82e3aa32c1c6156
Required tree:     d188ce84e05e513899a7c2a3db67e59056276b89
Audit HEAD:        047b64541eeb7a98fa3a2501d82e3aa32c1c6156 (same as main at audit start)
Worktree:          clean at audit preflight
Programme:         PRE-M5-TIME COMPLETE; GAP-PRE-M5-* CLOSED; M5 AUTHORIZED; M5-01 NEXT
```

PRE-M5 closeout on this tree includes merged PRE-M5-TIME-G2 (`docs/evidence/pre-m5-time-g-certification.md`) and metrics certification (`docs/evidence/pre-m5-02f-metrics-certification.md`).

---

## 2. Authority map

| Authority | Role for M5-01 |
| --- | --- |
| `docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md` | Recognised sale filters for gross primitives and distinct order count |
| `docs/path-1/m1-05-refund-and-financial-adjustment-contract.md` | Refund quantity/value primitives; no gross mutation on refund |
| `docs/path-1/m1-06-financial-metric-dictionary.md` | Gross/Net/ATV definitions; currency partitions; historical gross |
| `docs/path-1/m1-07-timestamp-johannesburg-period-and-freshness-contract.md` | Business timezone on snapshots; source freshness is separate from aggregate grain (M5-07) |
| `docs/path-1/m1-08-backfill-completeness-reconciliation-and-analytics-ready-contract.md` | ANALYTICS_READY gate; no second readiness on snapshots |
| `docs/development/pre-m5-02-metrics-foundation.plan.md` | Locked metric semantics and snapshot v2 contract (PRE-M5-02A) |
| `docs/evidence/pre-m5-02f-metrics-certification.md` | Automated certification M01–M15 on canonical aggregation and snapshot paths |
| `docs/development/pre-m5-time-foundation-implementation.plan.md` | Period/freshness physical work (consumed by M5-04+, not reopened here) |
| `docs/evidence/pre-m5-time-g-certification.md` | TIME foundation closed; preset period aggregation on `EventAggregator` certified |

Conflict rule: locked M1 and PRE-M5 evidence win over the M5-01 roadmap row still marked TBD for resource/migration.

---

## 3. Current resource map

```text
EventSales.Sales.FinancialPrimitives
  |> primitive arithmetic, derive_net_totals/1, integral quantity rules
  |> authority: CALCULATION (not management readiness)

EventSales.Analytics.MetricRules
  |> financial_summary/3 derives Net + ATV from primitives (not persisted)
  |> legacy summarize/2 for completed-only scalar compatibility

EventSales.Analytics.Aggregators.EventAggregator
  |> bounded Postgres aggregation per event (+ optional preset period)
  |> financial_summaries_for_event/1, summary_for_event/2 (legacy scalar)

EventSales.Analytics.Resources.EventAggregateSnapshot
  |> durable cold derived read model; grain event_id + currency; snapshot_version 2 canonical

EventSales.Analytics.SnapshotRefresh
  |> refresh_event/2: aggregator → transactional multi-currency persist → cache invalidate after commit

EventSales.Analytics.SnapshotReader
  |> snapshot-only reads; v2 canonical financial summaries; legacy scalar fail-closed on multi-currency

EventSales.Analytics.EventSnapshotRefreshFence
  |> per-event pg_advisory session lock + optional repeatable_read transaction

EventSales.Ingestion.AnalyticsReadinessResolver
  |> ANALYTICS_READY authority from M3 certificate + M4 reconciliation (no snapshot column)

EventSales.Analytics.DashboardCache (+ HotStateAggregator)
  |> HOT: ETS event summaries; recompute uses EventAggregator on write path, not dashboard SQL scans

EventSales.Analytics.Workers.RefreshSnapshotWorker
  |> Oban durable snapshot rebuild (`:analytics_rebuilds`, event-scoped uniqueness)
  |> perform/1 calls `SnapshotRefresh.refresh_event/2` when a job runs
  |> **no production caller enqueues event-scope jobs today** (see B23)
```

Refresh chain (event scope):

```text
FinancialPrimitives (via aggregator SQL + MetricRules.financial_summary/3)
  → EventAggregator.financial_summaries_for_event/1
  → SnapshotRefresh.refresh_event/2
  → EventAggregateSnapshot (v2, per currency)
  → SnapshotReader.financial_summaries_for_event/1
```

Management readiness is orthogonal:

```text
AnalyticsReadinessResolver.resolve/1
  → analytics_ready? / blocking_reason
  (does not read EventAggregateSnapshot)
```

---

## 4. Projection lifecycle

Conceptual states (not persisted enums):

| State | Meaning in repository |
| --- | --- |
| MISSING | No version-2 rows for the event; `SnapshotReader` returns `:miss` for canonical readers |
| CURRENT | At least one v2 row per canonical currency after successful `SnapshotRefresh.refresh_event/2`; rows reflect the aggregation at that refresh |
| STALE | **Target contract:** durable facts affecting the event changed since the last successful refresh, but v2 rows still exist. **Today:** no enforced STALE flag; rows can lag facts because post-mutation refresh orchestration is missing (B23) |

### Certified vs missing (lifecycle split)

```text
Refresh operation safety (when refresh_event/2 runs)
  IMPLEMENTED / CERTIFIED — PRE-M5-02F; concurrency and rollback tests

Automatic CURRENT → detect lag → queue refresh → CURRENT
  NOT IMPLEMENTED — no production enqueue of RefreshSnapshotWorker for event scope
```

Do not treat `EventAggregateSnapshot.source_watermark_at` as proof the durable aggregate incorporated later facts. It is refresh-time metadata from order-item scope (`event_source_metadata/1` in `SnapshotRefresh`), not M1-07 source-freshness authority and not a refund/sync freshness model.

`SourceFreshness` and `RefundProcessedNotifier` advance separate projections. They do not refresh `EventAggregateSnapshot`.

### Transitions

**MISSING → CURRENT**

Guards: valid `Event`; `EventAggregator.financial_summaries_for_event/1` succeeds (`:incomplete_financial_primitives` blocks); full canonical currency set written inside `Repo.transaction` + fence; `DashboardCache.invalidate_event` only after successful transaction.

Evidence: `HistoricalReportingSnapshotsTest`; `event_snapshot_refresh_rollback_test.exs`.

**CURRENT → STALE (contract) / lag without orchestration (today)**

After relevant durable mutation, the projection should become logically stale until refresh. Production today:

```text
OrderProcessedNotifier
  → DashboardCache.invalidate_event
  → HotStateAggregator recompute (bounded EventAggregator)
  → does NOT enqueue RefreshSnapshotWorker

RefundProcessedNotifier
  → SourceFreshness advancement
  → does NOT enqueue RefreshSnapshotWorker
```

Repository search (`lib/`, 2026-09-29): `RefreshSnapshotWorker` is defined in `lib/event_sales/analytics/workers/refresh_snapshot_worker.ex` only; no `Oban.insert` / worker module reference enqueues event-scope jobs in production. Tests call `perform/1` directly (`refresh_snapshot_worker_test.exs`). Manual dashboard refresh expects zero snapshot jobs (`dashboard_live_test.exs` asserts `refresh_snapshot_job_count() == 0`).

There is no production reader that compares live facts to snapshot rows and blocks `SnapshotReader` until refresh. On hot-cache miss, `SnapshotReader` can return the last persisted v2 row even when facts are newer.

**STALE → CURRENT (target)**

Enqueue/coalesce `RefreshSnapshotWorker` with existing Oban uniqueness (`keys: [:scope, :event_id, :business_date]`), then same guards as MISSING → CURRENT. **M5-01-G1** closes this path.

Mapping/attribution changes that alter aggregate membership must be included in M5-01B seam analysis (smallest authoritative post-commit hooks; no scatter `Oban.insert`).

**STALE → CURRENT (manual / test today)**

Explicit `SnapshotRefresh.refresh_event/2` or direct `RefreshSnapshotWorker.perform/1` in tests.

### Side effects (existing only)

- Persist v2 projection set
- `DashboardCache.invalidate_event(event_id, :snapshot_refresh)` after successful refresh
- Telemetry on `RefreshSnapshotWorker` (existing)
- No new PubSub contract required for M5-01 base aggregates

### Failure behavior

Failed refresh inside transaction: `Repo.rollback/1`; prior projection preserved (`event_snapshot_refresh_rollback_test.exs`). Multi-currency persist uses `reduce_while` halt on error before purge completes in same transaction. Fence serializes concurrent refresh for one event (`event_snapshot_refresh_concurrency_test.exs`).

### Terminal states

None.

---

## 5. Requirement matrix (B01–B23)

Classification key:

```text
ALREADY_IMPLEMENTED_CERTIFIED     — production + PRE-M5 or listed tests prove requirement
ALREADY_IMPLEMENTED_NEEDS_M5_TEST — production correct; M5-01B should add explicit evidence crosswalk only
IMPLEMENTATION_GAP                — provable missing behavior
DOCUMENTATION_GAP                 — behavior exists; programme doc missing (addressed in this plan)
OUT_OF_SCOPE                      — belongs to M5-02+ / M5-07+
OWNER_DECISION_REQUIRED           — policy choice blocks classification
```

| ID | Requirement | Classification | Contract | Production | Evidence |
| --- | --- | --- | --- | --- | --- |
| B01 | Event-scoped grain | ALREADY_IMPLEMENTED_CERTIFIED | M1-06; PRE-M5-02 | `EventAggregator.financial_summaries_for_event/1` | `event_aggregator_test.exs`; PRE-M5-02F M07–M08 |
| B02 | Currency partitioning | ALREADY_IMPLEMENTED_CERTIFIED | M1-06 §16 | `build_financial_summaries/4` keyed by `o.currency` | PRE-M5-02F M10; `historical_reporting_snapshots_test.exs` multi-currency refresh |
| B03 | Historical Gross quantity | ALREADY_IMPLEMENTED_CERTIFIED | M1-06; M1-04 | `recognised_sale_item_filters` + gross aggregate | PRE-M5-02F M01; `event_aggregator_test.exs` refunded-status gross preserved |
| B04 | Tax-inclusive Gross value | ALREADY_IMPLEMENTED_CERTIFIED | M1-06 | `sum(line_total + line_total_tax)` in gross query | PRE-M5-02F M02 |
| B05 | Refund quantity primitive | ALREADY_IMPLEMENTED_CERTIFIED | M1-05; M1-06 | `refund_aggregate_query/1` | PRE-M5-02F M03 |
| B06 | Refund value primitive | ALREADY_IMPLEMENTED_CERTIFIED | M1-05; M1-06 | refund value aggregate | PRE-M5-02F M04 |
| B07 | Net quantity derivation | ALREADY_IMPLEMENTED_CERTIFIED | M1-06 | `FinancialPrimitives.derive_net_totals/1` via `MetricRules.financial_summary/3` | PRE-M5-02F M03; `metric_rules_test.exs` |
| B08 | Net value derivation | ALREADY_IMPLEMENTED_CERTIFIED | M1-06 | same | PRE-M5-02F M04 |
| B09 | Distinct recognised order count | ALREADY_IMPLEMENTED_CERTIFIED | M1-06 §13–14 | `recognised_order_count_query/1` `count(distinct o.id)` | PRE-M5-02F M07–M08 |
| B10 | ATV derivation; zero qty → nil | ALREADY_IMPLEMENTED_CERTIFIED | M1-06 §15 | `MetricRules.average_ticket_value/2` | PRE-M5-02F M09; `metric_rules_test.exs` |
| B11 | Mixed-currency fail-closed scalar reads | ALREADY_IMPLEMENTED_CERTIFIED | PRE-M5-02 plan §8–9 | `EventAggregator.summary_for_event/2`, `SnapshotReader.summary_for_event/1` | PRE-M5-02F M11; `historical_reporting_snapshots_test.exs` |
| B12 | Canonical snapshot v2 durability | ALREADY_IMPLEMENTED_CERTIFIED | PRE-M5-02 | `EventAggregateSnapshot` v2 fields; `snapshot_version: 2` on refresh | PRE-M5-02F M13; migration `20260923134213_pre_m5_02d_event_snapshot_v2.exs` |
| B13 | Complete currency-set replacement | ALREADY_IMPLEMENTED_CERTIFIED | PRE-M5-02 | `persist_canonical_currencies!` + `purge_obsolete_event_projections!` | `historical_reporting_snapshots_test.exs` obsolete currency purge |
| B14 | Concurrent refresh safety | ALREADY_IMPLEMENTED_CERTIFIED | AGENTS analytics | `EventSnapshotRefreshFence.with_serial_event_refresh/2` | `event_snapshot_refresh_concurrency_test.exs`; `event_aggregate_snapshot_concurrency_test.exs` |
| B15 | Refresh rollback preservation | ALREADY_IMPLEMENTED_CERTIFIED | PRE-M5-02 | `refresh_event_projection_or_rollback` | `event_snapshot_refresh_rollback_test.exs` |
| B16 | Snapshot-only management read boundary | ALREADY_IMPLEMENTED_CERTIFIED | PRE-M5-02F M14 | `SnapshotReader`; `EventScopedDashboard` | `snapshot_boundaries_test.exs` |
| B17 | Indexed bounded aggregation | ALREADY_IMPLEMENTED_CERTIFIED | PRE-M5-02F §02F-B | `EventAggregator` gross/refund/order-count queries | `event_aggregator_financial_query_plan_test.exs`; PRE-M5-02F query-path tables |
| B18 | M4 ANALYTICS_READY separation | ALREADY_IMPLEMENTED_CERTIFIED | M1-08 | `AnalyticsReadinessResolver` (no snapshot readiness field) | `analytics_readiness_resolver_test.exs`; resolver moduledoc |
| B19 | Source-freshness separation | ALREADY_IMPLEMENTED_CERTIFIED | M1-07 | `SourceFreshness` / event source freshness snapshots; not stored on aggregate snapshot as readiness | PRE-M5-TIME-G evidence; `EventScopedDashboard` reads freshness separately |
| B20 | No raw dashboard history scan | ALREADY_IMPLEMENTED_CERTIFIED | AGENTS; PRE-M5-02F M14 | Dashboard LiveView + `EventScopedDashboard` boundary | `snapshot_boundaries_test.exs` |
| B21 | Legacy v1 compatibility boundary | ALREADY_IMPLEMENTED_CERTIFIED | PRE-M5-02 | v1 rows non-canonical; v2 required for `SnapshotReader` financial readers | PRE-M5-02F M13; `historical_reporting_snapshots_test.exs` |
| B22 | M5 scope isolation | ALREADY_IMPLEMENTED_NEEDS_M5_TEST | path-1 M5-01 row | No ticket-type/dimension snapshots added | M5-01C evidence pack should state non-goals explicitly |
| B23 | Durable event snapshot refresh orchestration after relevant source mutation | IMPLEMENTATION_GAP | M5-01 lifecycle; PRE-M5-02 projection lifecycle; path-1 M5 event-scoped invalidation | `RefreshSnapshotWorker` + `SnapshotRefresh.refresh_event/2` exist; **no production event-scope enqueue** | `OrderProcessedNotifier` hot path only; `RefundProcessedNotifier` source freshness only; `grep RefreshSnapshotWorker` → lib definition + tests + docs only; PRE-M5-02F certifies refresh **when it runs**, not post-mutation scheduling |

---

## 6. Gap decision

```text
M5-01_DECISION = IMPLEMENTATION_REQUIRED
```

B01–B21 remain implemented and certified (calculation, v2 durability, refresh transaction, readers, query plans, M4 separation, hot path). B23 is the sole `IMPLEMENTATION_GAP`.

```text
IMPLEMENTATION_GAP_IDS = M5-01-G1
```

**M5-01-G1 — Event-scoped durable snapshot refresh orchestration**

Schedule/coalesce existing `RefreshSnapshotWorker` (`scope: "event"`, `event_id`) from authoritative post-commit seams after durable changes that affect `EventAggregateSnapshot` membership or primitives, at minimum:

- order / order-item apply
- refund apply
- mapping / attribution changes that alter event aggregate membership

Reuse Oban uniqueness on the worker; do not add a second worker, Redis lock, GenServer serializer, resource, migration, or cache layer.

---

## 7. Physical recommendation

```text
NEW_RESOURCE = NO
MIGRATION = NO
NEW_INDEX = NO
NEW_DEPENDENCY = NO
NEW_CACHE_LAYER = NO
PRODUCTION_ORCHESTRATION_CHANGE = YES
```

Existing uniqueness: `analytics_event_aggregate_snapshots_unique_event_currency_index` (`event_id`, `currency`). Financial fact indexes certified under PRE-M5-02F query-plan work remain sufficient for event-scoped aggregation.

---

## 8. Proposed next slice

```text
M5-01B = implement smallest event-scoped durable snapshot refresh scheduling delta for M5-01-G1 (B23)
M5-01C = certify B01–B23 and close M5-01
```

M5-01B (implementation, not this PR):

1. Map smallest authoritative post-commit seams for order/order-item, refund, and mapping/attribution mutations.
2. Enqueue/coalesce `RefreshSnapshotWorker` per affected `event_id`; reuse existing uniqueness and `SnapshotRefresh`.
3. Add focused tests proving jobs are scheduled (and coalesced) without duplicating refresh logic.

M5-01C should:

1. Add `docs/evidence/m5-01-base-event-aggregates-certification.md` mapping B01–B23 to tests and PRE-M5 evidence.
2. Run focused analytics, orchestration, and readiness tests documented in evidence.
3. Update programme closeout in path-1 handoff only after M5-01C merges.

Do not start M5-02–M5-09 in M5-01B or M5-01C.

---

## 9. Performance and scaling review

| Question | Conclusion |
| --- | --- |
| Data layer owner | Postgres facts (Sales); cold derived `EventAggregateSnapshot`; hot `DashboardCache` / `HotStateAggregator` |
| Raw fact reads on dashboard path? | No on read facade (`SnapshotBoundariesTest`). Hot recompute uses bounded `EventAggregator` on write/notify path (existing) |
| Event-scoped? | Yes. All canonical queries filter by `event_id` |
| Required indexes present? | Yes for certified query-plan paths (PRE-M5-02F); event/currency unique on snapshots |
| Arbitrary history in BEAM? | No. Aggregation in SQL; refresh metadata uses bounded count/max watermark queries |
| N+1? | Per-currency upsert loop is O(currencies) with small cardinality, not per-order |
| Duplicate aggregate? | No second event aggregate resource |
| Hot/warm/cold ownership change? | No. M5-01 adds no Redis/Cachex |
| Concurrency | Session advisory lock per event + transactional full set replace; no Redis lock |

---

## 10. STOP findings

No programme STOP for M5-01 overall. One audit correction (B23 / M5-01-G1) blocks **certification-only** closeout:

- Durable `EventAggregateSnapshot` can lag facts with no automatic `RefreshSnapshotWorker` enqueue.
- PRE-M5-02F does not certify post-mutation orchestration.

No contradictory evidence found for B01–B21. No new resource, migration, index, or dependency required for M5-01-G1.

Preflight, code inspection, and focused tests (107 examples, 0 failures) did not contradict PRE-M5 refresh-safety, concurrency, rollback, query-plan, or M4 readiness certifications.

---

## Focused verification (M5-01A)

```text
bash scripts/dev_local.sh test \
  test/event_sales/analytics/metric_rules_test.exs \
  test/event_sales/analytics/event_aggregator_test.exs \
  test/event_sales/analytics/event_aggregator_financial_query_plan_test.exs \
  test/event_sales/analytics/historical_reporting_snapshots_test.exs \
  test/event_sales/analytics/event_snapshot_refresh_concurrency_test.exs \
  test/event_sales/analytics/event_snapshot_refresh_rollback_test.exs \
  test/event_sales/analytics/event_aggregate_snapshot_concurrency_test.exs \
  test/event_sales/analytics/snapshot_boundaries_test.exs \
  test/event_sales/ingestion/analytics_readiness_resolver_test.exs

Result: 107 tests, 0 failures (2026-09-29)
```
