# M5-01C — Base event aggregates certification evidence

| Field | Value |
| --- | --- |
| Plan ID | m5-01-base-event-aggregates |
| Evidence version | v2 |
| Plan version (authority at start) | v4 |
| Plan version (current) | v6 |
| Certification slice | M5-01C |
| Linear | JC-292 (Done); programme closeout JC-293 |
| Status | MERGED AND CERTIFIED |
| Scope | Certify M5-01 requirements B01–B23 on merged M5-01B base |
| Programme base SHA (M5-01B) | `f420437ab6ab5ab7a72db8e164ba08c59cbed328` |
| Programme base tree (M5-01B) | `f8245055c3a7acc8c7f3ee2891434d3a076ba9b6` |
| M5-01B merge | PR #268 on `main` at base SHA above |
| M5-01B implementation HEAD (reviewed) | `63acf204c9fe5098d65b51cb825a7d7b2110f729` |
| Certification PR | #269 |
| Approved HEAD | `24c6de35b6f0fa7ac67ba01a44c4a0b3a1752176` |
| Merge SHA | `42d830343c3baa714cec2eda8568d00ddb981abe` |
| Merge tree | `cbf5b19ddbdaabc6cf8ba86b177aeccefb4e8b96` |
| Exact-head CI (pre-merge) | run `36578565067`; 6/6 PASS; 2596 tests, 0 failures |
| Merge-SHA CI | none recorded at M5-01D closeout preparation |
| Branch (historical) | `path1/m5-01c-base-event-aggregates-certification` |
| Authority | `docs/development/m5-01-base-event-aggregates.plan.md` v6; locked M1-04–M1-08; PRE-M5-02F; PRE-M5-TIME-G |
| Last updated | 2026-09-29 |

### Revision log

- `v2` — Record PR #269 merge identity; status MERGED AND CERTIFIED; M5-01 COMPLETE on `main`; preserve B01–B23 PASS and residual advisory-lock capacity note.
- `v1` — M5-01C acceptance matrix B01–B23, B23 seam and transactional proof, regression and scope isolation, performance review, focused test bundle, verdict.

---

## 1. Certification identity and preflight

Preflight on programme base (2026-09-29):

```text
origin/main = f420437ab6ab5ab7a72db8e164ba08c59cbed328
tree        = f8245055c3a7acc8c7f3ee2891434d3a076ba9b6
worktree    = clean before branch creation
```

Implementation PR #268 is integrated at `main` HEAD. M5-01C changed documentation only; no `lib/**`, migrations, or dependency files were edited in this slice.

---

## 2. B01–B23 acceptance matrix

Cross-check: every production path and automated test cited below was verified to exist on base SHA `f420437`. Prior certification documents were re-read for contract authority only; M5-01C re-ran the focused bundle on the merged base.

