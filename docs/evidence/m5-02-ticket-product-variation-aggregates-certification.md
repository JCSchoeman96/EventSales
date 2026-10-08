# M5-02 — Ticket / product / variation aggregates certification evidence

| Field | Value |
| --- | --- |
| Plan ID | m5-02-ticket-product-variation-aggregates |
| Plan version | v4 |
| Linear | JC-299 (M5-02F) |
| Status | COMPLETE (PASS) |
| M5_02F_PR | 276 |
| M5_02F_MERGE_SHA | `fdd3b4bfb96e31f8c099774f93f4091fe9e915c0` |
| Programme base SHA | `191666b670d4c0d9dac1b6c91d30201a0300358a` |
| Programme base tree | `c25e9192cf8e5049ea0619e248a4306bf30c5beb` |
| Last updated | 2026-10-08 |

### Revision log

- `v4` — M5-02F merge authority (PR #276); exact-head CI provenance; durable COMPLETE (PASS).
- `v3` — B23 matrix cites `order_upserter_historical_coverage_test.exs` (mutation enqueue + negative controls), not dimension refresh persistence tests.
- `v2` — Full slice merge authority (M5-02B–F); auditable PASS matrix with test citations; EventDetail readiness propagation evidence.
- `v1` — Initial M5-02F EventDetail conformance draft.

---

## Slice merge authority

| Slice | PR | Merge SHA | Notes |
| --- | --- | --- | --- |
| M5-02B | [#272](https://github.com/JCSchoeman96/EventSales/pull/272) | `57e01b1e61ecb10783336c52614b7e75535835ef` | `EventDimensionAggregateSnapshot` resource + migration |
| M5-02C | [#273](https://github.com/JCSchoeman96/EventSales/pull/273) | `a2746c0b640ac7adeeac0556c0ea6db94d4f37cd` | `DimensionAggregator` + query plans |
| M5-02D | [#274](https://github.com/JCSchoeman96/EventSales/pull/274) | `ddc3e21f048e281d1aa2c49c0a9c10aeb33922db` | `SnapshotRefresh` dimensional persist + invalidation |
| M5-02E | [#275](https://github.com/JCSchoeman96/EventSales/pull/275) | `191666b670d4c0d9dac1b6c91d30201a0300358a` | `DimensionSnapshotReader` + policy |
| M5-02F | [#276](https://github.com/JCSchoeman96/EventSales/pull/276) | `fdd3b4bfb96e31f8c099774f93f4091fe9e915c0` | Implementation commit `799d1ffd7d81614af387a79f1570f152eb0729d1` (reviewed); correction commits on same PR |

### M5-02F exact-head CI (verified)

```text
M5_02F_FINAL_HEAD = e351082b0ce0d3a671240bfb8c0e9469777bf204
M5_02F_EXACT_HEAD_CI_RUN = 36763020324
M5_02F_EXACT_HEAD_CI_RUN_NUMBER = 724
M5_02F_EXACT_HEAD_CI_ATTEMPT = 1
M5_02F_EXACT_HEAD_CI = PASS
```

---

## M5-02F EventDetail runtime contract

```text
OUTER_COHERENT_TRANSACTION = YES (EventSnapshotRefreshFence.coherent_transaction_opts)
ADVISORY_LOCK = NONE in EventDetail path
ANALYTICS_READY = AnalyticsReadinessResolver before projection reads
FINANCIAL = SnapshotReader.financial_summaries_for_event (gross qty/value, tax-inclusive)
TICKET = DimensionSnapshotReader :ticket_type + catalogue zero-row merge
STATUS = operational Option A (current order status, SUM quantity, mapped tickets)
refreshed_at = nil
```

Nested `DimensionSnapshotReader` `Repo.transaction` executes inside the outer transaction (Ecto 3.14: same transaction, not a savepoint). `Repo.rollback` from the reader aborts the outer EventDetail read.

---

## Acceptance matrix (PASS evidence)

| Requirement | Verdict | Automated evidence |
| --- | --- | --- |
| Dimension grain invariants (`ticket_type`, `source_product`, `source_variation`) | PASS | `test/event_sales/analytics/event_dimension_aggregate_snapshot_test.exs` |
| Currency partitioning (per-order currency, no cross-currency sums) | PASS | `test/event_sales/analytics/dimension_aggregator_test.exs`; `m5_02_dimension_reconciliation_test.exs` (multi-currency) |
| Historical completion (refunded/cancelled + `completed_at`) | PASS | `test/event_sales/analytics/event_detail_test.exs` ("historical completion includes refunded orders") |
| Tax-inclusive gross (`line_total + line_total_tax`) | PASS | `test/event_sales/analytics/event_detail_test.exs` (capacity/remaining test); `m5_02_dimension_reconciliation_test.exs` |
| Null / product-only variation (no synthetic variation row) | PASS | `test/event_sales/analytics/event_dimension_snapshot_refresh_test.exs` ("product-only line"); `m5_02_dimension_reconciliation_test.exs` |
| ProductMapping independence (historical line identity, not mapping id) | PASS | `test/event_sales/analytics/dimension_aggregator_test.exs` ("ignores ProductMapping creation") |
| Transactional dimension full replace | PASS | `test/event_sales/analytics/event_dimension_snapshot_refresh_test.exs` ("second refresh removes obsolete dimensional grains") |
| Rollback preservation on failed refresh | PASS | `test/event_sales/analytics/event_snapshot_refresh_rollback_test.exs` |
| Same-event refresh concurrency / fence | PASS | `test/event_sales/analytics/event_snapshot_refresh_concurrency_test.exs` |
| B23 dimension-identity invalidation enqueue | PASS | `test/event_sales/sales/order_upserter_historical_coverage_test.exs`: same-event `ticket_type_id`, `woo_product_id`, and `woo_variation_id` changes each request the Event snapshot refresh; ProductMapping-only and TicketType catalogue-only mutations do not enqueue refresh |
| `DimensionSnapshotReader` authorization | PASS | `test/event_sales/analytics/dimension_snapshot_reader_policy_test.exs` |
| `DimensionSnapshotReader` revenue redaction policy | PASS | `test/event_sales/analytics/dimension_snapshot_reader_policy_test.exs` |
| Reader coherent projection read (event v2 + dimensions) | PASS | `test/event_sales/analytics/dimension_snapshot_reader_test.exs` |
| Bounded TicketType / SourceSystem enrichment, no N+1 | PASS | `test/event_sales/analytics/dimension_snapshot_reader_test.exs` (query count assertions) |
| EventDetail global-admin policy | PASS | `test/event_sales/analytics/event_detail_test.exs` ("facade rejects missing and non-admin actors") |
| ANALYTICS_READY management gate | PASS | `test/event_sales/analytics/event_detail_test.exs` ("blocks when analytics are not ready") |
| Pending readiness propagation (`financial_reconciliation_pending`) | PASS | `test/event_sales/analytics/event_detail_test.exs` ("propagates financial reconciliation pending readiness") |
| Failed/mismatched readiness propagation (`financial_reconciliation_failed`) | PASS | `test/event_sales/analytics/event_detail_test.exs` ("propagates failed mismatched reconciliation readiness") |
| EventDetail canonical v2 financial source | PASS | `test/event_sales/analytics/event_detail_test.exs`; `event_detail_query_bound_test.exs` (static boundary) |
| EventDetail dimensional ticket source | PASS | `test/event_sales/analytics/event_detail_test.exs` (ticket rows + unsold zeros) |
| Raw financial aggregate query = 0 | PASS | `test/event_sales/analytics/event_detail_query_bound_test.exs` (SQL telemetry + static) |
| Raw ticket aggregate query = 0 | PASS | `test/event_sales/analytics/event_detail_query_bound_test.exs` |
| Option-A operational status query = 1 | PASS | `test/event_sales/analytics/event_detail_query_bound_test.exs` |
| Outer coherent transaction + nested rollback | PASS | `test/event_sales/analytics/event_detail_test.exs` ("projection rollback aborts outer transaction") |
| Event↔ticket parity (per currency) | PASS | `test/event_sales/analytics/m5_02_dimension_reconciliation_test.exs` |
| Event↔product parity (per currency) | PASS | `test/event_sales/analytics/m5_02_dimension_reconciliation_test.exs` |
| Variation exact subset (variation-bearing lines only) | PASS | `test/event_sales/analytics/m5_02_dimension_reconciliation_test.exs` |
| Multi-currency independent reconciliation | PASS | `test/event_sales/analytics/m5_02_dimension_reconciliation_test.exs` ("multi-currency reconciles independently") |
| Mixed-currency scalar fail-closed (`EventDetail`) | PASS | `test/event_sales/analytics/event_detail_test.exs` ("mixed currency events fail closed") |
| No double counting across dimension families | PASS | `test/event_sales/analytics/m5_02_dimension_reconciliation_test.exs` (families sum > event gross) |
| `SnapshotReader` / `DimensionSnapshotReader` production change in M5-02F | N/A | No production change in PR #276 beyond `event_detail.ex` |
| New migration / index / cache / worker | NONE | PR #276 scope |

---

## Residual risks / non-goals

```text
status_breakdown =
  operational current-state context
  NOT canonical financial or dimensional truth

M5-03 refund / net / ATV dimensional metrics = OUT OF SCOPE
M5-04 period-preset dimensional aggregates = OUT OF SCOPE
M5-08 cache acceleration = OUT OF SCOPE
```

---

## Local validation bundle (M5-02F)

```bash
bash scripts/dev_local.sh test test/event_sales/analytics/event_detail_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/m5_02_dimension_reconciliation_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/event_detail_query_bound_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/dimension_snapshot_reader_test.exs
bash scripts/dev_local.sh test test/event_sales/analytics/dimension_snapshot_reader_policy_test.exs
bash scripts/dev_local.sh test test/event_sales/ingestion/analytics_readiness_resolver_test.exs
bash scripts/dev_local.sh quality-pr
```

Exact-head GitHub CI on PR #276 final reviewed head: PASS (run #724, attempt 1; see M5-02F exact-head CI block above).
