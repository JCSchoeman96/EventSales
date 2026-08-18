# M3-05C2 Historical Refund Integration Design

## Goal

Wire the already-proven `EventSales.Ingestion.OrderRefundSync` into both
immutable historical execution paths so an M or U member is not considered
successful, and its page is not checkpointed, until its refund synchronization
has completed.

## Boundaries

`HistoricalManifestExecution` keeps the frozen M membership authority and
existing Order count semantics. It fetches each exact parent Order, writes a
matching current Event subset when one exists, and then invokes
`OrderRefundSync.sync_order/3` for every valid member, including empty subsets
and `:stale_noop` Order writes.

`HistoricalCatchupExecution` keeps F4C1 as the sole U Order reconciliation path.
It exact-fetches each U member, selects the current Event subset (including an
empty subset), completes F4C1, and then invokes `OrderRefundSync.sync_order/3`.

`OrderRefundSync` remains the sole Refund/RefundLine orchestration boundary and
`RefundUpserter` remains the sole durable Refund writer. No source HTTP is
added inside the existing Order/F4C1 or checkpoint transactions.

## Source and dependency flow

Each executor already validates and holds the exact active WooCommerce
`SourceSystem` before processing a page. The executor passes that struct to C1
through a loader that returns it only for the run's exact `source_system_id`,
and passes the same injected WooCommerce client and client options used for the
parent Order. Required source/client options override optional test sync
options, so the refund sync cannot silently use a different source namespace.

Per member, source work is therefore one existing exact Order GET plus C1's
bounded parent-scoped refund list and only its exact deletion-candidate GETs.

## Failure and checkpoint behavior

The Order/F4C1 result is persisted first. A refund-sync error is returned
unchanged from the executor before `before_checkpoint/1` and before any cursor
or run-count checkpoint transaction. Durable Order or prior Refund facts may
remain; replay relies on their existing idempotent writers.

The existing `BackfillOrdersWorker` remains the only Oban shell. Its transient
reasons stay unchanged. C1 refund-integrity atoms and reachable permanent
WooCommerce client atoms are added to the existing permanent/failure-summary
sets, so known refund failures fail closed with atom-only summaries and
transient refund transport failures pause and snooze.

## Verification scope

Focused tests prove M and U call/refusal ordering, empty subsets, stale no-ops,
partial-page failure, checkpoint blocking, terminal U blocking, replay, and
source/client option reuse. Worker tests prove transient refund retry and
permanent refund fail-closed behavior. No migration, resource change, cursor,
watermark, new worker, webhook integration, completeness certification, or
cache/state system is introduced.
