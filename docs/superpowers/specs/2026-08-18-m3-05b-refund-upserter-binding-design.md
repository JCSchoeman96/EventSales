# M3-05B Refund Persistence and Binding Design

## Goal

Make `EventSales.Sales.RefundUpserter` the sole durable writer for WooCommerce
refund references and normalized refund detail. Repeated delivery, out-of-order
parent/line availability, and concurrent partial refunds must converge to one
source-scoped `Refund`/`RefundLine` truth without rewriting the original sale.

## Scope and boundaries

The public boundaries are:

- `upsert_reference/4` persists discovery evidence for one
  `(source_system_id, woo_order_id, woo_refund_id)` identity.
- `upsert_refund/4` parses one exact raw WooCommerce refund before entering the
  database transaction.
- `upsert_normalized_refund/4` persists already-normalized detail.

The module does not fetch WooCommerce, enqueue Oban work, reconcile source
membership, detect voids, update `Order` or `OrderItem` facts, publish events,
or calculate analytics. `OrderUpserter` remains the only writer for Order and
OrderItem source truth.

## Persistence model

Reference writes create or hydrate one active `Refund` with
`detail_status: :reference_only`. They never downgrade complete detail,
reactivate a voided refund, replace known financial facts, or create a second
row. A known parent Order is found by the source-scoped Order identity and
provides both `order_id` and `currency`; otherwise the refund remains durable
with both nullable and `unresolved_reason: "parent_order_not_found"`.

Valid normalized detail normally sets `detail_status: :complete`, independently
of parent or line binding. A parser error with a valid positive refund ID
creates or locates the source identity, marks it `:unresolved` with a stable
sanitized reason, and writes no partial lines. An invalid or missing refund ID
returns an error and writes nothing.

Refund lines are identified only by `(refund_id, woo_refund_line_item_id)`.
Their only binder is the parser's positive `_refunded_item_id`, resolved against
an OrderItem belonging to the exact bound parent Order. Missing, malformed, or
unknown binders remain nullable and retain a stable `binding_reason`; product
and variation values are validation evidence and never change the binder.
Value-only refunds persist their header facts with no invented lines or ticket
allocation.

## Transaction and locking

Parsing and input validation occur before `EventSales.Repo.transaction/1`.
Inside the transaction the writer:

1. locks the source-scoped parent Order, when present;
2. locates and locks the existing source-scoped Refund, when present;
3. establishes one Refund row, using the unique identity as the final authority;
4. resolves all valid incoming line binders with one parent-scoped query;
5. locks affected OrderItems in ascending `woo_line_item_id` order;
6. reads active prior RefundLines while excluding the current Refund;
7. validates cumulative ticket quantity and creates or updates RefundLines;
8. updates local binding/detail evidence and commits.

`Ash.Query.lock(query, :for_update)` is used for row locks. No HTTP or
unbounded retry occurs while locks are held. If a concurrent no-parent create
loses the unique identity race, the writer performs at most one refetch and
convergence attempt.

## Replay and conflict rules

For each durable source fact, equal known values are accepted, nil-to-known
values hydrate, and known-to-nil or known-to-different values are conflicts.
Once a line identity set is established, a materially different incoming set
is also a conflict. A conflict preserves existing financial facts and lines,
marks the Refund `detail_status: :unresolved`, records
`"source_detail_conflict"`, and returns the durable refund as success evidence.
Voided refunds are never silently reactivated.

## Quantity safety

For each bound ticket OrderItem, the transaction locks the item and compares
the sum of active bound RefundLine quantities from other refunds plus all
incoming quantities for the current refund against the original `quantity`.
Voided refunds are excluded. Replay excludes the current refund's existing
lines so it cannot double-count. An overage preserves the full source quantity,
keeps the exact binding, leaves the OrderItem untouched, and adds the stable
validation token `refunded_quantity_exceeds_original` alongside any product or
variation mismatch tokens in deterministic order.

## Error and test contract

Durably stored review evidence returns `{:ok, %Refund{}}`. Errors are limited to
invalid identity, database/transaction failure, and impossible internal
invariants. Focused tests cover references, parent and exact line binding,
validation evidence, value-only detail, monotonic replay/conflicts, voided
replay, cumulative quantity safety, concurrent duplicate/distinct writes, and
transaction rollback. No migration or resource schema change is expected.
