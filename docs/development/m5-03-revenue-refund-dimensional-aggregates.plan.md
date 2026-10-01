# M5-03 revenue / refund dimensional aggregates implementation plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. This document is a planning and conformance artifact. It does not authorize production changes.

**Goal:** Expose gross, refund, net, and average ticket value for ticket type, source product, and source variation without changing the historical dimensional grain.

**Architecture:** Extend the existing EventDimensionAggregateSnapshot with the two additive refund primitives. DimensionAggregator will run three gross grouped queries and three separate refund grouped queries, then merge the results by the complete currency and identity key. SnapshotRefresh will replace the full dimensional set in the existing event fence and transaction. Net values and average ticket value remain reader-derived.

**Tech Stack:** Ash 3.x, AshPostgres, Ecto/PostgreSQL 18, Oban RefreshSnapshotWorker, Phoenix policy reads, and the existing EventSales financial-primitives modules.

---

## Planning status and authority

This is the M5-03A planning/conformance slice. It does not authorize
production code or migration changes. Publishing this document as a docs-only
review candidate does not authorize later implementation; the implementation
slices are authorized only after this plan is accepted.

The required base was checked after git fetch origin:

    BASE_SHA  = fdd3b4bfb96e31f8c099774f93f4091fe9e915c0
    BASE_TREE = a2ca9e581c47b5a39b7242964f6dc1b43fa73fb8
    WORKTREE  = the requested plan path was the only untracked path during
                preflight; no other changed path was found.

The plan follows these authorities, in order:

1. docs/path-1/m1-05-refund-and-financial-adjustment-contract.md
2. docs/path-1/m1-06-financial-metric-dictionary.md
3. docs/development/pre-m5-02-metrics-foundation.plan.md
4. docs/development/m5-02-ticket-product-variation-aggregates.plan.md
5. docs/evidence/m5-02-ticket-product-variation-aggregates-certification.md
6. The production modules and focused tests named in JC-301

This planning audit did not start Phoenix, mutate a database, or claim a local
refund EXPLAIN result. The query-plan certification in M5-03C is a release
gate. It must run against the isolated TEST database with the existing
selective fixture before any index decision is revisited.

## Terminal decision summary

    BASE_SHA = fdd3b4bfb96e31f8c099774f93f4091fe9e915c0
    BASE_TREE = a2ca9e581c47b5a39b7242964f6dc1b43fa73fb8

    RESOURCE_STRATEGY = EXTEND_EXISTING_NORMALIZED_RESOURCE
    RESOURCE_COUNT = 1

    PERSISTED_FIELDS =
      existing gross_ticket_quantity
      existing gross_ticket_value
      new refund_ticket_quantity
      new refund_ticket_value

    DERIVED_FIELDS =
      net_ticket_quantity
      net_ticket_value
      average_ticket_value

    DIMENSION_GRAINS =
      ticket_type: event_id + currency + ticket_type_id
      source_product: event_id + currency + source_system_id + woo_product_id
      source_variation: event_id + currency + source_system_id + woo_product_id + woo_variation_id

    REFUND_PREDICATE_AUTHORITY = EventSales.Analytics.Aggregators.EventAggregator
    REFUND_PREDICATE_REUSE_STRATEGY = expose EventAggregator.refund_primitives_filters/0

    REFUND_IDENTITY_SOURCE = exact bound parent OrderItem plus parent Order.source_system_id

    DIMENSION_AGGREGATOR_API = financial_rows_for_event/1
    GROSS_API_COMPATIBILITY = gross_rows_for_event/1 remains a three-query compatibility adapter

    GROSS_QUERY_COUNT = 3
    REFUND_QUERY_COUNT = 3
    TOTAL_QUERY_COUNT = 6

    SNAPSHOT_REFRESH_STRATEGY = existing per-event fence and one coherent full replacement
    REFUND_INVALIDATION_STRATEGY = existing RefundUpserter -> candidate resolver -> RefreshSnapshotWorker
    NEW_SCHEDULER = NO
    NEW_WORKER = NO

    READER_OUTPUT_FIELDS = gross/refund/net quantity, gross/refund/net value, average_ticket_value
    REVENUE_REDACTION = all four monetary fields become nil when can_view_revenue?/2 is false
    PII = NONE

    INDEX_DECISION = NONE
    MIGRATION_REQUIRED = YES, alter the existing dimensional table
    NEW_RESOURCE = NO
    CACHE_CHANGE = NONE
    EVENTDETAIL_CHANGE = NONE
    UI_CHANGE = NONE

    M5_03B = schema/resource extension
    M5_03C = six-query aggregator and query-plan certification
    M5_03D = coherent persistence and invalidation certification
    M5_03E = reader, derived metrics, redaction, and readiness
    M5_03F = management reconciliation and certification evidence

    IMPLEMENTATION_READY = YES
    HANDOFF_NOTE = docs-only review candidate; no production implementation
                   is included

## Outcome and backward plan

The management read model will expose, for every event and currency, parallel rows for:

