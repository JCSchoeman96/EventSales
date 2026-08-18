# M3-05C1 Order Refund Sync Design

## Goal

Add one source-safe `EventSales.Ingestion.OrderRefundSync` boundary that
converges the current WooCommerce refund membership and full refund objects
with durable `Refund` facts, including confirmed source deletion without
hard-deleting audit history.

## Boundaries

`OrderRefundSync.sync_order/3` owns only parent-scoped refund membership
synchronization. It does not wire into historical execution, webhook
processing, workers, completeness watermarks, analytics, Redis, or PubSub.

`EventSales.Sales.RefundUpserter` remains the sole durable writer for
`Refund` and `RefundLine`. The sync orchestrator may read active candidates,
but it never writes those resources directly.

## Data flow

1. Load the exact `SourceSystem` by internal UUID and require an active
   WooCommerce source with a valid normalized base URL.
2. Compare that URL with the configured WooCommerce client URL before any
   source request. A failed validation performs no HTTP.
3. Call one bounded `list_refunds/3` request for the explicit parent order.
   Validate that the response is a list of maps with unique positive refund
   IDs.
4. Sequentially send every returned full object to
   `RefundUpserter.upsert_refund/4`. A returned voided identity fails closed;
   a write failure stops the sync before deletion discovery.
5. Read local active refunds scoped to the same source and parent order.
   Only IDs absent from the current list become deletion candidates.
6. For each candidate, call exact `fetch_refund/3` outside any database
   transaction. `:not_found` is the only deletion confirmation and invokes
   `RefundUpserter.mark_source_deleted/5`; an exact object is replayed through
   the upserter; transient or other errors leave the local refund active and
   return a retryable/fail-closed reason.

## Void writer

`RefundUpserter.mark_source_deleted/5` validates the full source/order/refund
identity, opens a short Postgres transaction, locks the exact refund row, and
uses the existing `Refund :mark_voided` action for active rows. Already-voided
rows are returned unchanged, preserving their original `voided_at`. Missing
rows return a stable error. The operation always uses `void_reason:
"source_deleted"` and never deletes or reactivates a row.

## Error handling and injection

WooCommerce transient reasons remain normalized to the repository vocabulary:
`:rate_limited`, `:timeout`, `:server_error`, `:queue_timeout`,
`:circuit_open`, and `:transport_error`. Malformed membership, duplicate IDs,
source validation failures, reappearing voided IDs, upsert failures, and void
failures use stable refund-sync reasons. Tests inject only the source loader,
WooCommerce client/client options, upserter, and observation time needed to
prove the boundary without real source access.

## Verification

Focused tests cover source safety, list validation and replay, full-object
persistence without listed-refund N+1 fetches, exact deletion confirmation,
stale-list protection, transient/permanent confirmation failures, partial
failure ordering, and reappearing voided identities. Existing and new
`RefundUpserter` tests cover exact void scope, idempotent void replay,
preserved timestamps/lines/financial facts, and cross-source isolation.

No migration or Ash resource change is expected.
