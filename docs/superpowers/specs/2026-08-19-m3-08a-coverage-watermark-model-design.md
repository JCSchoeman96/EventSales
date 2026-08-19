# M3-08A Durable Historical Coverage Watermark Model

## Goal

Extend `EventSales.Ingestion.Resources.SyncRun` with the durable Postgres
fields and narrowly scoped actions required to record and invalidate a
historical coverage certificate. This slice stores certification evidence but
does not evaluate transport evidence or integrate with terminal execution.

## Architecture

`SyncRun` remains the certification identity because it already owns the exact
source, event, historical range, run type, lifecycle, and counts. `SyncCursor`
continues to own detailed manifest and catch-up transport evidence and is not
expanded. The watermark is persisted on `ingestion_sync_runs`; Redis, ETS,
Cachex, PubSub, and a new resource are out of scope.

The model stores independent sales and refund coverage boundaries. The first
certification will later supply `coverage_start = B`,
`sales_covered_through = C`, and `refunds_covered_through = H`, but this slice
does not derive or prove those values.

## Data model

Add nullable UTC timestamp attributes for `coverage_start`,
`sales_covered_through`, `refunds_covered_through`, `coverage_certified_at`,
and `coverage_invalidated_at`. Add non-null atom statuses with defaults:

* `order_coverage_status`: `:incomplete`, `:complete`, or `:failed`; default
  `:incomplete`.
* `refund_coverage_status`: `:not_started`, `:incomplete`, `:complete`, or
  `:failed`; default `:not_started`.

Add nullable `coverage_invalidation_reason` constrained to the contract-derived
reason vocabulary. The additive migration must leave existing runs
uncertified: order status incomplete, refund status not started, and
certification timestamp nil.

## Actions and validation

The private/internal `:record_coverage_certification` update action accepts only
the three boundary values, requires a historical backfill, requires all three
values, enforces `coverage_start <= sales_covered_through`, and rejects a run
that already has `coverage_certified_at`. It sets both coverage statuses to
complete, records server UTC time, and clears invalidation audit fields.

`:invalidate_order_coverage` accepts only a valid invalidation reason, marks
both coverage statuses incomplete, timestamps invalidation, and preserves the
original certificate boundaries and timestamp. `:invalidate_refund_coverage`
marks only refund coverage incomplete and preserves the same audit values.
Neither action has a caller in this slice.

## Testing

Focused resource tests cover defaults, exact certification boundaries,
successful certification with a later refund boundary, range rejection,
non-historical rejection, one-time certification, both invalidation scopes,
invalid reasons, and migration/default behavior for ordinary existing runs.
The existing event index remains the only index used.

## Non-goals

No certification evaluator, terminal transaction changes, order/refund writer
hooks, source HTTP, financial reconciliation, `ANALYTICS_READY`, M4/M5 work,
or cache/realtime infrastructure.
