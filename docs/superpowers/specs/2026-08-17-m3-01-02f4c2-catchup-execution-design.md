# M3-01/02F4C2 Immutable Catch-up Execution + Historical Completion

## Goal

Complete one historical run only after immutable manifest evidence and immutable catch-up evidence are both terminal. Every catch-up member is fetched by exact source order ID and reconciled through the existing F4C1 event-order writer using the current canonical attribution rules.

## Architecture

Keep M execution, F4C1 order reconciliation, source protocols, and readiness semantics unchanged. Extend the existing bounded `SyncCursor.metadata` child namespace with exactly three U states:

```text
pending_first_page -> catchup_in_progress -> catchup_terminal
```

The pending state is persisted by the existing bootstrap POST and deliberately causes the first execution step to replay the page with `cursor = nil`. A new U executor processes exactly one page per call, performs all source HTTP and F4C1 writes before a short PostgreSQL checkpoint transaction, and never holds a database lock across HTTP. The final transaction locks and revalidates the cursor, run, Event, and SourceSystem before atomically marking U terminal, cursor done, and the run completed through the canonical `SyncRun` action.

`HistoricalEventLineSelector` uses `WoocommerceOrderParser` for normalized attribution inputs and `OrderItemMapper.resolve_canonical_attribution/2` for read-only resolution. It returns literal raw line maps from the full order, fails closed for relevant unresolved lines, and excludes demonstrably unrelated unresolved mixed-event lines.

No U counters, durable tables, source collection scans, Redis correctness state, or readiness/certification transitions are introduced. The M terminal evidence and all M-derived counters remain unchanged throughout U processing.

## Safety invariants

- U pages are bounded to 100 identities and require explicit paging proof; short pages are never inferred to be terminal.
- Page identity, boundary token, manifest hash, expiry, and `H` are validated against the durable child evidence before and inside each checkpoint.
- Each identity uses only exact-ID order retrieval, and the returned order ID must equal the requested ID.
- Every fetched order calls `reconcile_event_order/4`, including an empty target line subset.
- Checkpoint and completion failures leave the cursor unchanged; replay is safe because F4C1 is idempotent.
- The complete child metadata namespace remains JSON encoded at or below 2048 bytes and contains no identity arrays or full source payloads.

## Validation

Add focused evidence, selector, attribution, executor, worker, and existing F4C1 regression coverage for the required replay, mutation, unresolved-line, continuity, invalidation-race, counter-preservation, metadata-bound, and atomic-completion cases. Run the repository’s focused and full quality gates before committing and opening one draft PR.
