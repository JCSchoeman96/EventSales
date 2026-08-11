# Historical Execution & Checkpoint Safety Design

## Goal

Activate the durable historical `SyncRun` and `SyncCursor` contract so one
`BackfillOrdersWorker` execution fetches and safely processes exactly one raw
WooCommerce order page, advances a deterministic modified-time/order-ID
high-water only after successful durable writes, and reaches transport
completion only from source-safe short or empty pages.

## Scope and boundaries

The implementation reuses `SyncRun`, `SyncCursor`, `OrderReconciliation`,
`WooCommerceClient`, and `OrderUpserter`. It adds no durable resource and no
migration. `OrderUpserter` remains the sole durable order writer. Historical
transport completion is not financial completeness, `ORDER_COMPLETE`,
`REFUND_COMPLETE`, or `ANALYTICS_READY`.

Normal reconciliation keeps its existing page iteration and tolerant
individual-upsert semantics. Historical behavior is selected explicitly by
`BackfillOrdersWorker`; `ReconcileOrdersWorker` rejects historical runs, and
`BackfillOrdersWorker` rejects reconciliation runs.

## Components

### WooCommerce one-page boundary

`WooCommerceClient.list_orders_page/2` is an additive client API. It performs
one bounded request using the existing configuration, Basic authentication,
rate limiter, circuit breaker, transport, timeout, and telemetry paths. It
returns the decoded raw page and never iterates or reports
`:pagination_limit`. Existing `list_orders/2` behavior remains intact, with
reserved page parameters normalized so reconciliation does not send duplicate
page controls.

### Historical reconciliation step

`OrderReconciliation` gains an explicit historical step. It:

1. Requires the supplied pre-created active cursor and verifies the immutable
   run scope and Event remains `:backfill_pending`.
2. Requests one raw page with `modified_after`, `modified_before`, ascending
   modified ordering, the cursor transport page, and the configured bounded
   page size. Request timestamps use the existing second precision; local
   filtering retains the inclusive logical `[run.date_from, run.date_to]`
   range.
3. Validates every raw order's positive Woo ID and `date_modified_gmt` before
   any durable order write. Invalid or missing values fail closed.
4. Sorts valid raw rows by `{date_modified_gmt, id}`. Rows outside the
   immutable logical range and rows already covered by the durable high-water
   are not counted or written, while the raw page length remains authoritative
   for terminal detection.
5. Filters matching Event lines using the existing mapping logic and sends
   every matching order through `OrderUpserter`. A write failure stops the page
   immediately and returns an error without cursor or successful-page changes.
6. Commits page counts plus either the next active cursor or terminal cursor
   state in one Postgres transaction. A terminal short/empty raw page also
   marks the run completed in that same transaction.

The historical high-water is represented only by `cursor.modified_after` and
`cursor.last_seen_order_id`. When the greatest successful tuple advances the
timestamp, the transport page resets to `1`; while traversing the same
timestamp tie bucket, the page increments and the greatest ID is retained.
Overlap rows at or below the durable tuple are safe replays and never move the
high-water backward. A full raw page always continues, including a full page
containing only overlap or unmatched rows.

`SyncCursor.mark_done` accepts the existing progress fields so terminal cursor
progress, status, counts, and run completion can be committed together. The
cursor's `page` remains transport bookkeeping, never completeness authority.

### Historical worker and activation

`BackfillOrdersWorker` uses the dedicated `:historical_backfill` queue at
concurrency one, with Oban uniqueness keyed by `sync_run_id`. Each `perform/1`
call loads and validates one active historical run and its existing cursor,
starts/resumes lifecycle state, invokes one historical step, and returns
`:snooze` for continuation. It does not recursively loop through history.

Missing cursor, scope mismatch, Event invalidation, malformed source tuples,
and other deterministic safety failures fail closed without fetching another
page. Retryable page/upsert/checkpoint errors are returned for Oban retry; at
final attempt the worker marks the run failed and the cursor failed where one
exists, preventing a durable run from remaining `:running` forever.

Historical queueing now performs the existing durable run/cursor transaction,
audit write, and exactly one `BackfillOrdersWorker` enqueue. Any audit or
enqueue error before activation cancels the queued run, so no active runnable
run is stranded. Oban uniqueness prevents competing historical jobs for one
run ID.

## Failure and replay model

Order writes are intentionally not wrapped in one page-wide transaction.
Earlier successful writes may remain when a later matched order fails. The
cursor and successful-page counters remain unchanged, so retrying the same raw
page replays through `OrderUpserter` and converges without duplicate durable
orders or order items. If the checkpoint transaction fails after order writes,
the same replay behavior applies; counts and cursor state are committed only
when their transaction commits together.

No page limit or worker invocation count establishes completion. Only a raw
page shorter than the requested `per_page` (including an empty page) establishes
source-safe exhaustion for the immutable bounded query.

## Verification

Focused tests cover queue activation and failure cleanup, worker isolation and
lifecycle, one-page fetching, full/short/empty terminal behavior, configured
`max_pages` non-authority, unmatched raw pages, tuple validation and bounds,
same-timestamp ID ties, high-water progression, fail-closed writes, replay and
checkpoint safety, counter/checkpoint atomicity, Event invalidation, retry
exhaustion, and existing reconciliation compatibility. Client tests prove the
additive one-page boundary reuses the existing HTTP safeguards without
iteration.

The slice does not add financial, refund, sale-clock, analytics-readiness, or
dashboard behavior.