| Family | Identity authority | Optional identity |
| --- | --- | --- |
| ticket_type | historical OrderItem.ticket_type_id | none |
| source_product | Order.source_system_id plus historical OrderItem.woo_product_id | none |
| source_variation | Order.source_system_id plus historical OrderItem.woo_product_id and woo_variation_id | variation rows require a non-null variation |

Each row carries gross and refund additive primitives. The reader derives net quantity, net value, and average ticket value from those primitives. A current ProductMapping, a display label, or a refund-line product ID cannot change a row's historical identity.

The dependency order is:

    Woo refund/order facts
      -> RefundUpserter and exact RefundLine binder
      -> EventAggregator refund eligibility
      -> six bounded DimensionAggregator GROUP BY queries
      -> one EventDimensionAggregateSnapshot replacement
      -> DimensionSnapshotReader derived fields and policy redaction
      -> M5-03F event/dimension reconciliation

M5-03 is event-scoped. It does not add lifetime or period buckets. Period-dimensional aggregates remain M5-04 work.

## Resource map and relationships

Durable source truth remains in the existing sales resources:

    Order
      source_system_id, currency, status, completed_at
      |
      +-- OrderItem
      |     order_id, event_id, ticket_type_id, mapping_status, item_kind,
      |     quantity, line_total, line_total_tax,
      |     historical woo_product_id, historical woo_variation_id,
      |     woo_line_item_id
      |
      +-- Refund
            order_id, source_state, detail_status, currency
            |
            +-- RefundLine
                  refund_id, order_item_id, woo_refunded_item_id,
                  refund totals, refunded quantity,
                  binding_reason, validation_reason

RefundLine.order_item_id is nullable in the source model. The dimensional query must use the exact persisted parent line and independently verify the Woo binder:

    RefundLine.order_item_id == parent OrderItem.id
    RefundLine.woo_refunded_item_id == parent OrderItem.woo_line_item_id
    parent OrderItem.order_id == Refund.order_id

The parent line supplies event_id, ticket_type_id, woo_product_id, woo_variation_id, mapping_status, and item_kind. The parent order supplies source_system_id and currency. RefundLine.woo_product_id and RefundLine.woo_variation_id remain source evidence used by the upserter's validation reason. They are never grouping authority. ProductMapping is not read by the refund query.

The durable projection remains the existing EventDimensionAggregateSnapshot. Its event/currency and three partial unique indexes remain unchanged. The three dimension kinds remain parallel projections, not additive families that may be summed together.

## Financial primitive ownership

EventSales.Sales.FinancialPrimitives remains the arithmetic authority.

    refund_ticket_quantity = positive refunded quantity magnitude only
    refund_ticket_value    = refund_total_amount + refund_total_tax

    net_ticket_quantity = gross_ticket_quantity - refund_ticket_quantity
    net_ticket_value    = gross_ticket_value - refund_ticket_value

    average_ticket_value = net_ticket_value / net_ticket_quantity
    net_ticket_quantity == 0 -> nil

All stored additive quantities and values are non-negative magnitudes. Net values are not clamped after canonical qualification. A line with a
`validation_reason` is not admitted to the primitives, so this no-clamp rule
does not override validation-failure exclusion. Qualifying refund primitives
may still exceed gross totals and produce negative net quantity or value. The
existing MetricRules.financial_summary/3 tests already prove this arithmetic
and the zero-denominator ATV rule.

M5-03E adds one pure `MetricRules.derive_financial_metrics/1` entry point and
refactors `financial_summary/3` to use it, so row readers do not copy
arithmetic. The helper delegates net subtraction to
`FinancialPrimitives.derive_net_totals/1`, keeps the existing zero-only ATV
guard, and validates the four stored additive primitives before deriving.
Quantity inputs must be non-negative integral Decimals. Value inputs must be
non-negative Decimals. Derived net values may be negative. Its contract is:

    derive_financial_metrics(%{
      gross_ticket_quantity: Decimal.t(),
      refund_ticket_quantity: Decimal.t(),
      gross_ticket_value: Decimal.t(),
      refund_ticket_value: Decimal.t()
    }) ::
      {:ok, %{
        net_ticket_quantity: Decimal.t(),
        net_ticket_value: Decimal.t(),
        average_ticket_value: Decimal.t() | nil
      }}

    | {:error, :invalid_primitive_totals}

It must call FinancialPrimitives.derive_net_totals/1 and use the same zero-only ATV guard as financial_summary/3. The reader converts integral quantity Decimals to signed integers after validation. It must not persist any derived field.

## Refund lifecycle, states, and guards

### State model

Refund source state is active or voided. voided is terminal in the current resource and upserter. A replay of the same source identity cannot reactivate it; reactivation is outside the current contract.

Refund detail status is reference_only, complete, or unresolved. Only active plus complete can contribute a qualifying refund line. A complete header with no exact ticket line can still invalidate affected events, but it cannot allocate dimensional ticket money.

Line qualification is separate from header status. A line is potentially qualifying only when all of the following hold:

    exact parent binder succeeds
    parent OrderItem.event_id == requested event
    parent OrderItem.mapping_status == mapped
    parent OrderItem.item_kind == ticket
    RefundLine.binding_reason IS NULL
    RefundLine.validation_reason IS NULL
    RefundLine.refund_total_amount IS NOT NULL
    RefundLine.refund_total_tax IS NOT NULL
    Refund.currency IS NOT DISTINCT FROM Order.currency