| ID | Requirement | Contract authority | Production authority | Automated evidence | Prior evidence | M5-01C verification | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B01 | Event-scoped grain | M1-06; PRE-M5-02 | `EventSales.Analytics.Aggregators.EventAggregator.financial_summaries_for_event/1` | `EventSales.Analytics.EventAggregatorTest` (`test/event_sales/analytics/event_aggregator_test.exs`) | PRE-M5-02F M07–M08 | Path exists; bundle pass | PASS |
| B02 | Currency partitioning | M1-06 §16 | `EventAggregator` `build_financial_summaries/4` keyed by order currency | `HistoricalReportingSnapshotsTest` multi-currency refresh | PRE-M5-02F M10 | Path exists; bundle pass | PASS |
| B03 | Historical Gross quantity | M1-06; M1-04 | Recognised-sale filters + gross aggregate SQL | `EventAggregatorTest` refunded-status gross preserved | PRE-M5-02F M01 | Bundle pass | PASS |
| B04 | Tax-inclusive Gross value | M1-06 | Gross query sums `line_total + line_total_tax` | `EventAggregatorTest` tax-inclusive gross | PRE-M5-02F M02 | Bundle pass | PASS |
| B05 | Refund quantity primitive | M1-05; M1-06 | `EventAggregator` refund aggregate query | PRE-M5-02F M03 via aggregator tests | PRE-M5-02F M03 | Bundle pass | PASS |
| B06 | Refund value primitive | M1-05; M1-06 | Refund value aggregate | PRE-M5-02F M04 via aggregator tests | PRE-M5-02F M04 | Bundle pass | PASS |
| B07 | Net quantity derivation | M1-06 | `FinancialPrimitives.derive_net_totals/1` via `MetricRules.financial_summary/3` | `MetricRulesTest` | PRE-M5-02F M03 | Bundle pass | PASS |
| B08 | Net value derivation | M1-06 | Same | `MetricRulesTest` | PRE-M5-02F M04 | Bundle pass | PASS |
| B09 | Distinct recognised order count | M1-06 §13–14 | `recognised_order_count_query/1` | `EventAggregatorTest` distinct count cases | PRE-M5-02F M07–M08 | Bundle pass | PASS |
| B10 | ATV; zero Net qty → nil | M1-06 §15 | `MetricRules.average_ticket_value/2` | `MetricRulesTest` zero net qty | PRE-M5-02F M09 | Bundle pass | PASS |
| B11 | Mixed-currency fail-closed scalar reads | PRE-M5-02 | `EventAggregator.summary_for_event/2`, `SnapshotReader.summary_for_event/1` | `HistoricalReportingSnapshotsTest`; `EventAggregatorTest` | PRE-M5-02F M11 | Bundle pass | PASS |
| B12 | Canonical snapshot v2 durability | PRE-M5-02 | `EventSales.Analytics.Resources.EventAggregateSnapshot` v2 refresh | `HistoricalReportingSnapshotsTest` | PRE-M5-02F M13 | Bundle pass | PASS |
| B13 | Full currency-set replacement | PRE-M5-02 | `SnapshotRefresh` persist + purge obsolete currencies | `HistoricalReportingSnapshotsTest` obsolete purge | PRE-M5-02F | Bundle pass | PASS |
| B14 | Refresh serialization | AGENTS analytics | `EventSnapshotRefreshFence.with_serial_event_refresh/2` | `event_snapshot_refresh_concurrency_test.exs`; `event_aggregate_snapshot_concurrency_test.exs` | PRE-M5-02F lifecycle | Bundle pass; fence still used by `SnapshotRefresh.refresh_event/2` | PASS |
| B15 | Failed refresh rollback preservation | PRE-M5-02 | `SnapshotRefresh.refresh_event/2` transactional replace | `event_snapshot_refresh_rollback_test.exs` | PRE-M5-02F | Bundle pass | PASS |
| B16 | Snapshot-only management read boundary | PRE-M5-02F M14 | `SnapshotReader`; `EventScopedDashboard` | `snapshot_boundaries_test.exs` | PRE-M5-02F M14 | Bundle pass | PASS |
| B17 | Indexed bounded aggregation | PRE-M5-02F | `EventAggregator` gross/refund/order-count queries | `event_aggregator_financial_query_plan_test.exs` | PRE-M5-02F §02F-B | Bundle pass | PASS |
| B18 | M4 ANALYTICS_READY separation | M1-08 | `EventSales.Ingestion.AnalyticsReadinessResolver` | `analytics_readiness_resolver_test.exs` | M1-08 contract | Bundle pass | PASS |
| B19 | Source-freshness separation | M1-07 | `SourceFreshness`; event source freshness snapshots | PRE-M5-TIME-G; dashboard reads freshness separately | `docs/evidence/pre-m5-time-g-certification.md` | No snapshot readiness coupling in bundle | PASS |
| B20 | No raw dashboard history scan | AGENTS; PRE-M5-02F M14 | `EventScopedDashboard` hot/snapshot boundary | `snapshot_boundaries_test.exs` | PRE-M5-02F M14 | Bundle pass | PASS |
| B21 | Legacy v1 boundary | PRE-M5-02 | v1 non-canonical; v2 required for financial readers | `HistoricalReportingSnapshotsTest` v1 miss cases | PRE-M5-02F M13 | Bundle pass | PASS |
| B22 | M5 scope isolation | path-1 M5-01 row | No new aggregate resource, worker, readiness flag, or cache layer for B23 | Code inspection on merged base (see §8) | M5-01 plan v4 non-goals | Explicit negative checklist on `f420437` | PASS |
| B23 | Durable event snapshot refresh orchestration after relevant source mutation | M5-01 lifecycle; M5-01-G1 | Same-transaction enqueue at order, refund, mapped catalog recovery, attribution seams; `RefreshSnapshotWorker` | Orchestration + seam tests (see §3–§5) | M5-01B PR #268 | Full B23 proof on merged base | PASS |

