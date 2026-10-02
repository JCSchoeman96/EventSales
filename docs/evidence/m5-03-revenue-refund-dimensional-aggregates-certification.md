# M5-03F - Revenue/refund dimensional aggregates certification

| Field | Value |
| --- | --- |
| Plan ID | `m5-03-revenue-refund-dimensional-aggregates` |
| Linear | JC-308 |
| Status | IN REVIEW (manual merge required) |
| Programme base SHA | `c2a4d7eb181ed7c8f84d2e98d7e3116b915df176` |
| Programme base tree | `8c07cfc096a668a9977ff2f83c2d99f84b6b2970` |
| M5-03F PR | PENDING |
| M5-03F merge | PENDING |
| Last updated | 2026-10-02 |

## Scope

M5-03F adds one integrated reconciliation test and this evidence document. It
does not change production code, resources, migrations, indexes, workers,
schedulers, Redis, Cachex, EventDetail, or UI.

The test uses real sales and refund facts, `SnapshotRefresh.refresh_event/1`,
the canonical v2 event snapshots, and `DimensionSnapshotReader`. The fixture
contains ZAR and USD, variation-bearing and product-only ticket lines, a normal
quantity refund, an exact value-only refund, and a complete header-only refund.

## Slice merge authority

| Slice | PR | Merge SHA |
| --- | --- | --- |
| M5-03A | [#277](https://github.com/JCSchoeman96/EventSales/pull/277) | `51a257f5eadc9ca0d8d26f838a8658b8a1b3729c` |
| M5-03B | [#278](https://github.com/JCSchoeman96/EventSales/pull/278) | `b682164a38b9f48401ef74ea29fb9d4c6d3690d4` |
| M5-03C | [#279](https://github.com/JCSchoeman96/EventSales/pull/279) | `c89b5ddd172d25bb1de9af11a046615016ea8768` |
| M5-03D | [#280](https://github.com/JCSchoeman96/EventSales/pull/280) | `e247ab84a495148653eee2f48b91d99129768358` |
| M5-03E | [#281](https://github.com/JCSchoeman96/EventSales/pull/281) | `c2a4d7eb181ed7c8f84d2e98d7e3116b915df176` |
| M5-03F | PENDING | PENDING |

## Acceptance matrix

| Requirement | Verdict | Evidence |
| --- | --- | --- |
| Resource refund fields, defaults, and constraints | PASS | `event_dimension_aggregate_snapshot_test.exs`: `refund fields default to zero when omitted`, `explicit refund values persist for each grain kind`, `negative refund_ticket_quantity fails`, `negative refund_ticket_value fails`, `postgres refund_ticket_quantity check rejects negative values`, `postgres refund_ticket_value check rejects negative values` |
| Three grain identities and shape checks | PASS | `event_dimension_aggregate_snapshot_test.exs`: `ticket_type creates`, `source_product creates`, `source_variation creates`, and the `invalid grain shapes` tests |
| Canonical refund predicate | PASS | `EventAggregator.refund_primitives_filters/0`; `event_aggregator_test.exs`: `refund on never-recognised order does not produce canonical refund primitives`, `financial_summaries_for_event applies qualifying refunds without changing gross`; `dimension_aggregator_test.exs`: `excludes non-qualifying refunds from dimensional aggregation` |
| Exact historical parent binder | PASS | `refund_upserter_test.exs`: `persists complete detail and binds a line to the exact parent order item`; `dimension_aggregator_test.exs`: `requires exact two-part parent binder for dimensional refunds`, `uses parent line identity for refunds when refund line product evidence differs` |
| ProductMapping historical independence | PASS | `dimension_aggregator_test.exs`: `ignores ProductMapping changes for dimensional refund identity`; the test covers later ProductMapping create and `:remap` without changing `DimensionAggregator.financial_rows_for_event/1` |
| Value-only refund | PASS | `m5_03_revenue_refund_dimension_reconciliation_test.exs`: `reconciles refund, net, variation, currency, and ATV projections`; existing `event_dimension_snapshot_refresh_test.exs`: `value-only refund persists a positive value with zero refund quantity`; existing `dimension_aggregator_test.exs`: `counts value-only refunds without quantity` |
| Header-only refund has no dimensional allocation | PASS | The M5-03F test keeps the ZAR event refund value at `10.50`, excluding the unallocated `20.00` header amount; `event_dimension_snapshot_refresh_test.exs`: `header-only refund does not allocate dimensional ticket refunds`; `refund_upserter_historical_coverage_test.exs`: `header-only value refunds invalidate every bounded parent Event` |
| Six dimensional aggregate queries | PASS | `dimension_aggregator_query_plan_test.exs`: `financial_rows_for_event uses six bounded dimensional aggregates under selective data` |
| Refund EXPLAIN evidence | PASS | `dimension_aggregator_query_plan_test.exs`: the six-query test classifies all three refund queries and runs `EXPLAIN (FORMAT JSON)` with indexed refund-line and refund-header access checks; `event_aggregator_financial_query_plan_test.exs`: `financial_summaries_for_event uses indexed event-scoped plans under selective data` |
| Full replacement and stale-row removal | PASS | `event_dimension_snapshot_refresh_test.exs`: `full replacement removes a refund-only grain when source aggregation no longer returns it`, `second refresh removes obsolete dimensional grains`, `voided refund refresh removes dimensional refund primitives and keeps gross`, `unresolved refund refresh removes prior dimensional refund primitives` |
| Rollback | PASS | `event_snapshot_refresh_rollback_test.exs`: `failed dimensional bulk insert rolls back event and dimension projections and leaves cache intact`, `failed multi-currency refresh rolls back and leaves cache intact` |
| Same-event serialization and concurrency | PASS | `event_snapshot_refresh_concurrency_test.exs`: `concurrent refresh_event calls block on the PostgreSQL session fence`, `two concurrent refreshes keep event and dimension refund primitives coherent`, `two concurrent refresh_event calls on the same source leave one coherent projection set` |
| Refund invalidation and replay behavior | PASS | `refund_upserter_historical_coverage_test.exs`: `new normalized historical detail invalidates its exact Event certificate`, `an exact normalized replay does not invalidate coverage`, `active to voided invalidates the BEFORE exact Event candidates`, `header-only value refunds invalidate every bounded parent Event` |
| Reader authorization-first behavior | PASS | `dimension_snapshot_reader_policy_test.exs`: `unassigned unknown valid uuid is forbidden before event or projection reads`, `unassigned valid uuid is forbidden before dimension projection is read`, `nil actor is forbidden` |
| Money redaction | PASS | `dimension_snapshot_reader_policy_test.exs`: `global admin sees revenue`, `event owner hides revenue by default`, `event owner and staff revenue follows dashboard settings` |
| PII is absent | PASS | `dimension_snapshot_reader_test.exs`: `reads all dimension kinds with multi-currency grouping and stable ordering` asserts `pii_visibility == :none` and rejects PII keys; the M5-03F test repeats the result assertion |
| Four reconciliation readiness triggers | PASS | `analytics_readiness_resolver_test.exs`: `returns pending when no terminal reconciliation exists`, plus the generated `maps latest mismatched terminal evidence without an older PASS fallback`, `maps latest failed terminal evidence without an older PASS fallback`, and `maps latest cancelled terminal evidence without an older PASS fallback` tests |
| Generation coherence | PASS | `event_dimension_snapshot_refresh_test.exs`: `multi-currency dimensional rows and event snapshots share one generation`; `dimension_snapshot_reader_test.exs`: `generation mismatch fails closed`, `orphan dimension currency fails closed` |
| Reader query-count bounds | PASS | `dimension_snapshot_reader_test.exs`: `projection and catalogue query counts stay flat as row cardinality grows`, `catalogue enrichment uses one TicketType and one SourceSystem query for multi-currency output`; `event_detail_query_bound_test.exs`: `get_event_detail SQL capture excludes raw financial and ticket aggregates` |
| Event to ticket-type gross/refund/net parity | PASS | `m5_03_revenue_refund_dimension_reconciliation_test.exs`: `reconciles refund, net, variation, currency, and ATV projections` |
| Event to source-product gross/refund/net parity | PASS | Same M5-03F test. Ticket and product families are checked independently for each currency |
| Variation exact subset | PASS | The M5-03F test checks variation-bearing ZAR and USD parents only, verifies their gross/refund/net values, and proves the product-only line has no variation row |
| Product-only line has no variation identity | PASS | The M5-03F test asserts product `9012` appears in `ticket_type` and `source_product` with `woo_variation_id == nil` and never appears in `source_variation`; existing `event_dimension_snapshot_refresh_test.exs`: `product-only line creates ticket and product rows without variation` |
| Currency isolation | PASS | The M5-03F test reads independent `ZAR` and `USD` event snapshots and dimension buckets, with no cross-currency sum or conversion; existing `m5_02_dimension_reconciliation_test.exs`: `multi-currency reconciles independently` |
| Family non-additivity | PASS | The M5-03F test proves `ticket_type + source_product + source_variation` gross quantity is not the event total; existing `m5_02_dimension_reconciliation_test.exs`: `integrated refresh reconciles event, ticket, and product per currency` also proves the parallel-family rule |
| ATV non-additivity | PASS | The M5-03F test uses different row ATVs and derives rolled ATV with `MetricRules.derive_financial_metrics/1`; it rejects both the sum and arithmetic average of row ATVs |
| EventDetail gross compatibility | PASS | `event_detail_test.exs`: `historical completion includes refunded orders with completion evidence`, `operational status_breakdown is current-state context not financial totals`; M5-03F does not modify EventDetail or redefine `sold`/`revenue` |
| EventDetail query boundary | PASS | `event_detail_query_bound_test.exs`: `certified get_event_detail succeeds without legacy raw financial helpers in module`, `get_event_detail SQL capture excludes raw financial and ticket aggregates`, `projection rollback emits no operational status SQL after nested rollback` |
| No new index, cache, Redis, worker, or scheduler | PASS | Changed paths are limited to the M5-03F test and this document. The plan's M5-03F exclusions and `INDEX_DECISION = NONE` remain unchanged |

## Canonical arithmetic and reconciliation notes

The integrated fixture is checked independently for each event currency.
Gross, refund quantity, refund value, net quantity, and net value all match
between the event snapshot and both the `ticket_type` and `source_product`
families. Net uses `MetricRules.derive_financial_metrics/1`, which delegates
net subtraction to `FinancialPrimitives.derive_net_totals/1`. No net or ATV
field is persisted.

The value-only ZAR refund has `refunded_quantity == 0` and tax-inclusive value
`4.50`. It increases refund value without changing refund or net quantity. The
header-only ZAR refund has positive unallocated header money but no exact bound
ticket line, so it contributes zero to every dimensional family and to the
canonical event refund primitives.

Variation rows are the exact subset of historical parent lines with a non-null
`woo_variation_id`. The ZAR product-only line contributes to ticket type and
source product only. The three families are parallel projections and are never
summed to form a management total.

ATV is derived from rolled additive primitives as `SUM(net value) /
SUM(net quantity)`. The fixture's row ATVs differ, so both `SUM(row ATV)` and
`AVG(row ATV)` fail the assertions.

## Residual risk

Dense same-event PostgreSQL advisory-lock waiters may occupy database
connections under extreme contention. M5-03F records this risk and does not
redesign the refresh fence.

## Validation record

```text
bash scripts/dev_local.sh status       PASS (DEV/TEST PostgreSQL and Redis reachable)
bash scripts/dev_local.sh doctor       PASS (loopback endpoints and ownership checks)
bash scripts/dev_local.sh test test/event_sales/analytics/m5_03_revenue_refund_dimension_reconciliation_test.exs
                                      PASS (1 test)
bash scripts/dev_local.sh test <focused M5-02/M5-03 evidence set>
                                      PASS (225 tests)
git diff --check                       PENDING final HEAD
bash scripts/dev_local.sh quality-pr  PASS (2731 tests, 0 failures)
exact-head GitHub CI                   PENDING PR final HEAD
```

No production, schema, migration, index, worker, scheduler, cache, Redis,
EventDetail, or UI change is included.