The query must not require refunded_quantity > 0. The quantity expression returns zero for nil or zero, while a valid positive amount and tax remain eligible.

An unallocated header amount (for example, `Refund.unallocated_header_amount > 0`) without an exact bound ticket line remains header-only. It can drive the existing bounded event invalidation, but it never enters a ticket-type, source-product, or source-variation refund sum. A refund may contain both qualifying bound lines and an unallocated residual; only the exact bound line primitives enter the dimensional sums, and the residual remains excluded.

### Canonical header predicate

EventAggregator.refund_primitives_filters/0 is currently private. M5-03C will expose it as an @doc false public helper with the existing [rl, r, o] dynamic binding:

    r.source_state == "active" and
    r.detail_status == "complete" and
    (o.status == "completed" or not is_nil(o.completed_at)) and
    is_nil(rl.binding_reason) and
    is_nil(rl.validation_reason) and
    not is_nil(rl.refund_total_amount) and
    not is_nil(rl.refund_total_tax) and
    fragment("? IS NOT DISTINCT FROM ?", r.currency, o.currency)

`Order.status == "refunded"` is not a refund financial predicate. A historically recognised order remains eligible for qualifying refund lines when the canonical active/complete refund and exact-line guards pass.

Both EventAggregator and DimensionAggregator will use this helper. Each query will retain its exact parent and event/ticket joins. The implementation must keep rl, r, and o as the first three Ecto bindings in the refund query so the dynamic expression cannot silently bind to a different table. A focused SQL-shape test will assert that event and dimensional refund queries retain the same eligibility terms.

### Required transition effects

| Transition | Durable qualification effect | Refresh effect |
| --- | --- | --- |
| reference_only or unresolved -> active/complete with exact lines | New qualifying line primitives may appear | Existing candidate Events enqueue after the line write |
| active/complete -> unresolved or source conflict | Prior qualifying primitives disappear | Before candidates enqueue before stale values can remain |
| active -> voided | All refund contribution becomes inactive | Before candidate Events enqueue; full replacement removes old values |
| Exact replay with unchanged durable truth | No semantic change | No coverage invalidation and no refresh enqueue |
| Previously unresolved binder -> exact parent OrderItem | Event attribution becomes available | Candidate event refreshes through existing resolver |
| Binding or validation failure | Line is stored as evidence but excluded from canonical primitives | Existing mutation path invalidates/enqueues the bounded candidate set |
| Header-only or unallocated refund with no exact ticket line | No dimensional ticket allocation | Existing bounded parent-event invalidation may enqueue refresh; it must not invent a row or residual allocation |
| Exact bound line with refunded_quantity == 0 and positive amount plus tax | Refund quantity increases by zero; refund value increases by the positive tax-inclusive amount | Event refresh produces unchanged net quantity and reduced net value |

RefundUpserter already locks the parent order, refund, refund lines, and parent order items; captures before/after truth; calls HistoricalRefundCoverageInvalidator; and invokes RefreshSnapshotWorker.enqueue_events/1 inside the same transaction. M5-03 must retain that order and transaction boundary. The invalidation detector is deliberately conservative. Its candidate evidence does not replace the financial query's exact two-part binder. M5-03D must prove that a mismatched `woo_refunded_item_id` cannot contribute money or quantity while the before/after candidate union still removes any prior projection. No new scheduler, queue, worker, GenServer, or Redis lock is justified.

## Grain matrix and row merge

| Kind | Gross GROUP BY | Refund GROUP BY | Variation rule |
| --- | --- | --- | --- |
| ticket_type | o.currency, oi.ticket_type_id | o.currency, parent.ticket_type_id | ticket_type_id is required by the existing grain validation |
| source_product | o.currency, o.source_system_id, oi.woo_product_id | o.currency, o.source_system_id, parent.woo_product_id | Includes both variation-bearing and product-only lines |
| source_variation | o.currency, o.source_system_id, oi.woo_product_id, oi.woo_variation_id | o.currency, o.source_system_id, parent.woo_product_id, parent.woo_variation_id | woo_variation_id IS NOT NULL; never synthesize a variation |

The merge key is the complete tuple:

    {currency, dimension_kind, ticket_type_id, source_system_id,
     woo_product_id, woo_variation_id}

The merge builds a map from the gross rows and refund rows, then fills missing components with zero. It sorts using the existing currency, family, and identity ordering. It must retain refund-only keys instead of iterating only over gross rows. Under the current source invariants a qualifying refund normally has a recognized parent gross line; a refund-only key is still an explicit integrity signal and must not be silently discarded.

The three families are parallel views. No management total may sum ticket-type, product, and variation rows together.

## Aggregator query model

DimensionAggregator.financial_rows_for_event/1 is the one canonical aggregate API. It runs six bounded grouped queries:

    3 gross queries
      ticket_type
      source_product
      source_variation

    3 refund queries
      ticket_type
      source_product
      source_variation

    total = 6, independent of row cardinality