---

## 3. B23 mutation-seam certification

### OrderUpserter

Production: `EventSales.Sales.OrderUpserter` calls `enqueue_snapshot_refreshes/2` inside `Repo.transaction/1` after historical coverage invalidation, using `HistoricalOrderCoverageCandidateResolver` before+after event IDs.

| Seam | Evidence | M5-01C result |
| --- | --- | --- |
| New aggregate-relevant order schedules current event | `OrderUpserterHistoricalCoverageTest` — `"a new aggregate-relevant Order requests its exact Event refresh"` | PASS |
| OrderItem event A→B schedules both events | Same module — `"OrderItem Event A to B mutation invalidates both certificates through D2"` (`assert_receive` sorted `[event_a.id, event_b.id]`) | PASS |
| Removed source identity retains BEFORE event candidate | Same — `"a removed source identity retains the BEFORE exact Event candidate"` | PASS |
| Enqueue failure rolls back mutation | Same — `"snapshot enqueue failure rolls back Order and coverage invalidation"` | PASS |
| Outer transaction rollback drops refresh intent | Same — `"an outer transaction rollback removes an OrderUpserter refresh job"` | PASS |

### RefundUpserter

Production: `finalize_refund_comparison/6` enqueues when `refresh_snapshot?` or `refund_snapshot_aggregates?/1` on **either** before or after snapshot. An aggregate-contributing refund snapshot is `source_state: :active` and `detail_status: :complete`. Candidate event IDs come from `HistoricalRefundMutationDetector`.

| Seam | Evidence | M5-01C result |
| --- | --- | --- |
| Qualifying active refund creation | `RefundUpserterHistoricalCoverageTest` — `"new normalized historical detail invalidates its exact Event certificate"` | PASS |
| Qualifying active refund update (aggregate-affecting) | Production guard on before/after complete active snapshots; reference-only→complete persists lines (`"reference-only to complete persists lines before invalidating both exact Events"`) with default scheduler path in production | PASS |
| Active complete → unresolved | `"malformed replay of an active complete refund refreshes its prior aggregate events"` — `assert_receive` with `event_ids == Enum.sort([event_a.id, event_b.id])`; before snapshot qualified, so removed refund contribution is recomputed | PASS |
| New unresolved / malformed detail without prior qualifying aggregate truth | `"new malformed detail invalidates every bounded parent Event"` — `refute_receive {:unexpected_snapshot_refresh}`; no prior active+complete contribution | PASS — no snapshot refresh |
| Reference-only detail without aggregate truth | `"new reference-only detail invalidates every bounded parent Event"` — `refute_receive` unexpected refresh | PASS — no snapshot refresh |
| Active → voided / source-deleted | `"active to voided invalidates the BEFORE exact Event candidates"` via `mark_source_deleted/5` with scheduler assertion | PASS — refreshes BEFORE-state aggregate event IDs |
| Enqueue failure rolls back refund mutation | `"snapshot enqueue failure rolls back active refund facts and coverage invalidation"` | PASS |

### MissingCatalogResolver

Production: mapped recovery only enqueues when durable OrderItem event membership changes (`pending → mapped`).

