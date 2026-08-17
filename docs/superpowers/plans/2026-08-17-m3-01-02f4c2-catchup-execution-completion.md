# M3-01/02F4C2 Immutable Catch-up Execution + Historical Completion

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Execute one immutable U page per worker step, reconcile every exact-ID order through F4C1, checkpoint bounded U evidence, and atomically complete the historical run after explicit M and U terminal proof.

**Architecture:** Extend `HistoricalCatchupEvidence` with strict pending, in-progress, and terminal namespaces. Factor a read-only canonical attribution boundary from `OrderItemMapper`; use it in a new raw-line selector. Implement a separate U executor with HTTP outside short PostgreSQL transactions and update the existing worker to sequence M, bootstrap, and U without POST+GET in one perform. Add only narrow cursor actions for U progress and final completion.

**Tech Stack:** Elixir, Ash 3.x, AshPostgres, Ecto/PostgreSQL, Oban, Phoenix workers, existing Woo clients, and the F4C1 `OrderUpserter`.

## Task 1: Establish failing evidence and attribution tests

Files:

- Modify `test/event_sales/ingestion/historical_catchup_evidence_test.exs`.
- Modify `test/event_sales/sales/order_item_mapper_test.exs`.
- Create `test/event_sales/ingestion/historical_event_line_selector_test.exs`.

Add red tests for exact U state keys, mutually exclusive cursor/proof fields, identity continuity, explicit terminal proof, 100-item/page shape limits, expiry/high-water validation, and the 2048-byte metadata bound. Add red tests for read-only source-event-first attribution and selector behavior: literal raw target lines, exclusion of other events, relevant unresolved failure, unrelated unresolved exclusion, and no write side effects.

Run the focused tests and confirm the failures are from the missing U states, read-only boundary, and selector rather than unrelated setup errors.

## Task 2: Implement evidence and canonical read-only resolution

Files:

- Modify `lib/event_sales/ingestion/historical_catchup_evidence.ex`.
- Modify `lib/event_sales/sales/order_item_mapper.ex`.
- Create `lib/event_sales/ingestion/historical_event_line_selector.ex`.

Implement strict U metadata parsing/serialization and continuity helpers while preserving M fields and the existing bootstrap pending state. Add a public read-only attribution resolver that reuses `OrderAttributionResolver` and `MappingResolver`, then make `map_item/1` and `reconcile_item/2` consume that same path. Build the selector on `WoocommerceOrderParser`; return exact raw maps and fail closed only when an unresolved line could belong to the target.

Run the evidence, mapper, and selector tests, then format and compile the directly affected files.

## Task 3: Add narrow cursor actions and U executor tests first

Files:

- Modify `lib/event_sales/ingestion/resources/sync_cursor.ex`.
- Create `lib/event_sales/ingestion/historical_catchup_execution.ex`.
- Create `test/event_sales/ingestion/historical_catchup_execution_test.exs`.

Add only `record_catchup_progress` and `complete_historical`, both accepting only `page` and `metadata`. Implement one-page U execution with exact authority validation before HTTP, M-terminal proof, exact catch-up page retrieval, exact order-ID retrieval, selector/F4C1 reconciliation (including empty subsets), counter preservation, a `before_checkpoint` seam, and short transactional progress/completion paths. Test pending replay, 205 members over three pages, all F4C1 mutations, stale no-op, checkpoint replay, continuity failure, invalidation before checkpoint/completion, terminal atomicity, M-proof and counter preservation, and maximum metadata sizes.

Run the new executor test red before implementation, then green after each checkpoint/completion path. Do not add a migration or any new correctness store.

## Task 4: Update worker orchestration and bootstrap state reuse

Files:

- Modify `lib/event_sales/ingestion/historical_catchup_bootstrap.ex`.
- Modify `lib/event_sales/ingestion/workers/backfill_orders_worker.ex`.
- Modify `test/event_sales/ingestion/historical_catchup_bootstrap_test.exs`.
- Modify `test/event_sales/ingestion/workers/backfill_orders_worker_test.exs`.

Allow bootstrap to reuse valid in-progress/terminal U evidence without a new POST. Sequence M execution, one authorized bootstrap POST with a snooze, then one U page per worker step; never GET U in the POST step. Preserve existing terminal handling, retry classification, and failure bookkeeping.

Run focused worker/bootstrap regressions and the no-POST+GET same-perform assertion.

## Task 5: Full validation and repository artifacts

Run focused tests, then:

```text
mix format --check-formatted
mix compile --warnings-as-errors
mix ash.codegen --dry-run
git diff --exit-code priv/repo/migrations priv/resource_snapshots
mix project.index
mix project.index --check
mix credo --strict
mix test
mix dialyzer
mix hex.audit
mix quality.fast
mix quality.pr
git diff --check
```

Inspect generated index changes and the complete diff for scope, metadata, transaction, source-client, and PR #188 boundaries. Update the relevant Linear issue, commit the coherent implementation, push the required branch, and open one draft PR with the exact requested title. Report the exact baseline, HEAD, changed files, test/gate results, PR number, and CI state, then stop.