The gross queries keep the current EventAggregator.recognised_sale_item_filters/1 and incomplete-line guard in their grouped result, so the financial call does not add a seventh validation query. The refund queries use the shared refund predicate and the exact parent-line join.

### Intended refund SQL shapes

The following is the required shape, not a request-time SQL string. Ecto may choose different aliases, but the joins, predicates, grouping, and expressions must remain equivalent.

#### Ticket type refund query

    FROM sales_refund_lines rl
    JOIN sales_refunds r
      ON r.id = rl.refund_id
    JOIN sales_orders o
      ON o.id = r.order_id
    JOIN sales_order_items parent
      ON parent.id = rl.order_item_id
     AND parent.order_id = o.id
     AND parent.woo_line_item_id = rl.woo_refunded_item_id
    WHERE parent.event_id = :event_id
      AND parent.mapping_status = 'mapped'
      AND parent.item_kind = 'ticket'
      AND canonical_refund_primitives_filters(rl, r, o)
    GROUP BY o.currency, parent.ticket_type_id
    SELECT
      o.currency,
      parent.ticket_type_id,
      SUM(CASE WHEN rl.refunded_quantity > 0 THEN rl.refunded_quantity ELSE 0 END),
      SUM(rl.refund_total_amount + rl.refund_total_tax)

#### Product refund query

    GROUP BY o.currency, o.source_system_id, parent.woo_product_id
    SELECT o.currency, o.source_system_id, parent.woo_product_id, ...

It uses the exact same four joins, parent event/ticket guards, canonical refund predicate, quantity CASE, and tax-inclusive value expression as the ticket query.

#### Variation refund query

    WHERE parent.woo_variation_id IS NOT NULL
    GROUP BY o.currency, o.source_system_id,
             parent.woo_product_id, parent.woo_variation_id
    SELECT o.currency, o.source_system_id,
           parent.woo_product_id, parent.woo_variation_id, ...

The variation query must not fall back to RefundLine.woo_variation_id, a product mapping, or a display label.

gross_rows_for_event/1 remains for existing tests or callers. It is a compatibility adapter over the shared three gross query builders and projects only gross fields, so the existing gross query-plan contract stays at three grouped queries. It is not a second financial semantics implementation: the gross builders, recognition predicate, identity validation, and row normalization are shared with financial_rows_for_event/1. SnapshotRefresh and all new refund-aware code use financial_rows_for_event/1.

## Persistence and refresh boundary

### Schema/resource change

M5-03B alters the existing analytics_event_dimension_aggregate_snapshots table and resource:

    refund_ticket_quantity integer NOT NULL DEFAULT 0 CHECK (>= 0)
    refund_ticket_value decimal NOT NULL DEFAULT 0 CHECK (>= 0)

The migration must add defaults and non-null constraints in the same safe form as the existing gross fields. Existing rows backfill to zero. No new Ash resource, table, identity, or dimension kind is allowed.

EventDimensionAggregateSnapshot.create_snapshot accepts the two new fields. update_snapshot accepts them for resource completeness, although SnapshotRefresh continues to use full replacement. Existing grain shape checks, partial unique indexes, ticket-type/event validation, and source-system/event validation stay unchanged.

### Full replacement

M5-03D changes only the dimensional input and insert map in SnapshotRefresh:

    EventSnapshotRefreshFence.with_serial_event_refresh/2
      -> one repeatable-read coherent transaction
      -> EventAggregator.financial_summaries_for_event/1
      -> DimensionAggregator.financial_rows_for_event/1
      -> existing source/grain validation
      -> event v2 upsert and obsolete currency purge
      -> delete all dimensional rows for event
      -> insert all financial dimensional rows
      -> commit
      -> existing DashboardCache.invalidate_event/2

The event snapshot's existing refreshed_at and every dimensional row use the same truncated projection_refreshed_at. A failed insert or event upsert rolls back both projections and preserves the prior generation. No code may patch only refund columns after the refund write.

### Refund invalidation reuse

The existing path remains the only invalidation path:

    RefundUpserter
      -> HistoricalRefundMutationDetector.capture/compare
      -> HistoricalRefundCoverageInvalidator.invalidate_refund_change/3
      -> RefreshSnapshotWorker.enqueue_events/1
      -> SnapshotRefresh.refresh_event/2

The detector's candidate set is the sorted union of before and after affected Events. Exact bound lines use historical parent event IDs. Unresolved, invalid, order-level, or ambiguous detail falls back to the bounded parent order's Event set. This is sufficient for new exact refunds, multi-event lines, binder resolution, malformed/conflict transitions, voids, and header-only invalidation. M5-03 must add tests around the dimensional result, not add another invalidator.

## Reader contract, redaction, and readiness

### Output fields

Every row returned by DimensionSnapshotReader keeps the current identity, catalogue display, and refreshed_at fields, then adds:

    gross_ticket_quantity  integer
    refund_ticket_quantity integer
    net_ticket_quantity    integer

    gross_ticket_value     Decimal or nil
    refund_ticket_value    Decimal or nil
    net_ticket_value       Decimal or nil
    average_ticket_value   Decimal or nil