| Seam | Evidence | M5-01C result |
| --- | --- | --- |
| `pending → mapped` schedules event refresh | `MissingCatalogResolverTest` — `"maps a pending item to Event B and invalidates Event B coverage"` | PASS |
| `pending → unmapped` does not broaden to snapshot refresh | `"marks a pending item with an existing Event candidate unmapped and invalidates it"` — `refute_receive {:unexpected_snapshot_refresh}` | PASS |
| ProductMapping-only path without OrderItem membership change | Resolver tests do not schedule refresh on mapping-only operations; no production enqueue without item event change | PASS |
| Refresh failure rolls back mapping | `"refresh scheduling failure rolls back the recovered mapping and coverage"` | PASS |

### OrderAttributionCorrection

Production: `OrderAttributionCorrection` enqueues sorted before+after candidates when audited correction changes OrderItem event membership.

| Seam | Evidence | M5-01C result |
| --- | --- | --- |
| A→B correction refreshes both events | `OrderAttributionCorrectionTest` — successful correction with `assert event_ids == Enum.sort([mp_event.id, wr_event.id])` | PASS |
| Enqueue failure rolls back correction | `"refresh scheduling failure rolls back correction, audit, and coverage"` | PASS |

---

## 4. B23 transactional coupling

Required behavior on merged base:

```text
mutation succeeds + enqueue succeeds     → COMMIT
mutation succeeds + enqueue not confirmed → ROLLBACK
outer transaction rolls back             → mutation absent; refresh intent absent
```

Evidence:

| Proof | Test / production |
| --- | --- |
| Order/refund/catalog/attribution enqueue failure rolls back durable mutation | Seam tests listed in §3 |
| Outer rollback removes Oban rows | `EventSnapshotRefreshEnqueueConcurrencyTest` — `"an outer transaction rollback removes its refresh job"`; `OrderUpserterHistoricalCoverageTest` outer rollback |
| Idless `%Oban.Job{id: nil}` never counts as success | `RefreshSnapshotWorker.insert_event_job/3` returns `{:error, :snapshot_refresh_enqueue_unconfirmed_conflict}`; `RefreshSnapshotWorkerTest` — `"rejects an unconfirmed unique conflict without a persisted job"`; production Basic idless case in enqueue concurrency test |
| Nested Oban insert uses `retry: false` | `lib/event_sales/analytics/workers/refresh_snapshot_worker.ex` — `Oban.insert(changeset, retry: false)` inside mutation transaction |

M5-01C verdict: **PASS**

---

## 5. B23 scheduler concurrency (production Basic)

All proofs use `EventSales.Analytics.EventSnapshotRefreshEnqueueConcurrencyTest` with production-style Basic uniqueness (not test-mode bypass), unless noted.

| # | Requirement | Test name (module prefix `EventSnapshotRefreshEnqueueConcurrencyTest`) |
| --- | --- | --- |
| 1 | Pending requests coalesce | `"pending event refresh requests coalesce without moving the debounce"` |
| 2 | Coalescing does not move debounce/scheduled time | Same test |
| 3 | `executing` excluded from uniqueness | `RefreshSnapshotWorker` unique `states`; `"an executing event job permits a trailing pending job"` |
| 4 | Mutation during execution can leave trailing pending refresh | Same executing/trailing test |
| 5 | Pending conflict verified under row locking | `"a pending conflict holds the job row lock through the outer transaction"` |
| 6 | Lookup/replacement claim race cannot lose trailing work | `"a claim between uniqueness lookup and replacement leaves a trailing refresh"` |
| 7 | Same-event production contention waits on event transaction lock | `"same-event production enqueue waits, then coalesces after TX-A commits"` |
| 8 | TX-A commit → TX-B confirms/coalesces durable intent | Same test |
| 9 | TX-A rollback → TX-B inserts its own intent | `"same-event production enqueue survives TX-A rollback by inserting its own intent"` |
| 10 | Different events remain independent | `"different events retain separate pending jobs"`; `"an event-scoped scheduler lock does not block a different event"` |
| 11 | Multi-event locks in sorted UUID order | `"opposite multi-event inputs acquire scheduler locks in normalized order"`; `RefreshSnapshotWorkerTest` — `"normalizes event UUIDs and inserts them in deterministic order"` |
| 12 | Unconfirmed idless Basic conflicts fail closed | `"production Basic uniqueness returns an idless conflict when another transaction owns the lock"` |
| 13 | Oban nested transaction `retry: false` | Production `refresh_snapshot_worker.ex`; concurrency test Basic insert helper uses `retry: false` |
| 14 | `EventSnapshotRefreshFence` still serializes refresh execution | `SnapshotRefresh.refresh_event/2` still calls fence; B14 concurrency tests unchanged |

