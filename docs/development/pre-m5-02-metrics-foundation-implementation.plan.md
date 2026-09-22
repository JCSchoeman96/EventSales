---
Plan ID: pre-m5-02-metrics-foundation-implementation
Plan version: v2
Status: active execution plan
Scope: PRE-M5-02B through PRE-M5-02F and PRE-M5-DOC-READY-IX sequencing
Authority: `docs/development/pre-m5-02-metrics-foundation.plan.md` wins on metric semantics and invariants
Historical context: Path 1 roadmap docs; superseded where they conflict with this pair
Last updated: 2026-09-22
Change summary (v2): Clarify PRE-M5-02A audit baseline vs PRE-M5-02B implementation start after READY-IX docs closeout
---

### Revision log

- v1 — initial implementation plan from approved PRE-M5-02A review
- v2 — preserve `a90f4a6` as 02A design/audit baseline only; PRE-M5-02B starts from verified post-merge `main` after PRE-M5-DOC-READY-IX

# PRE-M5-02 Metrics Foundation Implementation Plan

> Planning artifact only. Do not implement production code from this document until the applicable sub-slice is explicitly authorized.

## Goal

Close `GAP-PRE-M5-METRICS` through a sequence of independently reviewable changes that establish authoritative tax-inclusive, refund-aware, currency-partitioned event financial projections without changing PRE-M5-TIME semantics or M4 reconciliation behavior.

## Architecture

`EventSales.Sales.FinancialPrimitives` remains the arithmetic authority.

`EventSales.Analytics.MetricRules` becomes the analytics facade over those primitives.

`EventSales.Analytics.Aggregators.EventAggregator` becomes the bounded Postgres event/currency aggregation boundary.

`EventAggregateSnapshot` becomes a versioned `(event_id, currency)` durable projection.

`SnapshotRefresh`, `SnapshotReader`, hot-state rebuilds and dashboard compatibility surfaces consume those boundaries without performing peak-time history scans.

## Tech stack

* Elixir
* Ash 3.x
* AshPostgres
* Ecto/PostgreSQL
* Decimal
* ExUnit
* Oban
* existing `DashboardCache`
* existing Redis warm adapter where already present

No new dependencies.

## Canonical specification

Version-controlled target:

`docs/development/pre-m5-02-metrics-foundation.plan.md`

Implementation-plan target:

`docs/development/pre-m5-02-metrics-foundation-implementation.plan.md`

## Baselines

### PRE-M5-02A design / audit baseline

```text
a90f4a6d991510684dde80a538c0847635de2ee9
```

