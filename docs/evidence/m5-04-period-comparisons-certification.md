# M5-04 period comparisons — G2 certification evidence (JC-326)

## 1. Verdict

**PASS** (certification-only; no production semantic changes; no STOP gates triggered).

Load/rebuild/fence/backfill measurements recorded below. Harness is not part of default CI timing gates.

## 2. Authority / identities

```text
LINEAR = JC-326
BASE_SHA = d527cb9cc9afab930c0f007ed2ff6b20a4095086
BASE_TREE = 2949fed049e55a82e8fc95ff8f29424c951542e6
PLAN_VERSION = v17
JC_326_STATUS = IN_REVIEW
M5_04G1_DURABLE_AUTHORITY = YES
M5_04G2_STATUS = IN_PROGRESS
M5_04G2_DURABLE_AUTHORITY = PENDING_MERGE
M5_04_COMPLETE = NO
CERTIFICATION_VERDICT = PASS
```

## 3. Environment

```text
LOAD_ENVIRONMENT = local PostgreSQL TEST (127.0.0.1:55433)
DB_POOL_SIZE = 10 (config/test.exs TEST_DATABASE_POOL_SIZE default)
LOAD_RUN_POOL_SIZE = 10 (same; load evidence test uses unboxed workers per connection)
PGBOUNCER_RUNTIME_CERTIFIED = NO
```

## 4. Semantic reconciliation

G2 suite: `test/event_sales/analytics/m5_04_period_reconciliation_test.exs`

Oracle: `EventAggregator.financial_summaries_for_event_period/2` for preset windows; **today previous-equivalent** and other partial windows use certification-only `EventSales.TestSupport.M5_04PeriodRawOracle` (canonical sale/refund predicates, half-open UTC bounds).

```text
TODAY_CURRENT_ORACLE = PASS
TODAY_PREVIOUS_EQUIVALENT_ORACLE = PASS (raw boundary oracle; test "today previous-equivalent operand reconciles via raw boundary oracle")
YESTERDAY_ORACLE = PASS
ROLLING_7_ORACLE = PASS
ROLLING_30_ORACLE = PASS
EVENT_PRIMITIVE_RECONCILIATION = PASS
```

## 5. Dimensional reconciliation

```text
TICKET_TYPE_RECONCILIATION = PASS
SOURCE_PRODUCT_RECONCILIATION = PASS
SOURCE_VARIATION_SUBSET_RECONCILIATION = PASS
```

## 6. Replay / refund transitions

Delegated regression (exact test names in cited files):

```text
SALE_EXACT_REPLAY = PASS (period_projection_invalidator_test.exs, refund_upserter_test.exs)
REFUND_EXACT_REPLAY = PASS
UNRESOLVED_TO_COMPLETE = PASS (period_projection_invalidator_test.exs)
```

## 7. Concurrency races (G2 entry)

`test/event_sales/analytics/m5_04_period_concurrency_test.exs` exercises G2-only cases directly:

| Test | Requirement |
|------|-------------|
| `late refund commits during rolling reader RR transaction stays coherent` | Late refund + RR operand payload stability; post-commit operand growth |
| `exact replay after refresh produces no contribution semantic churn` | Refresh/replay fingerprint stability |
| `same-event refresh callers serialize while distinct events run in parallel` | Same-event vs distinct-event refresh parallelism |

Delegated RR barrier (unchanged):

```text
RR_READER_WRITER = PASS (period_comparison_reader_concurrency_test.exs — "repeatable read transaction keeps one snapshot across an interleaved writer commit")
LATE_REFUND_READER_RACE = PASS (m5_04_period_concurrency_test.exs above)
EXACT_REPLAY_REFRESH_RACE = PASS (m5_04_period_concurrency_test.exs above)
```

## 8. Historical catch-up churn (live Oban)

`test/event_sales/analytics/m5_04_period_backfill_churn_test.exs` — `G2 live catch-up batches enqueue and execute refresh workers without pathological churn`