M5-01C verdict: **PASS**

---

## 6. B01–B21 regression / parity

M5-01C did not reopen M1 financial semantics. The focused bundle re-ran metric, aggregator, query-plan, snapshot lifecycle, concurrency, rollback, snapshot boundaries, readiness, and historical coverage suites on base `f420437`.

Regression dimensions explicitly exercised in the bundle include: event-scoped grain; currency partitions; historical gross; tax-inclusive gross; refund qty/value; Net derivation; distinct recognised orders; ATV and nil ATV at zero net qty; mixed-currency fail-closed scalars; v2 canonical snapshots; full currency-set replacement; refresh fence serialization; failed-refresh rollback; snapshot-only dashboard reads; event-bounded indexed SQL; ANALYTICS_READY separation; source-freshness separation; no sales-history modules on snapshot read boundary; legacy v1 non-canonical boundary.

Result: **257 tests, 0 failures** (see §10). No contradiction with PRE-M5-02F or PRE-M5-TIME-G evidence.

**B01–B21 regression verdict: PASS**

---

## 7. B22 scope isolation

Inspection on programme base `f420437` confirms M5-01B did not add:

| Check | Result |
| --- | --- |
| Ticket-type aggregate snapshot resource | Not present; only existing `EventAggregateSnapshot` and pre-existing `DailySalesAggregateSnapshot` |
| Arbitrary dimensional analytics snapshots | Not added |
| M5-02+ features | Out of scope; not introduced |
| Second event aggregate Ash resource | Not added |
| Second readiness flag on snapshots | Not added |
| Second freshness authority | Not added |
| Cachex | Not used in analytics scheduling path (comments only elsewhere) |
| Redis scheduler locking for B23 | Not added; refresh intent is Postgres/Oban |
| Global GenServer serialization for scheduling | Not added |
| Browser polling for aggregates | Not added |
| Second snapshot worker module | Not added; existing `RefreshSnapshotWorker` extended |
| Analytics-specific source-of-truth model | Not added |

Architecture remains:

```text
HOT  = ETS / DashboardCache / HotStateAggregator
WARM = Redis where already designed
COLD truth = Postgres facts
COLD derived read model = EventAggregateSnapshot
async = Oban
real time = Phoenix PubSub
```

**B22 verdict: PASS**

---

## 8. Performance and scaling review (M5-01)

### Data ownership

`EventAggregateSnapshot` is a cold Postgres-derived read model. Refresh intent is durable Postgres state (`oban_jobs`) written in the same transaction as authoritative mutations. No Redis representation is required for the B23 scheduling contract.

### Query shape

Canonical aggregation remains event-bounded SQL via `EventAggregator` (indexed paths certified in PRE-M5-02F and re-run in `event_aggregator_financial_query_plan_test.exs`). Dashboard reads stay on hot/snapshot boundaries (`snapshot_boundaries_test.exs`).

### Concurrency

Scheduling uses a namespaced per-event PostgreSQL transaction advisory lock (`pg_advisory_xact_lock` on SHA-256 of `eventsales:analytics:event-snapshot-refresh:v1:` + event UUID) before Oban Basic insert. Same-event scheduling transactions serialize; different event IDs proceed independently. Refresh execution remains serialized by `EventSnapshotRefreshFence` (session advisory lock), separate from scheduling.

### Scaling questions