This SHA records the repository state used for PRE-M5-02A specification review and READY-IX merge evidence (`PRE-M5-01B` / PR #244). It is **not** the mandatory git start point for PRE-M5-02B production code.

### Implementation slice start rule

**PRE-M5-02B** starts from the verified post-merge `main` produced by the **PRE-M5-DOC-READY-IX** docs-only closeout (merge of branch `path1/pre-m5-ready-ix-doc-closeout`).

Each later slice starts from the verified post-merge `main` of its predecessor.

---

# 1. Global constraints

1. `GAP-PRE-M5-READY-IX` stays **CLOSED**. PRE-M5-02 never recertifies or reimplements it.
2. `GAP-PRE-M5-TIME` stays **OPEN**.
3. M5 stays **BLOCKED**.
4. Do not implement `paid_at` bucketing, refund period bucketing, Johannesburg period logic or source-freshness changes here.
5. Do not duplicate formulas from `FinancialPrimitives`.
6. Do not make `FinancialReconciliation.LocalTotals` a dashboard/runtime API.
7. Preserve negative Net results.
8. Zero Net Tickets means ATV is undefined / `nil`, not monetary zero.
9. Never collapse different currencies.
10. Never derive Recognised Order Count by summing overlapping child scopes.
11. Operational `status_breakdown` retains its current legacy semantics during PRE-M5-02 unless a separate contract changes it.
12. Persist additive financial components, not Net or ATV.
13. Canonical financial snapshots use version `2`.
14. Version-1 snapshots are not canonical financial truth.
15. Existing authorization and revenue visibility behavior must not weaken.
16. Postgres remains durable authority.
17. No new Cachex requirement.
18. No new Redis structure is needed for PRE-M5-02.
19. No UI redesign.
20. No unrelated refactors or dependency upgrades.

---

# 2. Review focus

These are the highest-risk failure modes reviewers must actively look for.

| Risk                                                             | Required proof                                                |
| ---------------------------------------------------------------- | ------------------------------------------------------------- |
| Mixed currencies silently collapse into one summary              | Two-currency integration test; legacy scalar API fails closed |
| Historical Gross disappears after refund/status mutation         | Completed→refunded regression                                 |
| Refund joins multiply Gross or Refund totals                     | Multi-line, multi-refund fixture with exact expected totals   |
| Snapshot v1 is mistaken for v2 canonical truth                   | Reader-version regression                                     |
| Concurrent refresh leaves partial/duplicate currency projections | Transactional refresh + uniqueness/concurrency test           |

---

# 3. File responsibility map

## Existing files expected to change

### PRE-M5-02B

`lib/event_sales/analytics/metric_rules.ex`

`test/event_sales/analytics/metric_rules_test.exs`

Possibly:

`lib/event_sales/sales/financial_primitives.ex`

`test/event_sales/sales/financial_primitives_test.exs`

`FinancialPrimitives` changes are allowed only if a genuinely missing reusable primitive/helper is proven. Do not move analytics-specific presentation logic into Sales.

### PRE-M5-02C

`lib/event_sales/analytics/aggregators/event_aggregator.ex`

`test/event_sales/analytics/event_aggregator_test.exs`

Regression authority:

`lib/event_sales/ingestion/financial_reconciliation/local_totals.ex`

`test/event_sales/ingestion/financial_reconciliation/local_totals_test.exs`

### PRE-M5-02D

`lib/event_sales/analytics/resources/event_aggregate_snapshot.ex`

Ash-generated migration under:

`priv/repo/migrations/`

Ash resource snapshot under:

`priv/resource_snapshots/repo/analytics_event_aggregate_snapshots/`

Tests:

`test/event_sales/analytics/historical_reporting_snapshots_test.exs`

and resource/domain smoke tests if codegen changes require them.

### PRE-M5-02E

`lib/event_sales/analytics/snapshot_refresh.ex`

`lib/event_sales/analytics/snapshot_reader.ex`

`lib/event_sales/analytics/event_scoped_dashboard.ex` only where required for fail-closed compatibility.

Potentially no functional change required in:

`lib/event_sales/analytics/workers/rebuild_hot_state_worker.ex`

because it already consumes `EventAggregator`; change it only if the new canonical contract requires an explicit adaptation.

Tests:

`test/event_sales/analytics/historical_reporting_snapshots_test.exs`

`test/event_sales/analytics/event_scoped_dashboard_test.exs`

`test/event_sales/analytics/rebuild_hot_state_worker_test.exs`

`test/event_sales/analytics/hot_state_aggregator_test.exs`

### PRE-M5-02F

Primarily tests, certification evidence and PRE-M5 metric status documentation.

No speculative production refactor.

---

# 4. Programme sequence

```text
PRE-M5-DOC-READY-IX    docs-only stale-status cleanup

PRE-M5-02B             canonical metric kernel
        ↓
PRE-M5-02C             bounded event/currency aggregation
        ↓
PRE-M5-02D             EventAggregateSnapshot v2
        ↓
PRE-M5-02E             refresh/read/cache compatibility integration
        ↓
PRE-M5-02F             metrics certification
        ↓
GAP-PRE-M5-METRICS CLOSED
        ↓
PRE-M5-TIME
```

Do not combine 02B–02E into one PR.

---

# 5. Scaffolding Prompt

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Implement the PRE-M5-02 Metrics Foundation programme as sequential sub-slices 02B→02F, using the approved `docs/development/pre-m5-02-metrics-foundation.plan.md` contract.                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Objective | Close `GAP-PRE-M5-METRICS` while preserving M3/M4 certified financial truth, READY-IX, authorization boundaries and the separate PRE-M5-TIME scope.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Output    | Sequential reviewed PRs for canonical metric rules, bounded event/currency aggregation, snapshot-v2 schema, snapshot/read integration and final metrics certification.                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Note      | Start PRE-M5-02B from verified post-merge `main` after PRE-M5-DOC-READY-IX merges; treat `a90f4a6` only as the 02A design/audit baseline. Every later slice must start from the verified post-merge `main` of its predecessor. Use existing modules before creating abstractions. `FinancialPrimitives` owns arithmetic. Never collapse currencies, clamp negative Net, persist ATV/Net, sum overlapping distinct order counts, or implement PRE-M5-TIME. Postgres cold truth; existing DashboardCache hot; existing Redis warm only. Run focused tests first, `mix quality.fast` at slice completion and `mix quality.pr` before meaningful review. STOP on unrelated drift, authority conflict, or failed validation. |

---

# 6. Dedicated READY-IX documentation closeout

This is a **separate documentation-only slice**.

It may occur before 02B so coding agents no longer encounter stale READY-IX status.

## TOON — READY-IX docs closeout

| Field     | Content                                                                                                                                                                                                                                                                                                                                                           |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Update PRE-M5 governance documentation so `GAP-PRE-M5-READY-IX` is recorded as CLOSED based on PR #244 and post-merge CI #621.                                                                                                                                                                                                                                    |
| Objective | Remove stale programme-state ambiguity without changing certified READY-IX behavior.                                                                                                                                                                                                                                                                              |
| Output    | Documentation-only diff in the canonical Path 1 roadmap/current-state documents that still report READY-IX as open or certification-required.                                                                                                                                                                                                                     |
| Note      | Do not touch production code, migrations, resolver semantics, index definitions or tests except documentation-consistency tests if they exist. Record merge `a90f4a6d991510684dde80a538c0847635de2ee9`, approved head `9485e4c8e81cede0c99d7bba7d7d86840f34d95d`, CI #621 / `35775996226`. READY-IX stays closed; METRICS and TIME remain open; M5 stays blocked. |

### STOP

Stop if updating READY-IX documentation requires changing production behavior.

---

# 7. PRE-M5-02B — Canonical Metric Kernel

## Outcome

Create the pure canonical analytics financial metric facade without changing persistence or query architecture.

### Contract to establish

`MetricRules` must clearly distinguish:

```text
legacy operational summary behavior
vs
canonical financial metric behavior
```

`FinancialPrimitives` remains arithmetic authority.

Canonical financial summaries must contain:

```text
currency
gross_ticket_quantity
refund_ticket_quantity
net_ticket_quantity
gross_ticket_value
refund_ticket_value
net_ticket_value
recognised_order_count
average_ticket_value
```

Net and ATV are derived only.

## TOON 02B-1 — MetricRules authority boundary

| Field     | Content                                                                                                                                                                                                                                                      |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Task      | Refactor `lib/event_sales/analytics/metric_rules.ex` documentation and public contract so `FinancialPrimitives` is explicitly the arithmetic authority and `MetricRules` is the analytics facade / compatibility layer.                                      |
| Objective | Remove conflicting “source of truth” documentation before new canonical financial behavior is introduced.                                                                                                                                                    |
| Output    | Updated moduledoc/types in `metric_rules.ex` and focused assertions in `test/event_sales/analytics/metric_rules_test.exs`.                                                                                                                                   |
| Note      | Do not alter current `summarize/2` status-breakdown semantics in this task. Do not modify snapshot resources, SQL queries, time bucketing or M4 modules. Existing completed-only helpers may remain temporarily as explicitly legacy compatibility behavior. |

## TOON 02B-2 — Canonical financial summary derivation

| Field     | Content                                                                                                                                                                                                                                                                                                                                                            |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Task      | Add a pure `MetricRules` canonical financial-summary API that consumes one currency partition of `FinancialPrimitives` totals plus a distinct recognised-order count and derives Net and ATV.                                                                                                                                                                      |
| Objective | Establish one reusable analytics-level metric representation before database aggregation and snapshot work.                                                                                                                                                                                                                                                        |
| Output    | Pure financial-summary function(s) in `metric_rules.ex`; focused unit tests in `metric_rules_test.exs`.                                                                                                                                                                                                                                                            |
| Note      | Delegate Gross/Refund/Net arithmetic to `FinancialPrimitives`; do not copy formulas. ATV uses Net Ticket Value ÷ Net Ticket Quantity. Zero denominator returns `nil`/undefined. Preserve negative Net. Reject or fail fast on invalid/missing currency and non-integral quantity primitives rather than silently coercing. No database access. No status counting. |

## TOON 02B-3 — Historical and refund regression matrix

| Field     | Content                                                                                                                                                                                                                                                                                                                                                          |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Add pure regression tests covering historical Gross preservation, tax-inclusive Gross, refund Net reductions, over-refunds and distinct derived metric behavior.                                                                                                                                                                                                 |
| Objective | Lock MG2/MG4/MG6 semantics before Postgres aggregation is changed.                                                                                                                                                                                                                                                                                               |
| Output    | Expanded `metric_rules_test.exs`; extend `financial_primitives_test.exs` only where primitive authority itself lacks coverage.                                                                                                                                                                                                                                   |
| Note      | Required cases: completed historical sale later current-status refunded still has Gross when historical recognition evidence is supplied; tax-inclusive value includes `line_total_tax`; quantity refund does not alter Gross; money refund does not alter Gross; negative Net preserved; zero Net quantity → ATV N/A. Do not redefine current status breakdown. |

## TOON 02B-4 — 02B certification

| Field     | Content                                                                                                                                                                                                                                                         |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Validate the completed 02B kernel branch and prepare it for independent review.                                                                                                                                                                                 |
| Objective | Ensure the pure metric contract is stable before any database or snapshot change.                                                                                                                                                                               |
| Output    | Green focused tests, green quality gates, coherent commit/PR, Linear issue updated with evidence.                                                                                                                                                               |
| Note      | Minimum commands: `git status --short`; focused `MetricRules` and `FinancialPrimitives` tests; `mix quality.fast`; then `mix quality.pr` before PR review. No local WordPress or Redis runtime is required. STOP if production persistence/query files changed. |

### 02B success

```text
MetricRules authority docs       PASS
tax-inclusive derivation         PASS
refund-aware Net                 PASS
negative Net preserved           PASS
zero-denominator ATV             PASS
status legacy behavior unchanged PASS
snapshot/schema changes          NONE
M4 regression                    PASS
```

---

# 8. PRE-M5-02C — Bounded Event/Currency Aggregation

## Outcome

Replace the event financial path that loads all `OrderItem` records into BEAM with bounded Postgres aggregation.

## Public boundary

Extend `EventAggregator`.

Preferred canonical API semantics:

```text
financial_summaries_for_event(event_id)
→ {:ok, %{currency => canonical_financial_summary}}
→ {:error, reason}
```

Retain `summary_for_event/2` as a compatibility boundary, but its financial path must no longer require loading arbitrary event history.

For more than one currency, legacy scalar summary behavior must fail closed.

## TOON 02C-1 — Currency-partitioned Postgres primitive aggregation

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Replace the authoritative financial internals of `EventAggregator` with bounded Postgres aggregation grouped by event and currency.                                                                                                                                                                                                                                                                                                                                                                                                       |
| Objective | Produce canonical Gross/Refund primitives and distinct Recognised Order Count without loading full event history into BEAM.                                                                                                                                                                                                                                                                                                                                                                                                               |
| Output    | Updated `lib/event_sales/analytics/aggregators/event_aggregator.ex` and focused integration tests in `test/event_sales/analytics/event_aggregator_test.exs`.                                                                                                                                                                                                                                                                                                                                                                              |
| Note      | Reuse the qualification semantics proven by M4 `LocalTotals`: historical recognition, mapped positive ticket lines, tax-inclusive Gross, active+complete qualifying bound ticket refunds, source/order currency consistency. Do not call `LocalTotals` directly. Avoid joins that multiply original lines by refund-line cardinality; aggregate Gross and Refund independently before combining by currency if necessary. Distinct order count uses canonical source-scoped identity and must be calculated directly for the event scope. |

## TOON 02C-2 — Legacy single-summary compatibility

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Task      | Adapt `EventAggregator.summary_for_event/2` to the new bounded canonical aggregation while preserving legacy single-currency callers.                                                                                                                                                                                                                                                                                                                        |
| Objective | Remove the raw-history scan without forcing an unrelated dashboard redesign in 02C.                                                                                                                                                                                                                                                                                                                                                                          |
| Output    | Compatibility behavior in `event_aggregator.ex` plus tests.                                                                                                                                                                                                                                                                                                                                                                                                  |
| Note      | Exactly one currency may produce the existing scalar compatibility summary. Multiple currencies must return an explicit mixed-currency failure; never choose first/default/latest currency. Keep status breakdown behavior separate from canonical financial primitives; if legacy status context still requires existing logic, do not let that reintroduce an unbounded peak financial scan—STOP and report if those concerns cannot be separated cleanly. |

## TOON 02C-3 — Query/index certification

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Prove the 02C aggregate query paths are bounded and supported by appropriate existing PostgreSQL indexes.                                                                                                                                                                                                                                                                                                                                                                               |
| Objective | Prevent the canonical aggregator from becoming a peak-time table-scan path.                                                                                                                                                                                                                                                                                                                                                                                                             |
| Output    | Query-plan evidence recorded in the PR; focused test/assertion for stable query shape where practical.                                                                                                                                                                                                                                                                                                                                                                                  |
| Note      | Inspect event/order-item join/filter, refund-line binding, refund parent/status filters, currency grouping and distinct source-order lookup. Use `EXPLAIN` on representative seeded data. Do not add speculative indexes. If a critical path lacks a usable index and materially degrades the plan, STOP and return the exact query + missing index requirement for a dedicated reviewed index change. Do not accept an unbounded Seq Scan merely because development tables are small. |

## TOON 02C-4 — M4 non-regression certification

| Field     | Content                                                                                                                                                                                                                                                                                      |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Prove that the new Analytics aggregation path did not change certified M4 financial reconciliation semantics.                                                                                                                                                                                |
| Objective | Prevent two financial definitions from drifting.                                                                                                                                                                                                                                             |
| Output    | Passing `event_aggregator_test.exs`, `financial_primitives_test.exs`, and `test/event_sales/ingestion/financial_reconciliation/local_totals_test.exs`; PR evidence noting semantic parity.                                                                                                   |
| Note      | Exact totals for shared fixtures should agree where scope/completeness are equivalent. Analytics may have different scope orchestration, but arithmetic, recognition, refund qualification and currency rules must not diverge. Run `mix quality.fast`, then `mix quality.pr` before review. |

### 02C success

```text
full OrderItem load removed from authoritative financial path
currency grouping correct
historical recognition correct
refund qualification correct
distinct order count correct
mixed-currency legacy path fails closed
critical query plans bounded
M4 unchanged
```

---

# 9. PRE-M5-02D — EventAggregateSnapshot v2

## Outcome

Extend the durable event projection to canonical additive financial fields and `(event_id, currency)` identity.

## Canonical persisted fields

```text
gross_ticket_quantity
refund_ticket_quantity
gross_ticket_value
refund_ticket_value
recognised_order_count
currency
snapshot_version
```

Do not persist:

```text
net_ticket_quantity
net_ticket_value
average_ticket_value
```

## TOON 02D-1 — Snapshot v2 resource contract

| Field     | Content                                                                                                                                                                                                                                                                                                                                                         |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Extend `EventAggregateSnapshot` with canonical additive financial fields and change its identity from event-only to `(event_id, currency)`.                                                                                                                                                                                                                     |
| Objective | Make durable analytics projections currency-safe and capable of representing MG2/MG4–MG8 primitives.                                                                                                                                                                                                                                                            |
| Output    | Updated `lib/event_sales/analytics/resources/event_aggregate_snapshot.ex`.                                                                                                                                                                                                                                                                                      |
| Note      | Gross/refund quantities and values are non-negative magnitudes; recognised order count is non-negative. Do not add persisted Net or ATV. Retain legacy `total_sold`, `total_revenue`, `today_*` fields for compatibility only. Add a narrowly scoped destroy action if required for 02E obsolete-currency cleanup. Do not change `DailySalesAggregateSnapshot`. |

## TOON 02D-2 — Safe Ash migration/codegen

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Generate and review the AshPostgres migration/resource snapshot for EventAggregateSnapshot v2.                                                                                                                                                                                                                                                                                                                      |
| Objective | Make the schema transition deterministic without inventing canonical financial values for existing v1 rows.                                                                                                                                                                                                                                                                                                         |
| Output    | One generated migration plus updated Ash resource snapshot.                                                                                                                                                                                                                                                                                                                                                         |
| Note      | Use the repository’s normal Ash migration generator. Drop the event-only identity/index and create event+currency uniqueness. New additive fields may receive safe storage defaults for migration compatibility, but existing `snapshot_version = 1` must remain the marker that their canonical financial values are not authoritative. Do not backfill invented Gross/Refund numbers. No unrelated codegen drift. |

## TOON 02D-3 — Version/identity regression tests

| Field     | Content                                                                                                                                                                                                                                                                         |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Add persistence tests for event+currency uniqueness and version-1 compatibility.                                                                                                                                                                                                |
| Objective | Prove the schema can represent multiple currencies while preserving legacy rows safely.                                                                                                                                                                                         |
| Output    | Tests in `test/event_sales/analytics/historical_reporting_snapshots_test.exs` and resource smoke tests only if needed.                                                                                                                                                          |
| Note      | Required cases: same event + different currencies allowed; same event + same currency duplicate rejected/upsertable according to resource contract; v1 row remains identifiable as v1; canonical derived Net/ATV are absent from persistence. Do not test PRE-M5-TIME behavior. |

## TOON 02D-4 — Concurrency identity proof

| Field     | Content                                                                                                                                                                                                           |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Prove database uniqueness prevents duplicate event+currency projections under concurrent writes.                                                                                                                  |
| Objective | Establish the DB guard required before transactional multi-currency refresh is implemented.                                                                                                                       |
| Output    | Focused concurrent persistence test.                                                                                                                                                                              |
| Note      | Use independent DB connections/tasks where required by sandbox rules. Do not introduce Redis locks. STOP if uniqueness cannot safely arbitrate the race. Run focused tests, `mix quality.fast`, `mix quality.pr`. |

---

# 10. PRE-M5-02E — Refresh, Reader and Compatibility Integration

## Outcome

Make snapshot refresh write complete currency-partitioned v2 projections and make canonical readers consume them safely.

## TOON 02E-1 — Transactional multi-currency refresh

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Replace `SnapshotRefresh.refresh_event/2` raw event-row aggregation with `EventAggregator` canonical currency summaries and persist the complete v2 currency projection set transactionally.                                                                                                                                                                                                                                                  |
| Objective | Ensure one refresh produces an internally coherent event financial projection without arbitrary currency selection.                                                                                                                                                                                                                                                                                                                           |
| Output    | Updated `snapshot_refresh.ex` and focused snapshot integration tests.                                                                                                                                                                                                                                                                                                                                                                         |
| Note      | Set event financial snapshot writer version to `2`. Upsert each returned `(event_id,currency)` row. Remove obsolete v2 currency rows for the event inside the same transaction so stale currencies cannot remain visible. Do not delete unrelated/v1 history unless the migration/compatibility contract explicitly owns it. Invalidate `DashboardCache` only after successful durable transaction. No Redis lock. No daily snapshot changes. |

## TOON 02E-2 — Canonical SnapshotReader APIs

| Field     | Content                                                                                                                                                                                                                                                              |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Add currency-aware canonical event-financial reader APIs to `SnapshotReader`.                                                                                                                                                                                        |
| Objective | Give M5 a bounded snapshot-only interface that never uses `LIMIT 1` to choose between currencies.                                                                                                                                                                    |
| Output    | Canonical plural event reader and explicit event+currency reader in `snapshot_reader.ex`, with focused tests.                                                                                                                                                        |
| Note      | Canonical APIs read only compatible snapshot-v2 financial data. Return currency-keyed results deterministically. Version-1 rows are a canonical miss/non-authoritative condition, not zero-valued financial truth. No sales/refund table access from SnapshotReader. |

## TOON 02E-3 — Legacy reader fail-closed compatibility

| Field     | Content                                                                                                                                                                                                                                                                                                                            |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Define explicit legacy `SnapshotReader.summary_for_event/1` behavior over snapshot v1/v2 without arbitrary mixed-currency selection.                                                                                                                                                                                               |
| Objective | Preserve existing callers while preventing incorrect scalar money totals.                                                                                                                                                                                                                                                          |
| Output    | Updated legacy reader tests and compatibility behavior.                                                                                                                                                                                                                                                                            |
| Note      | A single compatible currency may be adapted to the legacy scalar shape. Multiple v2 currencies must return an explicit mixed-currency error. If no v2 canonical projection exists, existing v1 compatibility may remain available only as explicitly legacy data; never expose v1 fields through the new canonical financial APIs. |

## TOON 02E-4 — Dashboard/hot-state safety

| Field     | Content                                                                                                                                                                                                                                                                                                                                                                  |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Task      | Verify and minimally adapt dashboard/hot-state consumers to the new compatibility contracts.                                                                                                                                                                                                                                                                             |
| Objective | Ensure cache rebuilds and dashboard reads cannot select an arbitrary currency or reintroduce raw-history financial scans.                                                                                                                                                                                                                                                |
| Output    | Minimal changes, if required, to `event_scoped_dashboard.ex` and/or hot-state rebuild behavior plus focused tests in `event_scoped_dashboard_test.exs`, `rebuild_hot_state_worker_test.exs`, and `hot_state_aggregator_test.exs`.                                                                                                                                        |
| Note      | `RebuildHotStateWorker` already delegates to `EventAggregator`; prefer benefiting from 02C rather than creating another path. Mixed-currency error must fail closed and must not become zero revenue presented as valid data if that obscures the error. Preserve authorize-before-existence behavior and `can_view_revenue?` masking. Do not redesign the dashboard UI. |

## TOON 02E-5 — Refresh atomicity regression

| Field     | Content                                                                                                                                                                                                                                                                                                                                    |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Task      | Add a failure-path test proving a multi-currency refresh cannot expose only part of the new projection set.                                                                                                                                                                                                                                |
| Objective | Protect the event snapshot lifecycle against partial refresh state.                                                                                                                                                                                                                                                                        |
| Output    | Transaction/failure regression in snapshot tests.                                                                                                                                                                                                                                                                                          |
| Note      | Force failure after at least one planned currency write using a controlled test seam or DB constraint appropriate to existing patterns. After rollback, previously committed projection state must remain intact and no partial new currency set may be visible. Do not add production-only failure hooks that remain permanently exposed. |

## TOON 02E-6 — 02E validation

| Field     | Content                                                                                                                                                                                                |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Task      | Run the complete focused integration set and prepare 02E for review.                                                                                                                                   |
| Objective | Verify projections, compatibility, authorization and hot-state behavior together.                                                                                                                      |
| Output    | Green targeted tests, `mix quality.fast`, `mix quality.pr`, PR and Linear evidence.                                                                                                                    |
| Note      | Include snapshot tests, EventAggregator tests, dashboard tests, hot-state/rebuild tests and M4 LocalTotals regression. No WordPress runtime is required unless a concrete existing test depends on it. |

---

# 11. PRE-M5-02F — Metrics Certification

## Outcome

Prove MG2 + MG4–MG8 are implemented to contract and close only `GAP-PRE-M5-METRICS`.

## TOON 02F-1 — Acceptance matrix certification

| Field     | Content                                                                                                                                                                                                                                                                                                                                   |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Map every PRE-M5 metrics regression requirement to a concrete automated test and fill any genuine coverage gap.                                                                                                                                                                                                                           |
| Objective | Make closure of `GAP-PRE-M5-METRICS` evidence-based rather than inferred from PR history.                                                                                                                                                                                                                                                 |
| Output    | Certification table in the 02F PR description/docs mapping each acceptance item to exact test module/test name; minimal additional tests where missing.                                                                                                                                                                                   |
| Note      | Must cover: historical Gross preservation; tax-inclusive Gross; refund qty/value Net effects; Gross unchanged by refund; negative Net; distinct order count; zero-denominator ATV; two currencies; mixed-currency legacy failure; operational status isolation; v1 fail-closed canonical read; bounded dashboard path; M4 non-regression. |

## TOON 02F-2 — Performance certification

| Field     | Content                                                                                                                                                                                                                                                                                                |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Task      | Certify that canonical financial dashboard/cache reads use snapshots/cache and that refresh/rebuild aggregation is bounded by indexed Postgres queries.                                                                                                                                                |
| Objective | Prove the PRE-M5 metric design is suitable for the later M5 read path and does not create peak-time history scans.                                                                                                                                                                                     |
| Output    | Query-plan evidence and targeted structural tests/search evidence.                                                                                                                                                                                                                                     |
| Note      | Confirm `SnapshotReader` does not reference Sales/Refund resources; confirm canonical dashboard path does not issue OrderItem/Refund history scans; confirm EventAggregator aggregation uses bounded grouped SQL. No large-table scans during dashboard requests. Do not introduce M5-08 caching work. |

## TOON 02F-3 — M4 reconciliation regression

| Field     | Content                                                                                                                                                                                                 |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task      | Perform final financial-semantic comparison against M4 certified reconciliation tests.                                                                                                                  |
| Objective | Ensure Analytics and Reconciliation share the same underlying financial meaning.                                                                                                                        |
| Output    | Passing FinancialPrimitives + LocalTotals + EventAggregator suites with documented parity.                                                                                                              |
| Note      | Any difference in historical recognition, tax-inclusive value, refund qualification, currency or negative-Net behavior is a STOP condition. Scope orchestration may differ; arithmetic meaning may not. |

## TOON 02F-4 — Metrics closeout documentation

| Field     | Content                                                                                                                                                                              |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Task      | Update canonical PRE-M5 programme docs and Linear only after the final implementation merge and post-merge CI are verified.                                                          |
| Objective | Close `GAP-PRE-M5-METRICS` and hand off cleanly to PRE-M5-TIME.                                                                                                                      |
| Output    | Docs-only closeout commit/PR if repository workflow requires it; Linear issues marked complete with merge/CI evidence.                                                               |
| Note      | Wording must be: `GAP-PRE-M5-READY-IX = CLOSED (unchanged)`, `GAP-PRE-M5-METRICS = CLOSED`, `GAP-PRE-M5-TIME = OPEN`, `M5 = BLOCKED`, `NEXT = PRE-M5-TIME`. 02F closes METRICS only. |

---

# 12. Regression matrix ownership

| Requirement                                | Owning slice      | Primary test                                         |
| ------------------------------------------ | ----------------- | ---------------------------------------------------- |
| Gross survives current refunded status     | 02B/02C           | `metric_rules_test.exs`, `event_aggregator_test.exs` |
| Gross includes `line_total_tax`            | 02B/02C           | same                                                 |
| Refund qty reduces Net qty                 | 02B/02C           | same                                                 |
| Refund value reduces Net value             | 02B/02C           | same                                                 |
| Gross unaffected by refund                 | 02B/02C           | same                                                 |
| Over-refund remains negative               | 02B               | `metric_rules_test.exs`                              |
| Two ticket lines / one order → count 1     | 02C               | `event_aggregator_test.exs`                          |
| Distinct counts not additive across scopes | 02C/02F           | aggregator certification                             |
| Zero Net Tickets → ATV N/A                 | 02B               | `metric_rules_test.exs`                              |
| ZAR + USD separate                         | 02C/02D/02E       | aggregator + snapshot tests                          |
| Legacy mixed currency fails closed         | 02C/02E           | aggregator + reader tests                            |
| Status context does not change finance     | 02B/02F           | `metric_rules_test.exs`                              |
| v1 not canonical v2 truth                  | 02D/02E           | snapshot tests                                       |
| Dashboard avoids raw history scans         | 02C/02F           | structural/query-plan proof                          |
| M4 unchanged                               | every slice / 02F | `local_totals_test.exs`                              |

---

# 13. Minimal tool/command policy

Use only what the current slice needs.

## Every new slice

```bash
git fetch origin
git status --short
git branch --show-current
git rev-parse HEAD
git rev-parse origin/main
```

Start only from the authorized current `main`.

## Discovery

Prefer:

```bash
rg
```

Use `ast-grep` only when structural search genuinely improves the task.

## Tests

Run the directly affected focused tests during implementation.

At slice completion:

```bash
mix quality.fast
```

Before meaningful PR review:

```bash
mix quality.pr
```

Do not run local WordPress, Redis, Phoenix or the full integrated environment unless the slice actually needs them.

02B should need none.

02C–02F should primarily need Postgres through normal test setup.

## GitHub

Use GitHub only when the local slice is ready for PR/review/CI.

Do not repeatedly poll while local work is incomplete.

## Linear

Create/update the specific PRE-M5 sub-slice issue only.

Record:

```text
baseline SHA
authority docs
branch
PR
approved head
merge SHA
post-merge CI
final verdict
```

Do not mark Complete before verified merge + post-merge CI.

---

# 14. Branch sequence

Recommended:

```text
path1/pre-m5-ready-ix-doc-closeout

path1/pre-m5-02b-metric-kernel
path1/pre-m5-02c-event-currency-aggregation
path1/pre-m5-02d-event-snapshot-v2
path1/pre-m5-02e-snapshot-integration
path1/pre-m5-02f-metrics-certification
```

Never stack later implementation branches on an unmerged predecessor unless explicitly authorized.

Preferred flow:

```text
slice N
→ review
→ merge
→ post-merge CI
→ sync main
→ slice N+1
```

---

# 15. Universal STOP conditions

The agent must STOP and return evidence if:

```text
origin/main moved unexpectedly before the slice starts

working tree contains unrelated unexplained changes that would be overwritten

M1-05/M1-06/M1-08 authority conflicts with this plan

FinancialPrimitives formulas would need duplication

LocalTotals would become the runtime dashboard API

historical Gross requires current status == completed

refund joins multiply Gross/refund facts

Recognised Order Count is being summed from overlapping aggregates

different currencies would be combined

legacy LIMIT 1 would select an arbitrary currency

Net or ATV would be persisted

negative Net would be clamped

snapshot v1 would be advertised as canonical v2 truth

multi-currency refresh cannot be transactional

database uniqueness cannot prevent duplicate event+currency rows

PRE-M5-TIME behavior becomes necessary for the current task

dashboard requests require raw history scans

a critical aggregation query lacks a safe index

M4 reconciliation semantics regress

Ash migration/resource snapshot contains unrelated drift

focused tests fail

mix quality.fast fails

mix quality.pr fails

CI runs against a different head than the reviewed candidate
```

Do not work around a STOP condition by expanding scope.

---

# 16. Final programme success

Only after 02F merges and exact post-merge CI passes:

```text
PRE-M5-02A              COMPLETE
PRE-M5-02B              COMPLETE
PRE-M5-02C              COMPLETE
PRE-M5-02D              COMPLETE
PRE-M5-02E              COMPLETE
PRE-M5-02F              COMPLETE

GAP-PRE-M5-READY-IX     CLOSED (UNCHANGED)
GAP-PRE-M5-METRICS      CLOSED
GAP-PRE-M5-TIME         OPEN

M5                       BLOCKED
NEXT                     PRE-M5-TIME
```

PRE-M5 metrics completion does **not** authorize M5 by itself.