```text
BACKFILL_ORDER_COUNT = 20
BACKFILL_REFUND_MUTATION_COUNT = 0
BACKFILL_PAGE_COUNT = 4
BACKFILL_REFRESH_ENQUEUE_ATTEMPTS = 4
BACKFILL_OBAN_JOBS_CREATED = >= 4 (refresh worker rows for event)
BACKFILL_OBAN_CONFLICTS = 0 (not asserted; uniqueness not stressed in this fixture)
BACKFILL_REFRESH_EXECUTIONS = >= 4 (completed RefreshSnapshotWorker jobs)
BACKFILL_REBUILD_COUNT = via worker executions (same counter)
TERMINAL_COVERAGE_ENQUEUE_COUNT = final ensure_event_buckets + terminal refresh
BACKFILL_FINAL_PENDING_BUCKET_COUNT = 0
BACKFILL_FINAL_STALE_BUCKET_COUNT = 0
BACKFILL_FINAL_READER_READY = YES (rolling 7 compare_event :ready)
BACKFILL_FENCE_ACQUISITIONS = NOT_DIRECTLY_OBSERVABLE (no production fence counter instrumentation)
BACKFILL_CHURN_VERDICT = PASS
```

## 9. Query plans

G2 sale/refund population gate: `m5_04_period_query_plan_test.exs` — `G2 sale and refund population plans stay event-bounded` (indexes `sales_order_items_event_id_idx`, refund line index family).

Delegated EXPLAIN suites (rerun in G2 validation batch):

| Area | File | Representative test |
|------|------|---------------------|
| Fixed + edge reads | `period_comparison_reader_query_plan_test.exs` | bounded projection / unnest plans |
| Sale population | `period_projection_query_plan_test.exs` | event-scoped sale population |
| Dimensions | `period_dimension_projection_query_plan_test.exs` | dimension replacement reads |
| Eligible events + JHB envelope | `period_coverage_query_plan_test.exs` | coverage planner reads |

```text
QUERY_PLAN_SALE = PASS
QUERY_PLAN_REFUND = PASS
QUERY_PLAN_DIMENSIONS = PASS (delegated suite)
QUERY_PLAN_FIXED_READ = PASS (delegated suite)
QUERY_PLAN_EDGE_READ = PASS (delegated suite)
QUERY_PLAN_ELIGIBLE_EVENTS = PASS (delegated suite)
QUERY_PLAN_JHB_ENVELOPE = PASS (delegated suite)
NEW_INDEX_REQUIRED = NO
```

## 10. Reader load

```text
LOAD_HARNESS = scripts/certification/m5_04_period_load.exs
LOAD_HARNESS_IMPL = test/support/m5_04_period_load_harness.ex
LOAD_EVIDENCE_TEST = test/event_sales/analytics/m5_04_period_load_evidence_test.exs (@tag :m5_04_certification_load)
LOAD_COMMAND = TEST_DATABASE_POOL_SIZE=10 M5_04_LOAD_SAMPLES=40 bash scripts/dev_local.sh test test/event_sales/analytics/m5_04_period_load_evidence_test.exs
LOAD_HARNESS_REAL_READER_CALLS = YES (PeriodComparisonReader.compare_event/4)
LOAD_SAMPLE_SIZE = 40
LOAD_CONCURRENCY_COHORTS = [1, 5, 10, 20]
MAX_READER_CONCURRENCY_TESTED = 20
READER_ERRORS = 0
READER_NOT_READY_COUNT = 0
```

Reader latency (ms, concurrency=1 / p50 of cohort; p95/p99 at max tested concurrency 20 where listed):

| Request | p50 (c=1) | p95 (c=20) | p99 (c=20) |
|---------|-----------|------------|------------|
| `:today` | 13 | 17 | 18 |
| `:yesterday` | 4 | 7 | 7 |
| `{:rolling_days, 7}` | 59 | 83 | 90 |
| `{:rolling_days, 30}` | 190 | 284 | 292 |

Full cohort table (stdout artifact `tmp/m5_04_period_load_evidence.txt` + harness stdout):

```text
READER request=:today concurrency=20 samples=40 errors=0 not_ready=0 p50=16 p95=17 p99=18 max=18
READER request=:yesterday concurrency=20 samples=40 errors=0 not_ready=0 p50=6 p95=7 p99=7 max=7
READER request={:rolling_days, 7} concurrency=20 samples=40 errors=0 not_ready=0 p50=72 p95=83 p99=90 max=90
READER request={:rolling_days, 30} concurrency=20 samples=40 errors=0 not_ready=0 p50=263 p95=284 p99=292 max=292
```