For financial and dimensional source truth, the reader reads only EventAggregateSnapshot and EventDimensionAggregateSnapshot. It does not query Order, OrderItem, Refund, RefundLine, or ProductMapping. It may retain the existing bounded Event/TicketType/SourceSystem catalogue lookups, coherent transaction, authorization-first ordering, and stable family ordering.

### Revenue policy

Policies.can_view_revenue?/2 controls all monetary fields. When false, the reader returns nil for:

    gross_ticket_value
    refund_ticket_value
    net_ticket_value
    average_ticket_value

Quantities and identity/catalogue fields remain visible under the existing dashboard policy. There is no alternate raw money field and no PII in this reader result. The existing revenue_visible? flag is not a substitute for redacting the fields.

### Readiness authority boundary

The reader's projection check is separate from source completeness. It protects
against an event snapshot with financial primitives but missing or stale
dimensional families. It does not replace `AnalyticsReadinessResolver`.
`EventDetail` and other management facades must continue to gate exposure on
the existing resolver, including historical refund coverage and financial
reconciliation evidence. `SnapshotRefresh` and `RefreshSnapshotWorker` must
continue to refresh durable projections even when that external readiness gate
is blocked. M5-03 does not change the existing `sold` or `revenue` compatibility
keys in `EventDetail`.

### Fail-closed readiness algorithm

Readiness is a management-read concern. SnapshotRefresh and RefreshSnapshotWorker must continue refreshing while the read is not ready.

Within the existing reader transaction:

1. Read canonical v2 rows for the event. If none exist, return :miss.
2. Read all dimensional rows before applying the optional dimension_kind output filter.
3. Reject any dimensional currency that is absent from the v2 currency set.
4. Group dimensional rows by currency.
5. For each v2 currency, mark financial_primitives_present? true when any of these is non-zero:
   - gross_ticket_quantity
   - gross_ticket_value
   - refund_ticket_quantity
   - refund_ticket_value
6. If financial_primitives_present? is true, require both :ticket_type and :source_product families for that currency. Variation is optional because product-only parent lines are valid.
7. Require every dimensional row for the currency to have the same microsecond-truncated refreshed_at as the v2 row.
8. If all currencies pass, apply the requested family filter and derive row metrics.

This catches a value-only refund with zero refund quantity and positive refund value. It also catches a refund-only generation where gross quantity remains zero. A currency with all four additive primitives equal to zero may return empty families, as in the existing zero-gross behavior. Any malformed primitive type or invalid negative stored additive primitive returns {:error, :snapshot_not_ready} rather than a partial result.

## Reconciliation lemmas and ATV rules

M5-03F certifies each Event and currency independently.

### Refund quantity and value

    event.refund_ticket_quantity
      == sum(ticket_type.refund_ticket_quantity)
      == sum(source_product.refund_ticket_quantity)

    event.refund_ticket_value
      == sum(ticket_type.refund_ticket_value)
      == sum(source_product.refund_ticket_value)

Missing rows on either side contribute zero. The checks use only the matching currency and family. No cross-currency total is formed.

### Net parity

For each family, derive net from that family's gross and refund sums. Then compare it to the event derivation:

    event.net_ticket_quantity == sum(family.gross_ticket_quantity)
                               - sum(family.refund_ticket_quantity)
    event.net_ticket_value    == sum(family.gross_ticket_value)
                               - sum(family.refund_ticket_value)

The certification must use FinancialPrimitives rather than a second subtraction helper. Negative results remain valid evidence of an over-refund.

### Variation subset

Variation refund totals equal only the qualifying refund lines whose exact historical parent OrderItem.woo_variation_id is non-null. Product-only lines contribute to ticket type and source product but never create a synthetic variation row. Full variation parity is not required when product-only lines exist.

### ATV is non-additive

No family aggregation may sum or average row average_ticket_value. A rolled-up ATV is always:

    sum(net_ticket_value) / sum(net_ticket_quantity)

with a zero denominator returning nil. The reader may expose per-row ATV, but no snapshot column stores it.

## Index and query-plan analysis

The existing indexes are sufficient candidates for the six bounded queries:

| Table | Existing index | Expected use |
| --- | --- | --- |
| sales_order_items | sales_order_items_event_id_idx | Event-scoped parent/gross access |
| sales_order_items | sales_order_items_event_mapping_status_idx | Event plus mapped ticket filter |
| sales_order_items | sales_order_items_order_id_idx | Exact parent-order join |
| sales_order_items | sales_order_items_ticket_type_id_idx | Ticket grouping support |
| sales_order_items | sales_order_items_woo_product_variation_idx | Product/variation grouping support |
| sales_refund_lines | sales_refund_lines_order_item_id_idx | Exact bound parent line lookup |
| sales_refund_lines | unique (refund_id, woo_refund_line_item_id) | Refund-line-to-header join support |
| sales_refunds | sales_refunds_order_id_idx | Refund-to-order join |
| sales_refunds | source/order/refund unique index | Source identity lookup and fallback join |

    INDEX_DECISION = NONE

M5-03A adds no speculative index. M5-03C must extend dimension_aggregator_query_plan_test.exs or add a focused companion test that:

1. Seeds the existing selective event plus at least 800 unrelated order lines and refund lines.
2. Captures exactly six aggregate SELECT statements from financial_rows_for_event/1.
3. Classifies the three gross and three refund GROUP BYs.
4. Runs EXPLAIN (FORMAT JSON) for every statement against the isolated TEST database.
5. Requires an event-scoped indexed access path for sales_order_items and rejects a sequential scan on sales_order_items, sales_refund_lines, sales_refunds, or sales_orders for the selective fixture.
6. Allows any of the existing refund-line/refund-header indexes when PostgreSQL chooses among equivalent paths.

The empty DEV database cannot prove a selective plan, so a failed representative EXPLAIN in M5-03C is a stop condition. Only a measured failing plan may justify a new index.

## Performance and scaling review

| Path | Layer | Query/materialization budget | Cache and invalidation |
| --- | --- | --- | --- |
| Refund/order facts | Cold durable truth | Source writes only; no request-time dashboard scan | Existing source mutation and coverage invalidation |
| Event refresh | Warm asynchronous work | Six grouped dimension queries plus existing event queries; count is constant | Existing Oban worker, event fence, and transaction |
| Dimensional projection | Cold derived Postgres model | Full replacement by event; BEAM holds only grouped rows and bounded merge maps | Existing dashboard cache invalidation after commit |
| Management reader | Cold snapshot read | One v2 query, one dimension query, and one bounded batch query per catalogue type; no N+1 | No new cache and no raw history scan |

The event fence serializes same-event refreshes and prevents mixed generations. The 120-second transaction timeout remains the existing bound. Six grouped queries occupy a database connection during refresh, but they do not scale with dimension cardinality and do not materialize raw order/refund histories. A reader transaction performs event existence, canonical snapshot, dimensional snapshot, and at most one batched TicketType plus one batched SourceSystem catalogue read. A query-plan regression or connection occupancy problem must be measured in M5-03C/D before changing the design.

Redis and Cachex remain unused for M5-03. No new cache key, invalidation rule, period bucket, or hot aggregator is required.

## Failure modes and controls

| Failure mode | Required control |
| --- | --- |
| Gross/refund join multiplication | Separate three gross and three refund GROUP BY queries |
| Refund attributed from RefundLine product IDs | Group only from the exact historical parent OrderItem; keep RefundLine IDs as validation evidence |
| ProductMapping reattributes history | Do not join ProductMapping in aggregation or reader |
| Header-only refund receives an invented allocation | No dimensional ticket allocation; retain bounded invalidation only |
| Value-only bound line is dropped | Do not filter on positive quantity; sum value independently |
| Voided refund remains in a row | active predicate plus full replacement |
| Unresolved detail is counted | detail_status == complete predicate |
| Binding or validation conflict is counted | binding_reason IS NULL and validation_reason IS NULL |
| Currency mismatch is counted | IS NOT DISTINCT FROM refund/order currency predicate |
| Variation row is synthesized | Variation query requires parent variation non-null |
| Net is clamped at zero | Use Decimal.sub/2 without a clamp |
| ATV is persisted or averaged | Keep ATV derived and compute rolled-up ATV from net sums |
| Value-only refund passes stale readiness | Readiness checks all four additive event primitives |
| Hidden reader leaks refund/net money | Redact gross, refund, net, and ATV values together |
| Refund mutation misses an affected Event | Reuse before/after candidate union and existing enqueue path; certify mismatched two-part binders remove prior rows |
| Full replacement leaves stale refund values | Delete all event dimensions before inserting the new set in one transaction |
| Query count scales with dimension cardinality | Fixed six grouped queries and a bounded map merge |
| New index is added without evidence | INDEX_DECISION = NONE; require selective EXPLAIN first |
| Period/lifetime machinery enters M5-03 | Keep M5-03 event scope and defer periods to M5-04 |

## Implementation slices B-F

Each slice is independently reviewable and mergeable. Each worker must run the focused tests for that slice, mix compile --warnings-as-errors, mix format, and mix quality.fast at the slice boundary. No slice may change EventDetail's existing sold/revenue gross compatibility keys.

### M5-03B: schema and resource

Files:

- Modify lib/event_sales/analytics/resources/event_dimension_aggregate_snapshot.ex.
- Create one AshPostgres migration under priv/repo/migrations/ that alters the existing dimensional table.
- Extend test/event_sales/analytics/event_dimension_aggregate_snapshot_test.exs and focused migration/resource coverage if needed.

Acceptance:

- Add the two non-null zero-default additive refund fields and non-negative database constraints.
- Keep all three grain identities and shape checks unchanged.
- Add the fields to create/update accepts and resource attributes.
- Prove old gross-only rows read as zero refund primitives.
- Prove negative additive values are rejected by the resource/database.
- Do not add net or ATV columns and do not create a second resource.

### M5-03C: aggregator and query-plan certification

Files:

- Modify lib/event_sales/analytics/aggregators/event_aggregator.ex only to expose the shared refund predicate.
- Modify lib/event_sales/analytics/aggregators/dimension_aggregator.ex.
- Extend test/event_sales/analytics/dimension_aggregator_test.exs.
- Extend test/event_sales/analytics/dimension_aggregator_query_plan_test.exs or add its focused refund companion.
- Extend test/event_sales/analytics/event_aggregator_test.exs for predicate parity and value-only semantics.

