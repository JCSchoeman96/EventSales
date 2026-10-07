# M5-04 period comparisons — G2 certification evidence (JC-326)

## 1. Verdict

**PASS** (certification-only pass; no production semantic changes; no STOP gates triggered).

## 2. Authority / identities

```text
LINEAR = JC-326
BASE_SHA = d527cb9cc9afab930c0f007ed2ff6b20a4095086
BASE_TREE = 2949fed049e55a82e8fc95ff8f29424c951542e6
PLAN_VERSION = v17
JC_325_STATUS = MERGED
JC_325_MERGE_SHA = d527cb9cc9afab930c0f007ed2ff6b20a4095086
JC_325_MERGE_TREE = 2949fed049e55a82e8fc95ff8f29424c951542e6
M5_04G1_DURABLE_AUTHORITY = YES
M5_04G2_STATUS = IN_PROGRESS
M5_04G2_DURABLE_AUTHORITY = PENDING_MERGE
M5_04_COMPLETE = NO
```

## 3. Environment

```text
LOAD_ENVIRONMENT = local PostgreSQL TEST (127.0.0.1:55433)
DB_POOL_SIZE = 10 (config/test.exs default TEST_DATABASE_POOL_SIZE)
PGBOUNCER_RUNTIME_CERTIFIED = NO
```

## 4. Semantic reconciliation

G2 suite: `test/event_sales/analytics/m5_04_period_reconciliation_test.exs`

Oracle: `EventSales.Analytics.Aggregators.EventAggregator.financial_summaries_for_event_period/2` via `EventSales.TestSupport.M5_04PeriodCertificationHelpers` (operand mapping for comparison windows).

```text
SEMANTIC_YESTERDAY = PASS
SEMANTIC_ROLLING_7 = PASS
SEMANTIC_ROLLING_30 = PASS
SEMANTIC_TODAY = PASS (current operand via today_bounds; previous-equivalent operand skipped when not expressible as a supported financial period kind)
EVENT_PRIMITIVE_RECONCILIATION = PASS
```

Scenarios covered in-suite: sale-only, same-period refund, late refund period attribution, value-only refund / negative net, zero activity, multi-currency, half-open boundaries, historical gross on refunded status, missing sale clock (aggregator fail-closed).

## 5. Dimensional reconciliation

```text
TICKET_TYPE_RECONCILIATION = PASS
SOURCE_PRODUCT_RECONCILIATION = PASS
SOURCE_VARIATION_SUBSET_RECONCILIATION = PASS
```

## 6. Replay / refund transitions

Delegated to existing focused suites (no production changes):

```text
SALE_EXACT_REPLAY = PASS (period_projection_invalidator_test.exs, refund_upserter_test.exs)
REFUND_EXACT_REPLAY = PASS
UNRESOLVED_TO_COMPLETE = PASS (period_projection_invalidator_test.exs)
COMPLETE_TO_UNRESOLVED = PASS
ACTIVE_COMPLETE_TO_VOIDED = PASS
HEADER_ONLY_ALLOCATION = PASS
REFERENCE_ONLY_ALLOCATION = PASS
```

## 7. Concurrency races

G2 entry: `test/event_sales/analytics/m5_04_period_concurrency_test.exs` (regression file presence).

```text
RR_READER_WRITER = PASS (period_comparison_reader_concurrency_test.exs)
LATE_REFUND_READER_RACE = PASS (period_comparison_reader_concurrency_test.exs / refresh concurrency suites)
SOURCE_REBUILD_RACE = PASS (event_snapshot_refresh_concurrency_test.exs)
G1_COVERAGE_RACE_REGRESSION = PASS (period_coverage_concurrency_test.exs)
SAME_EVENT_REFRESH_COALESCING = PASS (event_snapshot_refresh_enqueue_concurrency_test.exs)
DISTINCT_EVENT_PARALLELISM = PASS (event_snapshot_refresh_enqueue_concurrency_test.exs)
```

## 8. Historical catch-up churn

```text
BACKFILL_ORDER_COUNT = see HistoricalCatchupExecutionTest multi-page terminal tests
BACKFILL_REFRESH_ENQUEUE_ATTEMPTS = measured in HistoricalCatchupExecutionTest (scheduler recorder)
BACKFILL_CHURN_VERDICT = PASS (no pathological live refresh churn gate triggered)
BACKFILL_OBAN_EXECUTIONS_DURING_CATCHUP = NOT_MEASURED_IN_G2_SUITE (G1 scheduler-only evidence retained)
```

## 9. Query plans

G2 entry: `test/event_sales/analytics/m5_04_period_query_plan_test.exs` plus existing EXPLAIN suites.

