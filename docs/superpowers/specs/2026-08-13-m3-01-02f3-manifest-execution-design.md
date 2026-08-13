# M3-01/02F3 Manifest-Driven Historical Execution Design

## Goal

Replace mutable WooCommerce historical collection traversal with one immutable
manifest page per execution step. Every manifest identity is resolved by an
exact WooCommerce order fetch, event-relevant payloads are persisted only by
`OrderUpserter`, and durable progress advances only after the complete page
has succeeded.

## Scope and boundaries

This slice consumes the manifest produced and durably evidenced by F2. It does
not create a second run or manifest resource, store per-order progress, use
WooCommerce collection paging for historical membership, implement catch-up H,
or mark a historical run or cursor complete. At manifest terminal, the run
remains nonterminal and the cursor remains active for F4.

Normal reconciliation continues to own `OrderReconciliation` collection
paging. Historical membership traversal is isolated in
`EventSales.Ingestion.HistoricalManifestExecution`.

## Durable state model

`HistoricalManifestEvidence` remains under the single `historical_manifest`
metadata namespace. It will validate exact nested key sets for:

- `create_claimed`: the existing F2 claim only; execution fails closed with
  `manifest_create_in_doubt`.
- `pending_first_page`: the existing F2 identity fields and no page cursor.
- `manifest_in_progress`: the F2 identity fields plus exactly `next_cursor`.
- `manifest_terminal`: the F2 identity fields plus exactly
  `terminal_evidence`.

`next_cursor` and `terminal_evidence` are mutually exclusive. Item arrays,
source IDs, full Woo payloads, customer/payment data, credentials, and
signatures are never persisted. Every resulting metadata map is checked against
the existing 2048-byte bound.

`SyncCursor.record_manifest_progress` accepts only `page` and `metadata`.
Execution keeps `modified_after = run.date_from`, `modified_before =
run.date_to`, `last_seen_order_id = nil`, and `status = active` throughout the
manifest phase. `page` starts at 1 and increments once for every successful
page checkpoint, including the terminal page; terminal evidence, not page,
is terminal authority.

## Execution flow

`run_step(sync_run, sync_cursor, opts)` performs one bounded step:

1. Validate the historical run, active cursor, exact SourceSystem identity,
   WooCommerce kind, and both configured client base URLs.
2. Parse and validate the persisted manifest evidence and injectable UTC clock.
   Terminal evidence returns immediately; a create claim fails closed.
3. Verify expiry before the manifest GET.
4. Call only `WooOrderIndexClient.fetch_manifest_page/3`, passing `nil` for
   `pending_first_page` or the exact persisted opaque cursor for
   `manifest_in_progress`.
5. Verify every continuity field against the persisted F2 evidence and verify
   expiry again before processing items.
6. For each page item, call `WooCommerceClient.fetch_order/2` with that exact
   source order ID, validate the returned map and exact positive ID, and avoid
   all current-date membership filtering.
7. Filter line items using active mappings scoped to the exact source system
   and event, matching Woo product ID and variation ID only. A nonmatching
   order is fully resolved without a Sales write.
8. For matching orders, call `OrderUpserter.upsert_order/2` and classify
   accepted, stale, or failed outcomes. Any failed identity or write fails the
   page before checkpointing.
9. Checkpoint counts, page, and the next state in one short Postgres
   transaction. The transaction locks and re-reads the cursor, verifies the
   exact state/cursor just processed, re-reads the run, applies counts from its
   current durable values, and updates the cursor with the page-only Ash
   action. No source HTTP or order write runs under this transaction.

Nonterminal source responses require a valid `next_cursor`, even for short or
empty pages, and persist `manifest_in_progress`. Terminal responses require
`terminal_evidence`, remove `next_cursor`, persist `manifest_terminal`, and
leave the run/cursor nonterminal/active.

## Worker and queue behavior

`BackfillOrdersWorker` will use Oban queue `historical_backfill`, max attempts
25, unique active jobs by `sync_run_id`, and queue concurrency 1. It starts or
resumes the run, calls F2 bootstrap when needed, executes at most one manifest
page, and snoozes briefly only after a successful checkpoint. A terminal
manifest returns `:ok` without scheduling another page and without calling
`SyncRun.complete` or `SyncCursor.mark_done`.

Transient Woo/source errors use the existing bounded rate-limit, timeout,
server-error, queue-timeout, circuit-open, and transport classifications. A
permanent invariant violation or final Oban attempt fails closed with a bounded
summary while preserving the full `historical_manifest` namespace in cursor
metadata.

Historical manual queueing will enqueue this worker only after the initial run
and cursor transaction and audit succeed. Audit failure records bounded
`failure = audit_failed` cleanup and does not enqueue. Worker enqueue failure
records bounded `failure = worker_enqueue_failed` cleanup and does not leave a
queued worker.

## Testing strategy

Focused tests will use injected source clients, order fetches, mappings,
upserter, clock, and checkpoint seams where useful, plus real Ash/Postgres
resources for cursor/run checkpoint behavior. They will cover nil/exact cursor
requests, one-page-per-step behavior, list endpoint exclusion, continuity and
expiry fail-closed behavior, exact identity validation, deleted/mismatched
orders, current modified dates beyond C, exact mapping, nonmatching orders,
upsert failures, replay before checkpoint, count idempotency, short
nonterminal pages, empty terminal pages, strict metadata, worker settings,
queue/audit failures, and preservation of F1/F2/reconciliation regressions.

No catch-up implementation, source protocol change, new durable inventory, or
production/remote runtime access is part of this design.