| Question | Answer |
| --- | --- |
| What layer owns this data? | Postgres facts (Sales); cold derived snapshots (Analytics); hot ETS/dashboard cache |
| Does this introduce excess DB calls? | One debounced Oban job per event per coalescing window; bounded watermark queries on refresh only |
| Is Redis-side representation required? | No for durable refresh intent |
| Can any operation load unbounded history into memory? | No on certified paths; aggregation stays in SQL |
| Does same-event contention preserve correctness? | Yes; proven under production Basic + transaction advisory lock tests |
| What remains unproven at 100k concurrency? | Connection pool occupancy while waiters block on same-event advisory lock; not a demonstrated correctness defect |

### Residual capacity risk

The transaction-scoped **blocking** advisory lock means same-event scheduling waiters may hold database connections until the owning transaction commits or rolls back. M5-01C certifies correctness under tested contention, not flash-sale load. Treat connection occupancy under dense same-event writes as a **residual performance risk** for later work (e.g. M5-09 / M7-06). Do not redesign the mechanism in M5-01C.

---

## 9. Focused certification test bundle

Command (canonical wrapper):

```bash
bash scripts/dev_local.sh test \
  test/event_sales/analytics/metric_rules_test.exs \
  test/event_sales/analytics/event_aggregator_test.exs \
  test/event_sales/analytics/event_aggregator_financial_query_plan_test.exs \
  test/event_sales/analytics/historical_reporting_snapshots_test.exs \
  test/event_sales/analytics/event_snapshot_refresh_concurrency_test.exs \
  test/event_sales/analytics/event_snapshot_refresh_rollback_test.exs \
  test/event_sales/analytics/event_aggregate_snapshot_concurrency_test.exs \
  test/event_sales/analytics/snapshot_boundaries_test.exs \
  test/event_sales/analytics/refresh_snapshot_worker_test.exs \
  test/event_sales/analytics/event_snapshot_refresh_enqueue_concurrency_test.exs \
  test/event_sales/ingestion/analytics_readiness_resolver_test.exs \
  test/event_sales/catalog/missing_catalog_resolver_test.exs \
  test/event_sales/sales/order_attribution_correction_test.exs \
  test/event_sales/sales/order_upserter_historical_coverage_test.exs \
  test/event_sales/sales/refund_upserter_historical_coverage_test.exs \
  test/event_sales/sales/refund_upserter_test.exs
```

Result (2026-09-29 on certification branch): **257 tests, 0 failures** (13.5s).

All listed paths existed on base SHA `f420437`.

---

## 10. Quality gates

Recorded on certification branch before commit (base implementation unchanged; docs only).

| Gate | Result |
| --- | --- |
| `mix project.index --check` | PASS (no generated drift) |
| `mix quality.fast` | PASS |
| `bash scripts/dev_local.sh quality-pr` | PASS — 2596 tests, 0 failures (~200s) |
| `git diff --check` | PASS |

PR exact-head CI: recorded in repository final report after push.

---

## 11. Certification verdict

```text
B01–B23 = PASS
M5-01-G1 / B23 = CERTIFIED
M5-01 CERTIFICATION = PASS
M5-01 = COMPLETE (PASS)
```

Certification PR #269 merged at `42d830343c3baa714cec2eda8568d00ddb981abe` (merge tree `cbf5b19ddbdaabc6cf8ba86b177aeccefb4e8b96`). Merge tree matches approved HEAD `24c6de35b6f0fa7ac67ba01a44c4a0b3a1752176`. No merge-SHA workflow run was recorded when M5-01D closeout was prepared.

---

## 12. Residual risks / future performance work

- Same-event scheduling waiters use a blocking PostgreSQL transaction advisory lock and may occupy database connections under dense contention. Treat as a performance/load concern for later M5-09 / M7-06 certification, not a correctness defect.
- SHA-256 lock key truncation is a theoretical concurrency reduction, not a correctness weakening (documented in plan v4).

---

## 13. Explicit non-goals (M5-01C)

- No production code, migration, index, dependency, or formula changes.
- No M5-02–M5-09 implementation.
- Programme handoff closeout is M5-01D (JC-293), separate from this certification merge.
