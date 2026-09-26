# PRE-M5-02F — Metrics certification evidence

| Field | Value |
| --- | --- |
| Plan ID | PRE-M5-02F |
| Version | v4 |
| Status | Certification artifact (pre-merge; PR #251) |
| Scope | MG2 + MG4–MG8 against locked PRE-M5 metric contract |
| Certified programme base (post #252) | `ab46cb6f65de2fb80aaf01444eba670895c3fea6` |
| Post-merge CI authority (#252) | push run `36164776038` (6/6 on `ab46cb6`) |
| Prior metrics base (#250) | `5efc9638f231d6b944bc52c739906d3ff83d1b41` |
| Branch | `path1/pre-m5-02f-metrics-certification` |
| Last updated | 2026-09-25 |

### Revision log

- `v1` — Initial acceptance matrix, query-path certification, M4 parity, lifecycle evidence, and verdict table.
- `v2` — Gate B: selective bulk fixture (800 noise lines), `ANALYZE`, telemetry `EXPLAIN (FORMAT JSON)` with index-scan proof; Gate A dependency path documented (PR #252); plural-reader citation fix.
- `v3` — Gate A merged (#252 / `ab46cb6`); 800 noise refund facts; strict event-first `sales_order_items` indexes on guard/gross/order-count; refund-path boundedness proof; three-iteration planner stability test.
- `v4` — Refund certification: zero tolerance for `Seq Scan` on `sales_refunds` / `sales_refund_lines` under 800-noise fixture; indexed `sales_refunds` header access required.

Authority: this file is the 02F evidence artifact. Programme closeout wording in `docs/path-1/path-1-phase-breakdown.md` and `docs/roadmap/current-state-and-path-handoff.md` stays unchanged until this PR merges and post-merge CI passes on the merge SHA.

### Gate A (dependency security) — satisfied on programme base

**PR #252** merged as `ab46cb6f65de2fb80aaf01444eba670895c3fea6`. Post-merge push CI run `36164776038`: 6/6 PASS. `mix.lock` on `main` includes `ash` 3.33.11, `lazy_html` 0.1.13, transitive `hpax` 1.1.0, `multigraph` 0.16.1-mg.5. **PR #251** rebases onto `ab46cb6` with no `mix.lock` delta.

---

## 02F-A — Acceptance matrix (M01–M15)

| ID | Requirement | Contract source | Implementation authority | Automated evidence | Verdict |
| --- | --- | --- | --- | --- | --- |
| M01 | Historical Gross survives a recognised sale whose current order status becomes refunded | `docs/path-1/m1-06-financial-metric-dictionary.md` §6–7; PRE-M5-02 plan §7 | `EventAggregator.financial_summaries_for_event/1` + `MetricRules.financial_summary/3` | `EventSales.Analytics.EventAggregatorTest` — `"preserves historical gross when current status is refunded but completion evidence exists"` (`test/event_sales/analytics/event_aggregator_test.exs`) | PASS |
| M02 | Gross Ticket Sales includes `line_total_tax` | M1-06 tax-inclusive Gross; PRE-M5-02 plan §7 | `EventAggregator` gross aggregate (`line_total + line_total_tax`) | `EventSales.Analytics.EventAggregatorTest` — `"financial_summaries_for_event returns canonical tax-inclusive gross and distinct order count"` | PASS |
| M03 | Refund quantity reduces Net Ticket Quantity | M1-06 Refund/Net; PRE-M5-02 plan §7 | `FinancialPrimitives` + `MetricRules` | `EventSales.Analytics.EventAggregatorTest` — `"financial_summaries_for_event applies qualifying refunds without changing gross"` (asserts `net_ticket_quantity`) | PASS |
| M04 | Refund value reduces Net Ticket Sales | Same | Same | Same test (asserts `net_ticket_value`) | PASS |
| M05 | Refunds do not mutate historical Gross | M1-06; PRE-M5-02 plan §7 | `MetricRules.financial_summary/3` | `EventSales.Analytics.MetricRulesTest` — `"preserves gross components when refunds reduce net only"`; `EventAggregatorTest` — `"financial_summaries_for_event applies qualifying refunds without changing gross"` | PASS |
| M06 | Over-refund produces negative Net; no clamp | M1-06; PRE-M5-02 plan §7 | `FinancialPrimitives.derive_net_totals/1`, `MetricRules` | `EventSales.Analytics.MetricRulesTest` — `"over-refund preserves negative net without clamping"`; `EventSales.Ingestion.FinancialReconciliation.LocalTotalsTest` — `"does not clamp over-refund net values"` | PASS |
| M07 | Multiple qualifying ticket lines from one order → Recognised Order Count = 1 per event | M1-06 §13; PRE-M5-02 plan §7 | `EventAggregator` `count(o.id, :distinct)` per event | `EventSales.Analytics.EventAggregatorTest` — `"financial_summaries_for_event returns canonical tax-inclusive gross and distinct order count"` | PASS |
| M08 | Recognised Order Count is distinct / non-additive across overlapping event scopes | M1-06 §14 | Per-event `recognised_order_count_query/1`; no additive global dashboard API | `EventSales.Analytics.EventAggregatorTest` — `"recognised order count stays one per event when one order spans overlapping events"` (Event A = 1, Event B = 1; sum ≠ global 1). Global distinct count contract: M1-06 §14 (`global_order_count = sum(event_order_counts)` forbidden); no public source-global financial aggregate exists by design. | PASS |
| M09 | Net Ticket Quantity = 0 → ATV `nil` / N/A | M1-06 §15; PRE-M5-02 plan §7 | `MetricRules.financial_summary/3` | `EventSales.Analytics.MetricRulesTest` — `"zero net ticket quantity yields undefined average ticket value"`; `MetricRulesTest` — `"historical gross totals remain when refund adjustment facts are present"` (ATV nil when net qty 0) | PASS |
| M10 | ZAR + USD remain separate canonical partitions | M1-06 §16; PRE-M5-02 plan §7 | `EventAggregator.financial_summaries_for_event/1` | `EventSales.Analytics.HistoricalReportingSnapshotsTest` — `"event refresh writes one v2 projection per canonical currency"`; `EventAggregatorTest` — `"summary_for_event returns mixed currency error without choosing a currency"` | PASS |
| M11 | Legacy scalar mixed-currency reads fail closed | PRE-M5-02 plan §8–9 | `EventAggregator.summary_for_event/1`, `SnapshotReader.summary_for_event/1`, `EventScopedDashboard` | `EventAggregatorTest` — `"summary_for_event returns mixed currency error without choosing a currency"`; `HistoricalReportingSnapshotsTest` — `"legacy reader fails closed when multiple v2 currencies exist"`; `EventSales.Analytics.EventScopedDashboardTest` — `"mixed-currency snapshot compatibility does not collapse into zero revenue"` | PASS |
| M12 | Operational `status_breakdown` does not alter financial recognition | PRE-M5-02 plan §7 status context | Legacy `summary_for_event/2` vs canonical financial path | `EventSales.Analytics.MetricRulesTest` — `"non-completed statuses are visible but excluded from sold and revenue totals"`; `EventAggregatorTest` — `"legacy summary_for_event stays completed-only while canonical gross includes historical completion evidence"`; `HistoricalReportingSnapshotsTest` — `"mixed-currency refresh preserves operational status breakdown on v2 rows"` (status on snapshot; canonical financial partitions unchanged) | PASS |
| M13 | Snapshot version 1 is not canonical v2 truth | PRE-M5-02 plan §8 | `SnapshotReader` canonical readers | `HistoricalReportingSnapshotsTest` — `"canonical reader treats v1 rows as a non-authoritative miss"`; `"a v1 snapshot cannot be promoted to v2 from compatibility defaults alone"` | PASS |
| M14 | Dashboard / canonical reads use hot/snapshot projection paths, not source financial-history scans | PRE-M5-02 plan; AGENTS.md analytics boundaries | `EventScopedDashboard` → `HotStateAggregator` / `SnapshotReader` | `EventSales.Analytics.SnapshotBoundariesTest` — `"SnapshotReader stays on snapshot resources only"`; `"EventScopedDashboard uses hot-state and snapshot readers only"`; `EventScopedDashboardTest` — `"hot aggregate is preferred over snapshot and response excludes pii"` | PASS |
| M15 | Existing M4 financial reconciliation semantics unchanged | M1-08; 02F-C parity gate | `FinancialPrimitives`, `LocalTotals` | Full suites: `financial_primitives_test.exs`, `local_totals_test.exs` (123-test 02F bundle, 0 failures). See §02F-C. | PASS |

---

## 02F-B — Performance and query-path certification

### Structural read path

```text
EventScopedDashboard.summary/2
  → HotStateAggregator.summary_for_event/1 (cache/ETS miss path)
  → SnapshotReader.summary_for_event/1 (durable fallback)
```

`SnapshotReader` reads `EventAggregateSnapshot` and `DailySalesAggregateSnapshot` only. Structural refutation of sales/refund history modules: `SnapshotBoundariesTest`.

### EventAggregator canonical SQL paths

Fixture: `EventSales.TestSupport.Analytics.EventAggregatorQueryPlanFixture` (test-only `insert_all`).

| Population | Count |
| --- | --- |
| Noise event (other `event_id`) | 800 orders, 800 `sales_order_items`, 800 `sales_refunds`, 800 `sales_refund_lines` |
| Target event financial row | 1 order, 1 ticket line, 1 refund, 1 refund line (known ZAR summary: gross 92.00, refund 46.00, net 46.00, order count 1) |
| Post-load stats | `ANALYZE` on all four financial fact tables |

SQL captured via Ecto telemetry during `EventAggregator.financial_summaries_for_event/1`. Each statement must include an `event_id` predicate **and** bind the requested event UUID in query parameters. Proof runs **three** fresh fixture iterations per test (`EventAggregatorFinancialQueryPlanTest`).

Observed plans (local test DB after `ANALYZE`, selective fixture; all three iterations):

| Path | Purpose | Event predicate | `sales_order_items` | Other relations | Seq scans | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| `incomplete_primitive_guard` | Incomplete gross primitive guard | `s0.event_id = $1` | **Index Scan** on `sales_order_items_event_id_idx` (`Index Cond` = target `event_id`); every `sales_order_items` node uses only `sales_order_items_event_id_idx` or `sales_order_items_event_mapping_status_idx` | `sales_orders` → **Index Scan** on `sales_orders_pkey` (single-row PK join) | None on `sales_order_items` | PASS |
| `gross_aggregate` | Tax-inclusive gross by currency | `s0.event_id = $1` | **Index Scan** on `sales_order_items_event_id_idx` | `sales_orders` → **Index Scan** on `sales_orders_pkey` | None on `sales_order_items` | PASS |
| `recognised_order_count` | Distinct order count by currency | `s0.event_id = $1` | **Index Scan** on `sales_order_items_event_id_idx` | `sales_orders` → **Index Scan** on `sales_orders_pkey` | None on `sales_order_items` | PASS |
| `refund_aggregate` | Qualifying refund primitives | Subquery `ss0.event_id = $1` | Event-bounded subquery: **Index Scan** on `sales_order_items_event_id_idx` (required); parent line joins may use `sales_order_items_pkey` or `sales_order_items_order_id_idx` | `sales_refund_lines` → **Index Scan** on `sales_refund_lines_order_item_id_idx`; `sales_refunds` → **Index Scan** on `sales_refunds_pkey` (observed local EXPLAIN probe); `sales_orders` → **Index Scan** on `sales_orders_pkey` | **Zero** `Seq Scan` nodes on `sales_refund_lines` and `sales_refunds` across all certification iterations (801 refund headers/lines in fixture; enforced by test) | PASS |

Legacy operational/status aggregation for snapshot refresh (`legacy_summary_aggregate_query/3`) remains event-scoped (`where: oi.event_id == ^event_id`) and is exercised in `EventAggregatorTest` and snapshot refresh tests.

No new indexes were added in 02F (certification only).

### Dashboard request bounding

Dashboard requests do not call `EventAggregator` or scan `sales_*` tables at request time (`SnapshotBoundariesTest`, `EventScopedDashboard` module boundary).

---

## 02F-C — M4 semantic parity

Executed together (02F validation bundle):

| Suite | Result |
| --- | --- |
| `test/event_sales/sales/financial_primitives_test.exs` | 6 tests, 0 failures |
| `test/event_sales/ingestion/financial_reconciliation/local_totals_test.exs` | 37 tests, 0 failures |
| `test/event_sales/analytics/metric_rules_test.exs` | 13 tests, 0 failures |
| `test/event_sales/analytics/event_aggregator_test.exs` | 9 tests, 0 failures |

Parity dimensions checked: historical recognition, tax-inclusive gross, qualifying refund qty/value, currency partitioning, no FX collapse, gross unchanged by refunds, negative net without clamp, distinct order semantics per event scope.

**M4_PARITY = PASS**

---

## 02F-D — Projection / read lifecycle

Chain: `FinancialPrimitives` → `MetricRules` → `EventAggregator` → `SnapshotRefresh` → `EventAggregateSnapshot` v2 → `SnapshotReader` → `EventScopedDashboard`.

### Durable representation

| Invariant | Evidence |
| --- | --- |
| Grain `(event_id, currency)` | `HistoricalReportingSnapshotsTest` — `"event snapshot identity allows one projection per currency"` |
| Additive primitives only; Net/ATV not persisted | `"event snapshot v2 stores canonical additive financial primitives"`; `"event snapshot schema does not persist derived net or average fields"` |
| Canonical version = 2 | `"event refresh writes one v2 projection per canonical currency"` |
| v1 not canonical truth | `"canonical reader treats v1 rows as a non-authoritative miss"` |

### Refresh safety

| Invariant | Evidence |
| --- | --- |
| Event-level serialization | `EventSnapshotRefreshConcurrencyTest` — `"concurrent refresh_event calls block on the PostgreSQL session fence"` |
| Coherent source snapshot / fence | `"overlapping refresh_event uses source facts visible after acquiring the session fence"` |
| Atomic multi-currency replace | `"each successful refresh replaces the full event v2 set without leaving stale currencies"` |
| Obsolete v2 prune | `HistoricalReportingSnapshotsTest` — `"obsolete v2 currency rows are removed on refresh"` |
| Stale v1 suppression | `"empty canonical refresh removes v2 rows and does not resurrect stale v1 compatibility"` |
| Failed refresh rollback | `EventSnapshotRefreshRollbackTest` — `"failed multi-currency refresh rolls back and leaves cache intact"` |
| Cache invalidation after commit | `HistoricalReportingSnapshotsTest` — `"refresh invalidates dashboard cache for touched event"` |

### Read safety

| Invariant | Evidence |
| --- | --- |
| Canonical plural reader partitions by currency | `HistoricalReportingSnapshotsTest` — `"event refresh writes one v2 projection per canonical currency"` (`SnapshotReader.financial_summaries_for_event/1` keys `["USD", "ZAR"]`) |
| Mixed currency legacy scalar fails closed | `"legacy reader fails closed when multiple v2 currencies exist"` |
| Dashboard mixed-currency fails closed | `EventScopedDashboardTest` — `"mixed-currency snapshot compatibility does not collapse into zero revenue"` |
| Authorization before existence | `"unassigned valid UUID is forbidden before event existence is revealed"` |
| Revenue masking | `"event staff can read counts but revenue is hidden by default"` |
| PII visibility `:none` | `"hot aggregate is preferred over snapshot and response excludes pii"` |

---

## 02F-E — Certification verdict

| Gate | Verdict |
| --- | --- |
| MG2 (tax-inclusive Gross composition) | PASS |
| MG4 (historical Gross + Net after refunds) | PASS |
| MG5 (distinct Recognised Order Count) | PASS |
| MG6 (ATV derivation, zero denominator N/A) | PASS |
| MG7 (currency partitions, no mixed sum) | PASS |
| MG8 (snapshot schema beyond legacy scalar totals) | PASS |
| M4_PARITY | PASS |
| QUERY_PATHS | PASS |
| DASHBOARD_BOUNDING | PASS |
| SNAPSHOT_CONTRACT | PASS |
| CONCURRENCY_ATOMICITY | PASS |

All required metric and performance gates passed on branch evidence. No production code changes were required.

```text
GAP-PRE-M5-METRICS = ELIGIBLE FOR CLOSEOUT
```

`GAP-PRE-M5-METRICS = CLOSED` is reserved for the post-merge closeout after this PR’s merge SHA passes CI.

---

## Validation commands (02F branch)

```bash
mix test test/event_sales/analytics/metric_rules_test.exs
mix test test/event_sales/analytics/event_aggregator_test.exs
mix test test/event_sales/analytics/historical_reporting_snapshots_test.exs
mix test test/event_sales/analytics/event_scoped_dashboard_test.exs
mix test test/event_sales/analytics/event_snapshot_refresh_concurrency_test.exs
mix test test/event_sales/analytics/event_snapshot_refresh_fence_test.exs
mix test test/event_sales/analytics/event_snapshot_refresh_rollback_test.exs
mix test test/event_sales/sales/financial_primitives_test.exs
mix test test/event_sales/ingestion/financial_reconciliation/local_totals_test.exs
mix test test/event_sales/analytics/snapshot_boundaries_test.exs
mix test test/event_sales/analytics/event_aggregator_financial_query_plan_test.exs
mix ash.codegen --check
mix quality.fast
mix quality.pr
mix credo --strict
git diff --check
```

Dependency remediation (merge before 02F): PR #252 — `mix.lock` only.