## 11. DB queue / pool (reader cohort window)

Ecto `[:event_sales, :repo, :query]` telemetry during harness run:

```text
DB_QUEUE_P50 = 0
DB_QUEUE_P95 = 0
DB_QUEUE_P99 = 0
POOL_TIMEOUTS = 0
```

`queue_time` is sub-millisecond for this fixture; no pool starvation at concurrency 20 with pool 10.

## 12. Reader memory

Rolling 30, 40 sequential calls in harness parent process:

```text
READER_MEMORY_FIXTURE = single-event ZAR sale + projection refresh
READER_MEMORY_DELTA_BYTES = -709848 (GC noise; no monotonic growth)
READER_MEMORY_VERDICT = BOUNDED
```

## 13. Rebuild load

`SnapshotRefresh.refresh_event/1` tiers (10 repetitions each):

| Tier | Contribution sales | p50 | p95 | p99 |
|------|-------------------|-----|-----|-----|
| small | 1 | 7 | 12 | 12 |
| medium | 5 | 7 | 7 | 7 |
| large_local | 12 | 7 | 7 | 7 |

```text
REBUILD_FIXTURE_SIZES = small, medium, large_local
REBUILD_SAMPLE_SIZE = 10 per tier
ZERO_COVERAGE_REBUILD = covered by G1 closure suites (not re-timed in harness)
LATE_REFUND_REBUILD = covered by reconciliation + invalidator suites (not re-timed in harness)
```

## 14. Same-event / distinct-event fence pressure

From `m5_04_period_concurrency_test.exs` (6 same-event parallel refreshes, 2-event parallel control):

```text
SAME_EVENT_CONCURRENCY_COHORTS = 6
SAME_EVENT_FENCE_PRESSURE = PASS (all {:ok, _} same event; serializes through fence without errors)
DISTINCT_EVENT_CONCURRENCY_COHORTS = 2
DISTINCT_EVENT_PARALLELISM = PASS (distinct events refresh concurrently)
```

## 15. Freshness / PubSub decision

Post-refresh: `SnapshotRefresh` calls `DashboardCache.invalidate_event(event_id, :snapshot_refresh)` after successful DB refresh (`lib/event_sales/analytics/snapshot_refresh.ex`). Period comparison operands are read from Postgres projections, not DashboardCache.

`event_dimension_snapshot_refresh_test.exs` asserts cache invalidation on refresh for legacy dashboard summaries.

```text
PUBSUB_DECISION = NO_CHANGE
PUBSUB_EVIDENCE = No period-comparison PubSub gap reproduced; management freshness remains Postgres-projection + existing DashboardCache invalidation on refresh. Hot-state PubSub remains out of period reader path.
```

## 16. Cache / Redis decision

```text
CACHE_DECISION = NO_CHANGE
REDIS_DECISION = NO_CHANGE
CACHE_REDIS_EVIDENCE = Rolling-30 reader p99 292ms at concurrency 20 with pool 10; DB queue p99 0ms; zero pool timeouts. Postgres acceptable for interactive management reader at certified fixture scale.
```

## 17. Security / isolation

```text
REVENUE_REDACTION = PASS (period_comparison_reader_policy_test.exs)
CROSS_EVENT_ISOLATION = PASS (period_comparison_reader_isolation_test.exs)
CROSS_CURRENCY_ISOLATION = PASS
PII_IN_EVIDENCE = NO
```

## 18. Validation commands (G2 batch)

```text
bash scripts/dev_local.sh test test/event_sales/analytics/m5_04_period_reconciliation_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/m5_04_period_concurrency_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/m5_04_period_backfill_churn_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/m5_04_period_query_plan_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/period_comparison_reader_concurrency_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/period_comparison_reader_query_plan_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/period_projection_query_plan_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/period_dimension_projection_query_plan_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/period_coverage_query_plan_test.exs
TEST_DATABASE_POOL_SIZE=10 M5_04_LOAD_SAMPLES=40 bash scripts/dev_local.sh test test/event_sales/analytics/m5_04_period_load_evidence_test.exs
```

## 19. Explicit non-certifications

```text
100K_CONCURRENT_USERS_CERTIFIED = NO
PRODUCTION_HARDWARE_LATENCY_CERTIFIED = NO
CROSS_REGION_CERTIFIED = NO
```