Acceptance:

- Add financial_rows_for_event/1 as the canonical API.
- Keep gross_rows_for_event/1 as a thin compatibility adapter over shared gross builders, preserving its three-query behavior; it is not a second financial semantic path.
- Run exactly six aggregate queries per financial call.
- Merge gross-only, refund-only, and matching rows by the full currency/family/identity key.
- Preserve source-system and historical parent IDs.
- Include positive value when refunded quantity is zero.
- Exclude unbound, unresolved, invalid, mismatched-currency, non-ticket, unmapped, and synthetic variation cases.
- Certify selective EXPLAIN plans in TEST and add no index without measured failure.

### M5-03D: persistence, rollback, concurrency, and invalidation

Files:

- Modify lib/event_sales/analytics/snapshot_refresh.ex to consume financial dimensional rows and persist both additive refund fields.
- Do not add a worker or scheduler.
- Extend test/event_sales/analytics/event_dimension_snapshot_refresh_test.exs.
- Extend test/event_sales/analytics/event_snapshot_refresh_rollback_test.exs.
- Extend test/event_sales/analytics/event_snapshot_refresh_concurrency_test.exs.
- Extend test/event_sales/sales/refund_upserter_historical_coverage_test.exs and test/event_sales/sales/refund_upserter_test.exs only where a dimensional result or missing seam needs proof.

Acceptance:

- Event and dimensional snapshots share one generation timestamp.
- A second refresh removes obsolete currencies, grains, and refund contributions.
- A voided or unresolved transition removes the prior refund values after refresh.
- A failed refresh rolls back event and dimension writes together.
- Same-event refreshes remain serialized by the existing fence.
- Exact replay does not enqueue a refresh.
- Binder resolution, multi-event lines, malformed/conflict detail, header-only invalidation, and active-to-voided transitions use the existing candidate resolver and worker.

### M5-03E: reader, metrics, readiness, and policy

Files:

- Modify lib/event_sales/analytics/dimension_snapshot_reader.ex.
- Modify lib/event_sales/analytics/metric_rules.ex for `derive_financial_metrics/1` and its shared implementation with `financial_summary/3`.
- Extend test/event_sales/analytics/dimension_snapshot_reader_test.exs.
- Extend test/event_sales/analytics/dimension_snapshot_reader_policy_test.exs.
- Extend test/event_sales/analytics/metric_rules_test.exs.

Acceptance:

- Return all seven requested per-row metrics and keep identity/display fields.
- Derive net and ATV through the canonical arithmetic helper.
- Redact all four money fields when revenue is hidden while retaining quantities.
- Require ticket-type and source-product families whenever any event additive primitive is non-zero, including refund value with refund quantity zero.
- Keep variation optional and preserve same-generation checks.
- Keep the existing `AnalyticsReadinessResolver` management gate and refund-completeness semantics separate from projection coherence; do not make refresh depend on readiness.
- Keep authorization before event/projection access and keep reader query counts independent of row cardinality.

### M5-03F: management conformance and evidence

Files:

- Add a focused reconciliation test, preferably test/event_sales/analytics/m5_03_revenue_refund_dimension_reconciliation_test.exs, rather than changing the M5-02 evidence contract.
- Add docs/evidence/m5-03-revenue-refund-dimensional-aggregates-certification.md after implementation and certification.
- Do not redesign EventDetail or UI in this slice.

Acceptance:

- Reconcile event and ticket-type/product refund quantity and value by currency.
- Reconcile derived net quantity and value without clamping.
- Prove variation equality only for the exact variation-bearing subset.
- Prove product-only lines do not create variation rows.
- Prove value-only bound refunds reduce net value without changing net quantity.
- Prove header-only/unallocated refunds do not enter dimensional ticket value.
- Prove a later ProductMapping create, deactivate, or retarget does not change refund dimensional identity.
- Prove family projections are not summed together and ATV is never summed or averaged.
- Record the focused test, query-plan, policy, rollback, concurrency, and invalidation evidence.

## Explicit scope exclusions

M5-03 does not include:

- M5-04 period or lifetime bucket machinery.
- Recognised-order count at dimensional grain.
- Status model or operational status redesign.
- Coupon, discount, fee, shipping, or non-ticket dimensions.
- A new Product resource or ProductMapping-based history.
- Proportional, residual, equal, or largest-line header refund allocation.
- EventDetail changes to sold and revenue, which remain gross compatibility fields.
- UI redesign, browser polling, Redis, Cachex, or a new cache layer.
- A new refund scheduler, queue, worker, or lock.

## Stop conditions

Implementation must stop and return IMPLEMENTATION_READY = NO if any of these becomes true:

1. The EventAggregator refund predicate cannot be shared without semantic drift.
2. The exact parent OrderItem cannot deterministically supply event, ticket type, product, variation, and source identity.
3. The existing normalized dimensional resource cannot hold two non-null additive refund primitives with the current grain checks.
4. Header-only refunds require an invented allocation rule to satisfy a management total.
5. The implementation requires period machinery or M5-04 lifetime semantics.
6. Gross/refund joins multiply line cardinality or require a query per dimension row.
7. Query count becomes dependent on dimension cardinality.
8. A new scheduler, worker, cache, or Redis lock is required for correctness.
9. Net or ATV must be persisted to avoid incorrect results.
10. RefundUpserter cannot identify every affected Event through its existing before/after candidate path.
11. A selective TEST EXPLAIN demonstrates that an existing index set cannot support the intended query shape and no measured replacement has been reviewed.
12. A reader or test path would expose money when Policies.can_view_revenue?/2 is false.

## Required planner output

    BASE_SHA = fdd3b4bfb96e31f8c099774f93f4091fe9e915c0
    BASE_TREE = a2ca9e581c47b5a39b7242964f6dc1b43fa73fb8

    RESOURCE_STRATEGY = EXTEND_EXISTING_NORMALIZED_RESOURCE
    RESOURCE_COUNT = 1
    PERSISTED_FIELDS = gross_ticket_quantity, gross_ticket_value,
                        refund_ticket_quantity, refund_ticket_value
    DERIVED_FIELDS = net_ticket_quantity, net_ticket_value, average_ticket_value
    DIMENSION_GRAINS = ticket_type, source_product, source_variation with existing keys
    REFUND_PREDICATE_AUTHORITY = EventAggregator.refund_primitives_filters/0
    REFUND_PREDICATE_REUSE_STRATEGY = one shared dynamic helper, exact joins retained
    REFUND_IDENTITY_SOURCE = exact parent OrderItem and parent Order.source_system_id
    REFUND_LIFECYCLE = active/voided plus reference_only/complete/unresolved
    QUALIFICATION_GUARDS = exact binder, historical order, mapped ticket, valid line,
                            amount/tax present, currency match
    TRANSITION_SIDE_EFFECTS = existing invalidation and RefreshSnapshotWorker enqueue
    TERMINAL_STATES = voided; exact replay is a no-op
    HEADER_ONLY_POLICY = invalidate bounded parent Events when required, allocate no ticket row
    VALUE_ONLY_LINE_POLICY = quantity zero, positive tax-inclusive value, included
    VOIDED_REFUND_POLICY = excluded by active predicate and removed by full replacement
    UNRESOLVED_REFUND_POLICY = excluded until complete and exact
    VALIDATION_FAILURE_POLICY = persist evidence, exclude from primitives, refresh affected Events
    DIMENSION_AGGREGATOR_API = financial_rows_for_event/1
    GROSS_API_COMPATIBILITY = gross_rows_for_event/1 uses shared gross builders and projects gross fields
    GROSS_QUERY_COUNT = 3
    REFUND_QUERY_COUNT = 3
    TOTAL_QUERY_COUNT = 6
    REFUND_TICKET_QUERY = exact parent binder, event/mapped/ticket guards,
                          GROUP BY currency + parent.ticket_type_id
    REFUND_PRODUCT_QUERY = exact parent binder, GROUP BY currency + source_system + parent product
    REFUND_VARIATION_QUERY = product query plus non-null parent variation in GROUP BY
    GROSS_REFUND_MERGE_STRATEGY = deterministic full-key map; absent side contributes zero
    SNAPSHOT_REFRESH_STRATEGY = fenced coherent transaction and full dimension replacement
    REFUND_INVALIDATION_STRATEGY = existing RefundUpserter candidate union and worker
    NEW_SCHEDULER = NO
    NEW_WORKER = NO
    READER_OUTPUT_FIELDS = gross/refund/net quantity, gross/refund/net value, ATV
    REVENUE_REDACTION = nil for gross/refund/net value and ATV when hidden
    PII = NONE
    READINESS_ALGORITHM = additive event primitive trigger, ticket/product family presence,
                           currency subset, generation equality; variation optional
    EVENT_REFUND_RECONCILIATION = ticket/product sums equal event by currency
    EVENT_NET_RECONCILIATION = derive both sides with FinancialPrimitives, no clamp
    VARIATION_SUBSET = exact parent lines with non-null historical variation only
    ATV_AGGREGATION_RULE = sum net value / sum net quantity; zero denominator nil
    EVENTDETAIL_CHANGE = NONE; sold/revenue remain gross
    UI_CHANGE = NONE
    INDEX_DECISION = NONE
    INDEX_EVIDENCE = existing event/order/refund indexes; M5-03C selective EXPLAIN gate
    MIGRATION_REQUIRED = YES, alter existing dimension table
    NEW_RESOURCE = NO
    CACHE_CHANGE = NONE
    PERFORMANCE_SCALING_REVIEW = six grouped queries, full replace, bounded reader, no N+1
    M5_03B = schema/resource
    M5_03C = aggregator/query plans
    M5_03D = persistence/invalidation
    M5_03E = reader/readiness/policy
    M5_03F = reconciliation/certification
    RISKS = query plan regression, stale generations, binder/source conflicts,
            hidden money, value-only readiness gaps
    STOP_CONDITIONS = the twelve conditions above
    EXPECTED_PLAN_FILE = docs/development/m5-03-revenue-refund-dimensional-aggregates.plan.md
    IMPLEMENTATION_READY = YES
