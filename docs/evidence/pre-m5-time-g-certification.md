# PRE-M5-TIME-G — Time foundation certification evidence

| Field | Value |
| --- | --- |
| Plan ID | PRE-M5-TIME-G1 |
| Version | v2 |
| Status | Merged and certified; PR #264 |
| Scope | Certify the PRE-M5-TIME implementation against M1-07 T1–T31 and TIME-B through TIME-F |
| Certification base SHA | `2e387f8f3a750c7cd5a0d10bd39a0d4fdf243f0c` |
| Certification base tree | `1f5f2715e009167a58ac777b178567a35e93184c` |
| TIME-F PR | [#263](https://github.com/JCSchoeman96/EventSales/pull/263) |
| TIME-F merge SHA | `2e387f8f3a750c7cd5a0d10bd39a0d4fdf243f0c` |
| TIME-F post-merge CI | [#691 / run 36461645968](https://github.com/JCSchoeman96/EventSales/actions/runs/36461645968), 6/6 PASS on the merge SHA |
| Certification branch | `path1/pre-m5-time-g-certification` |
| Certification PR | [#264](https://github.com/JCSchoeman96/EventSales/pull/264) |
| Approved head | `c23053a4f1c0d98f502a23f938f3b7c6ecc4a977` |
| Certification merge SHA | `c1fc8cd02b1809d3fd97e379b16dfec29d65b870` |
| Certification merge tree | `0a2db09c3634a19ebb9c9e253794cd67b2658703` |
| Certification post-merge CI | [#695 / run 36525412734](https://github.com/JCSchoeman96/EventSales/actions/runs/36525412734) — 6/6 PASS |
| Last updated | 2026-09-29 |

### Revision log

- v2 — PR #264 merged as `c1fc8cd02b1809d3fd97e379b16dfec29d65b870`; approved HEAD `c23053a4f1c0d98f502a23f938f3b7c6ecc4a977`; merge tree matched the approved HEAD tree; exact merge-SHA CI #695 / run 36525412734 passed all six jobs; TIME-G1 certification complete.

## Owner decisions

```text
ALL_EVENTS_FRESHNESS_POLICY = COMBINED_SIGNALS
CUSTOM_RANGE_MAX = 90 Johannesburg civil days
```

M1-07 T23 deferred the custom-range numeric maximum. The later owner decision records 90 Johannesburg civil days without changing M1-07 T1–T31. It does not enable `:custom` financial querying. `EventAggregator.financial_summaries_for_event_period/2` remains preset-only and returns `{:error, :unsupported_period_kind}` for `:custom`.

## Verified implementation history

PR numbers, branch heads, merge SHAs, and the TIME-F CI run below were checked against repository history and GitHub. TIME-C-IDX did not produce a migration or index change. The TIME-C period query plan test certifies the indexed paths that already existed.

| Slice | PR | Merge SHA | Verified record |
| --- | --- | --- | --- |
| TIME-A | [#254](https://github.com/JCSchoeman96/EventSales/pull/254) | `089983a4755904c43464224a2a0b1e35f2f31ed4` | PRE-M5-TIME implementation plan |
| TIME-B | [#255](https://github.com/JCSchoeman96/EventSales/pull/255) | `3b379571ce137747fddb33094faf16c68957619f` | Pure `TimeRules` kernel |
| TIME-C | [#256](https://github.com/JCSchoeman96/EventSales/pull/256) | `a28c29e3c8f778c13746d58117e457cb319b7ceb` | Bounded period aggregation and query-plan proof |
| TIME-C-IDX | N/A | N/A | No index migration was created; TIME-C query-plan evidence passed on existing indexed paths |
| TIME-C-COMPAT | [#257](https://github.com/JCSchoeman96/EventSales/pull/257) | `6363d9050ec3b063309ba66308b1ef2e6a4d35d8` | Legacy Today sale-effective alignment |
| TIME-D | [#258](https://github.com/JCSchoeman96/EventSales/pull/258) | `71b3c23aa28c03f41c06c08c2869e4def1a96a6d` | Durable source-freshness projection and reader |
| TIME-E1 | [#259](https://github.com/JCSchoeman96/EventSales/pull/259) | `66a3d2fae99e31c0fe4cd7e63f12a79956196a98` | Order source-freshness advancement |
| TIME-E2 | [#260](https://github.com/JCSchoeman96/EventSales/pull/260) | `4c09b238185ae903a27bcefc17788c59f2177b13` | Refund source-freshness advancement |
| TIME-E3 | [#261](https://github.com/JCSchoeman96/EventSales/pull/261) | `a8e0064901fd2c18a6cfc1ab2a657638ee87d007` | Terminal catch-up source-freshness advancement |
| Mint security recovery | [#262](https://github.com/JCSchoeman96/EventSales/pull/262) | `84653cfe4b143a7eeae19b243b0aa46ba7efa803` | `mix.lock` pins Mint 1.11.0; this recovery changed `mix.lock` only |
| TIME-F | [#263](https://github.com/JCSchoeman96/EventSales/pull/263) | `2e387f8f3a750c7cd5a0d10bd39a0d4fdf243f0c` | Post-merge CI run 36461645968 passed `test`, `format_compile`, `ash_codegen`, `dialyzer`, `lint_security`, and `playwright_unit` |
| TIME-G1 | [#264](https://github.com/JCSchoeman96/EventSales/pull/264) | `c1fc8cd02b1809d3fd97e379b16dfec29d65b870` | Merged and certified; exact merge-SHA CI #695 / 36525412734 6/6 PASS |

## Acceptance matrix

| ID | Requirement | Contract authority | Implementation authority | Automated evidence | Verdict |
| --- | --- | --- | --- | --- | --- |
| TG01 | `paid_at` is the preferred sale clock, `completed_at` is the fallback, and missing both fails. Recognition remains independently status-gated. | M1-07 T4–T6 | `TimeRules.sale_effective_at/1`; `EventAggregator` coalesced sale predicate and recognition filter | `TimeRulesTest` paid/completed/missing-clock cases; `EventAggregatorTest` paid-clock placement, completed fallback, and unrecognised paid order cases | PASS |
| TG02 | `Refund.source_created_at` is the only refund effective clock; missing it fails closed. | M1-07 T7–T8 | `TimeRules.refund_effective_at/1`; period refund predicate | `TimeRulesTest` authoritative and missing refund clock cases; `EventAggregatorTest` missing refund effective-time case | PASS |
| TG03 | Reporting uses `Africa/Johannesburg`; named-zone conversion uses `DateTime.shift_zone/2`; Today and Yesterday use Johannesburg civil boundaries. | M1-07 §12 (T17–T19) and §14 (T20–T23) | `TimeRules.business_date/2`, `today_bounds/2`, and `yesterday_bounds/2` | `TimeRulesTest` named-zone business date, Today boundary, Yesterday boundary, and UTC crossover cases | PASS |
| TG04 | Period membership is half-open `[start_utc, end_utc)`, including start and excluding end. | M1-07 §13; T19 | `TimeRules.period_contains?/2`; bounded sale and refund predicates in `EventAggregator` | `TimeRulesTest` start/end membership cases; `EventAggregatorTest` sale and refund start/end boundary cases | PASS |
| TG05 | Rolling 7-day and 30-day windows use exact UTC durations ending at `now`. | M1-07 §14; T21–T22 | `TimeRules.rolling_bounds/2`, `last_7_days_bounds/1`, and `last_30_days_bounds/1` | `TimeRulesTest` exact 7×24-hour and 30×24-hour duration cases | PASS |
| TG06 | The owner decision is 90 Johannesburg civil days; custom financial aggregation remains disabled. | M1-07 T23 deferred the number; PRE-M5-TIME plan §11.1 records the later owner decision | `TimeRules.custom_civil_bounds/3` normalizes civil bounds; `EventAggregator` period whitelist rejects `:custom` | `PreM5TimeCertificationTest` normalizes a 90-day custom period and asserts `:unsupported_period_kind` | PASS |
| TG07 | Gross and recognized order count use the sale period; refund adjustment uses the independent refund period. | M1-07 T24 | `EventAggregator.financial_summaries_for_event_period/2` | `PreM5TimeCertificationTest` places paid time yesterday, completion today, and refund source time today; asserts yesterday gross/count and today refund only | PASS |
| TG08 | Recognized sales and qualifying refunds with no authoritative effective clock are withheld. | M1-07 T25 | `assert_no_missing_sale_effective_time/1` and `assert_no_missing_refund_effective_time/1` | `EventAggregatorTest` missing sale and missing refund effective-time cases; `TimeRulesTest` missing-clock cases | PASS |
| TG09 | Financial period queries stay event-scoped, bounded, and indexed. | M1-07 §22; PRE-M5-TIME plan §13 | Event-period SQL predicates and existing event-first indexes | `EventAggregatorFinancialQueryPlanTest` period path: six query paths, selective noise fixture, three iterations, bound parameters, indexed plans, no unbounded `sales_orders` scan | PASS |
| TG10 | One durable source-freshness row exists per event, independent of currency; the anchor is derived on read and classification is not persisted. | M1-07 §9; PRE-M5-TIME plan §4 | `EventSourceFreshnessSnapshot` unique event identity and three component columns; `SourceFreshness` derives the anchor | `SourceFreshnessTest` exactly-one-row and independent-component cases; `PreM5TimeCertificationTest` asserts one row for the event | PASS |
| TG11 | Order, refund, and terminal catch-up producers converge on one durable row using distinct source clocks. | M1-07 §9; PRE-M5-TIME plan §§4–5 | `OrderProcessedNotifier`, `RefundProcessedNotifier`, `HistoricalCatchupFreshnessNotifier`, and `SourceFreshness` | `PreM5TimeCertificationTest` calls all three public notifier seams and checks the three distinct persisted clocks and the newest anchor | PASS |
| TG12 | Each component advances on newer time, leaves equal time unchanged, ignores older time, and separate component writes do not clobber each other. | M1-07 T26; PRE-M5-TIME plan §14 | Field-specific monotonic Postgres upsert conditions in `EventSourceFreshnessSnapshot` | `SourceFreshnessTest` newer/equal/older replays for order, refund, and sync; concurrent order/refund writes preserve both components | PASS |
| TG13 | Age below 5 minutes is normal; 5 through 10 minutes is aging; above 10 minutes is stale. Future anchors clamp to zero and emit low-cardinality clock-skew telemetry. | M1-07 T13–T16 | `TimeRules.classify_source_freshness/2`; `SourceFreshness` telemetry | `TimeRulesTest` exact 5m/10m boundaries and future anchor; `SourceFreshnessTest` future-anchor telemetry | PASS |
| TG14 | Missing row and all-nil component row both return `{:error, :missing_source_freshness_anchor}`. | M1-07 §9 and T10 | `SourceFreshness.classify_snapshot/2` | `SourceFreshnessTest` missing-row and all-nil-row cases; `AdminDashboardTest` all-missing portfolio case | PASS |
| TG15 | A manual Postgres-to-hot-state rebuild can make the read model ready while source freshness remains stale and unchanged. | M1-07 T27; PRE-M5-TIME plan invariant | `RebuildHotStateWorker` writes the hot and warm read models; source freshness reads its Postgres projection | `AdminDashboardTest` manual rebuild case asserts ready read model, stale source classification, and unchanged persisted components | PASS |
| TG16 | Postgres source-freshness projection is authoritative; ETS, Redis, PubSub, and hot-state lifecycle are not source-freshness truth. | M1-07 T10, T28–T29; PRE-M5-TIME plan §§13–14 | `SourceFreshness` reads `EventSourceFreshnessSnapshot` through Ash/Postgres; no Redis or Cachex source-freshness path | `SourceFreshnessTest` durable projection lifecycle; `AdminDashboardTest` rebuild separation; source reader is a direct projection read | PASS |
| TG17 | Admin portfolio source freshness reads one bounded event set with one batch call, not one Postgres read per event. | M1-07 §22; PRE-M5-TIME plan §10 | `AdminDashboard.snapshot/1` calls `SourceFreshness.for_events/2` once; `for_events/2` issues one projection read | `AdminDashboardTest` `snapshot uses one batch freshness call for the bounded event set` | PASS |
| TG18 | Portfolio classification uses the worst available event classification; portfolio anchor uses the newest available anchor; missing counts remain separate. | PRE-M5-TIME plan §4; owner decision `COMBINED_SIGNALS` | `AdminDashboard.aggregate_source_freshness/1` computes classification and anchor independently | `AdminDashboardTest` newer normal plus older stale case, mixed missing count case, and all-missing case | PASS |
| TG19 | Event-scoped reads validate UUID, authorize, check event existence, then read aggregates and freshness. Unauthorized actors cannot invoke the freshness reader. | `docs/development/pre-m5-02-metrics-foundation.plan.md` §19 Security and access | `EventScopedDashboard.summary/2` executes UUID cast, authorization, event lookup, and summary construction in that order | `EventScopedDashboardTest` — "unassigned valid UUID is forbidden before event existence is revealed" injects `SourceFreshnessRecorder` and asserts the freshness reader is not called; invalid UUID and authorized unknown-event cases preserve the remaining ordering. | PASS |
| TG20 | Durable projection changes precede PubSub notification; PubSub is event-scoped delivery, not source time. Live updates do not poll. | M1-07 T28 | `SourceFreshness` writes before broadcasting; `DashboardPubSub` uses `analytics:event:<event_id>`; LiveView subscribes to displayed event topics | `SourceFreshnessTest` persistence and notification cases; `DashboardLiveTest` source-freshness PubSub refresh updates one row; `EventDetailLiveTest` source-freshness PubSub handling | PASS |
| TG21 | Daily snapshot v1 remains a legacy read model; canonical period reporting uses `TimeRules` bounds and `EventAggregator.financial_summaries_for_event_period/2`. | M1-07 T30; PRE-M5-TIME plan §19 | `SnapshotRefresh`/`SnapshotReader` daily v1 path is separate from the canonical period aggregator | `HistoricalReportingSnapshotsTest` daily refresh/reader cases; `EventAggregatorTest` canonical period cases | PASS |
| TG22 | M1-07 T1–T31 remain unchanged. The later 90-day decision resolves T23's deferred value and does not rewrite its history. | M1-07 T1–T31; PRE-M5-TIME owner decision | G1 edits the PRE-M5-TIME owner-decision section only | `git diff --exit-code 2e387f8f3a750c7cd5a0d10bd39a0d4fdf243f0c -- docs/path-1/m1-07-timestamp-johannesburg-period-and-freshness-contract.md`; owner decision in PRE-M5-TIME plan §11.1 | PASS |

## Performance and scaling review

| Layer | Certified role | Evidence |
| --- | --- | --- |
| Hot | ETS through `DashboardCache` and `HotStateAggregator` holds derived read-model summaries. | `AdminDashboardTest` rebuild separation case |
| Warm | Redis snapshot adapter stores recoverable hot-state summaries with a TTL. | `SnapshotStore.RedixAdapter`; `RebuildHotStateWorker` writes read-model snapshots |
| Cold | Postgres holds source facts and the durable `EventSourceFreshnessSnapshot`. | `SourceFreshness` Ash/Postgres reader and writer; `SourceFreshnessTest` durable lifecycle cases |

The analytics source-freshness path does not use Redis or Cachex. Dashboard KPI summaries use hot or snapshot readers. The portfolio freshness path batches the bounded displayed event set and does not scan order or refund facts. Period aggregation remains event-scoped and bounded; its query-plan certification passed. There is no global source-freshness lock. PubSub topics remain event-scoped, and LiveView updates use push notifications.

```text
NEW MIGRATIONS = NONE
NEW INDEXES = NONE
DEPENDENCY CHANGES = NONE
PRODUCTION CODE CHANGES = NONE
```

## Validation record

| Command | Result |
| --- | --- |
| `bash scripts/dev_local.sh test test/event_sales/analytics/pre_m5_time_certification_test.exs` | 3 tests, 0 failures |
| `bash scripts/dev_local.sh test test/event_sales/analytics/time_rules_test.exs` | 31 tests, 0 failures |
| `bash scripts/dev_local.sh test test/event_sales/analytics/event_aggregator_test.exs test/event_sales/analytics/event_aggregator_financial_query_plan_test.exs` | 34 tests, 0 failures; 32 aggregator and 2 query-plan tests |
| `bash scripts/dev_local.sh test test/event_sales/analytics/source_freshness_test.exs` | 32 tests, 0 failures |
| `bash scripts/dev_local.sh test` with the four TIME-E producer suites | 72 tests, 0 failures |
| `bash scripts/dev_local.sh test` with hot-state, rebuild, admin, and event-scoped dashboard suites | 56 tests, 0 failures |
| `bash scripts/dev_local.sh test test/event_sales/analytics/historical_reporting_snapshots_test.exs` | 19 tests, 0 failures |
| `mix ash.codegen --check` | PASS, exit 0 |
| `mix project.index` and `mix project.index --check` | PASS, generated `INDEX.md` and architecture index files; check reported current |
| `mix quality.fast` | PASS, exit 0 |
| `mix hex.audit` and `mix deps.audit` | PASS, no advisories found |
| `bash scripts/dev_local.sh quality-pr` | PASS, 2,574 tests and 0 failures |
| `git diff --check` | PASS |

## Programme state

```text
PRE-M5-TIME = COMPLETE (PASS)

GAP-PRE-M5-METRICS = CLOSED
GAP-PRE-M5-READY-IX = CLOSED
GAP-PRE-M5-TIME = CLOSED

M5 = AUTHORIZED

NEXT = M5-01 — Base Event Aggregates
```

## G2 closeout protocol note

After TIME-G1 certification, PR #265 merged as `c3e7b1d85a4ca93583bebc187a2164024bae2d81` from approved head `2de6875cb2b94bab53dee2b00f667464e0c2378e`. PR CI #696 / run 36529470280 passed all six jobs.

Protected-main governance now requires the PR checks followed by verification of merge parents and tree identity. The workflow has no `push: main` trigger, so an automatic duplicate post-merge CI run is not expected. This records repository closeout procedure and does not define TIME semantics.