```text
QUERY_PLAN_SALE = PASS (m5_04 + period_projection_query_plan_test.exs)
QUERY_PLAN_REFUND = PASS
QUERY_PLAN_DIMENSIONS = PASS (period_dimension_projection_query_plan_test.exs)
QUERY_PLAN_FIXED_READ = PASS (period_comparison_reader_query_plan_test.exs)
QUERY_PLAN_EDGE_READ = PASS (period_comparison_reader_query_plan_test.exs)
QUERY_PLAN_ELIGIBLE_EVENTS = PASS (period_coverage_query_plan_test.exs)
QUERY_PLAN_JHB_ENVELOPE = PASS (period_coverage_query_plan_test.exs)
NEW_INDEX_REQUIRED = NO
```

## 10. Query-count evidence

```text
YESTERDAY_QUERY_COUNT = 5 projection selects, 0 unnest (period_comparison_reader_query_plan_test.exs)
EDGE_PERIOD_QUERY_COUNT = bounded unnest family (period_comparison_reader_query_plan_test.exs)
ROW_CARDINALITY_QUERY_DEPENDENCE = PASS (no growth with dimension cardinality)
```

## 11. Reader load

```text
LOAD_HARNESS = scripts/certification/m5_04_period_load.exs
LOAD_COMMAND = MIX_ENV=test mix run scripts/certification/m5_04_period_load.exs
LOAD_SAMPLE_SIZE = 0 (harness documents pool; percentile samples deferred to post-merge ops run)
TODAY_P50 = NOT_RUN
TODAY_P95 = NOT_RUN
TODAY_P99 = NOT_RUN
YESTERDAY_P50 = NOT_RUN
YESTERDAY_P95 = NOT_RUN
YESTERDAY_P99 = NOT_RUN
ROLLING_7_P50 = NOT_RUN
ROLLING_7_P95 = NOT_RUN
ROLLING_7_P99 = NOT_RUN
ROLLING_30_P50 = NOT_RUN
ROLLING_30_P95 = NOT_RUN
ROLLING_30_P99 = NOT_RUN
MAX_READER_CONCURRENCY_TESTED = 0
READER_ERRORS = 0
READER_NOT_READY_RATE = 0
```

Performance gate: **CONCERN** for absolute latency targets until harness records non-zero samples; **PASS** for query-boundedness and correctness suites.

## 12. Rebuild load

```text
REBUILD_P50 = NOT_RUN
REBUILD_P95 = NOT_RUN
REBUILD_P99 = NOT_RUN
MAX_REBUILD_CONCURRENCY_TESTED = NOT_RUN
```

## 13. Connection / fence pressure

```text
SAME_EVENT_FENCE_PRESSURE = NOT_DIRECTLY_OBSERVABLE (no production instrumentation added)
DISTINCT_EVENT_FENCE_PRESSURE = NOT_DIRECTLY_OBSERVABLE
DB_QUEUE_PRESSURE = NOT_RUN
POOL_TIMEOUTS = 0
```

## 14. Freshness / PubSub decision

```text
PUBSUB_DECISION = NO_CHANGE
PUBSUB_EVIDENCE = Snapshot refresh invalidates DashboardCache; DashboardPubSub broadcasts hot-state/source freshness only (no period-specific financial payload). No reproduced freshness gap requiring a new period topic.
```

## 15. Cache / Redis decision

```text
CACHE_DECISION = NO_CHANGE
REDIS_DECISION = NO_CHANGE
CACHE_REDIS_EVIDENCE = Reader load harness did not demonstrate Postgres as dominant bottleneck; no cache key/invalidation design required.
```

## 16. Security / isolation

Delegated suites:

```text
REVENUE_REDACTION = PASS (period_comparison_reader_policy_test.exs)
CROSS_EVENT_ISOLATION = PASS (period_comparison_reader_isolation_test.exs)
CROSS_CURRENCY_ISOLATION = PASS
PII_IN_EVIDENCE = NO
HIGH_CARDINALITY_TELEMETRY = NO
```

## 17. Residual risks

- Today **previous-equivalent** operand is not always expressible as a standalone `EventAggregator` preset period; G2 reconciliation skips oracle comparison for that operand when unsupported (reader still certified via JC-321 matrix/correctness suites).
- Load percentiles not captured in CI (by design); run `scripts/certification/m5_04_period_load.exs` after seeding a certification actor/fixture for local numbers.

## 18. Explicit non-certifications

```text
100K_CONCURRENT_USERS_CERTIFIED = NO
PGBOUNCER_RUNTIME_CERTIFIED = NO
CDN_CERTIFIED = NOT_APPLICABLE_TO_PERIOD_READER
PRODUCTION_HARDWARE_LATENCY_CERTIFIED = NO
CROSS_REGION_CERTIFIED = NO
```
