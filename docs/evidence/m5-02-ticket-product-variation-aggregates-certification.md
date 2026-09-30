# M5-02 — Ticket / product / variation aggregates certification evidence

| Field | Value |
| --- | --- |
| Plan ID | m5-02-ticket-product-variation-aggregates |
| Plan version | v2 |
| Linear | JC-299 (M5-02F) |
| Status | IMPLEMENTATION COMPLETE (pending PR merge) |
| Authority base SHA | `191666b670d4c0d9dac1b6c91d30201a0300358a` |
| Authority base tree | `c25e9192cf8e5049ea0619e248a4306bf30c5beb` |
| M5-02E merge | PR #275 at `191666b670d4c0d9dac1b6c91d30201a0300358a` |
| M5-02F PR | TBD |
| Last updated | 2026-09-30 |

### Revision log

- `v1` — M5-02F EventDetail conformance, ANALYTICS_READY gate, reconciliation certification, query-bound static proof.

---

## Slice evidence summary

| Slice | Deliverable | Automated evidence |
| --- | --- | --- |
| M5-02B | `EventDimensionAggregateSnapshot` resource + migration | Resource tests, grain validations |
| M5-02C | `DimensionAggregator` + query plans | `dimension_aggregator_test.exs`, `dimension_aggregator_query_plan_test.exs` |
| M5-02D | `SnapshotRefresh` dimensional persist + B23 | `event_dimension_snapshot_refresh_test.exs` |
| M5-02E | `DimensionSnapshotReader` + policy | `dimension_snapshot_reader_test.exs`, `dimension_snapshot_reader_policy_test.exs` |
| M5-02F | `EventDetail` canonical read + reconciliation | `event_detail_test.exs`, `m5_02_dimension_reconciliation_test.exs`, `event_detail_query_bound_test.exs` |

---

## M5-02F EventDetail conformance

```text
OUTER_COHERENT_TRANSACTION = YES (EventSnapshotRefreshFence.coherent_transaction_opts)
ADVISORY_LOCK = NONE in EventDetail path
ANALYTICS_READY = AnalyticsReadinessResolver before projection reads
FINANCIAL = SnapshotReader.financial_summaries_for_event (gross qty/value, tax-inclusive)
TICKET = DimensionSnapshotReader :ticket_type + catalogue zero-row merge
STATUS = operational Option A (current order status, SUM quantity, mapped tickets)
refreshed_at = nil (unchanged)
```

Nested `DimensionSnapshotReader` `Repo.transaction` joins the outer transaction (Ecto 3.14 semantics: same transaction, shared rollback).

---

## Reconciliation matrix (PASS targets)

| Check | Verdict |
| --- | --- |
| Dimension grains | PASS (`m5_02_dimension_reconciliation_test.exs`) |
| Currency partition | PASS (multi-currency independent reconcile) |
| Historical completion | PASS (`event_detail_test.exs` refunded + completed_at) |
| Tax-inclusive gross | PASS (line_total + line_total_tax) |
| Null variation product-only | PASS (variation exact subset fixture) |
| Event↔ticket parity | PASS |
| Event↔product parity | PASS |
| Variation exact subset | PASS |
| Mixed currency scalar fail-closed | PASS |
| No double counting across families | PASS |
| EventDetail raw financial SQL | PASS (removed `scoped_summary`, `ticket_type_aggregate_rows`) |
| ANALYTICS_READY gate | PASS |
| Outer coherent transaction | PASS (implementation + rollback test) |

---

## Residual risks / non-goals

```text
status_breakdown remains operational raw context, not financial truth
M5-03 refund/net/ATV dimensional metrics = OUT OF SCOPE
M5-04 period dimensions = OUT OF SCOPE
M5-08 cache acceleration = OUT OF SCOPE
```
