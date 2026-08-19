# M3-05C2 Historical Refund Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate immutable historical M and U page checkpoints on successful C1 refund synchronization for every valid historical member.

**Architecture:** Thread the already-validated `SourceSystem` through each executor's page/member helpers. After the existing M Order write or U F4C1 reconciliation, call the injected `OrderRefundSync.sync_order/3` with fixed source/client identity options and a source loader backed by the preloaded struct. Return refund errors before checkpoint construction. Extend the existing worker's atom classification only.

**Tech Stack:** Elixir, Ash 3.x, AshPostgres, Ecto/Postgres, ExUnit, Oban, existing WooCommerceClient and OrderRefundSync seams.

---

## File map

- Modify: `lib/event_sales/ingestion/historical_manifest_execution.ex` — invoke C1 after M Order handling, including empty subsets, and thread the loaded source into fixed refund options.
- Modify: `lib/event_sales/ingestion/historical_catchup_execution.ex` — invoke C1 after F4C1 for every U member and reuse the loaded source/client options.
- Modify: `lib/event_sales/ingestion/workers/backfill_orders_worker.ex` — classify the exact C1 and WooCommerce refund errors as permanent while preserving existing transient handling and summaries.
- Modify: `test/event_sales/ingestion/historical_manifest_execution_test.exs` — add a test-only refund-sync seam and M ordering/checkpoint tests.
- Modify: `test/event_sales/ingestion/historical_catchup_execution_test.exs` — add a test-only refund-sync seam and U ordering/checkpoint/terminal tests.
- Modify: `test/event_sales/ingestion/workers/backfill_orders_worker_test.exs` — prove refund timeout/rate-limit pause and refund-integrity fail-closed behavior.
- Create: `docs/superpowers/specs/2026-08-18-m3-05c2-historical-refund-integration-design.md` — approved design record.
- Create: `docs/superpowers/plans/2026-08-18-m3-05c2-historical-refund-integration.md` — this implementation plan.

No migration, Ash resource, SyncRun/SyncCursor schema, new worker, webhook, or C1/RefundUpserter production change is allowed.

### Task 1: Add the M refund-sync seam and failing tests

**Files:**
- Modify: `test/event_sales/ingestion/historical_manifest_execution_test.exs`

- [ ] **Step 1: Add a test-only `RefundSync` fake and default it in `base_opts/0`.**

The fake records `{source_system_id, woo_order_id, opts}` and consumes queued
responses, defaulting to `:ok`. Its `sync_order/3` must not perform source
calls. Start/reset it in the existing setup. Keep the existing Woo client and
OrderUpserter fakes unchanged except for a shared ordering trace if needed.

- [ ] **Step 2: Add one failing test for M order-before-refund ordering.**

Use the existing mapped line fixture and assert the M OrderUpserter call is
observed before the refund fake call, the refund fake is called once for
`"42"`, and the page returns `{:continue, _, _}`. Make the refund fake record
the OrderUpserter's durable/call state at invocation so the assertion tests
ordering rather than only final call counts.

- [ ] **Step 3: Add failing tests for M stale, empty, and failure behavior.**

Cover:

```text
OrderUpserter -> {:ok, :stale_noop}
  -> refund sync once; existing stale count remains one
empty current matching subset
  -> no OrderUpserter call; refund sync once; seen count remains one
OrderUpserter success + refund {:error, :timeout}
  -> same error; cursor page remains unchanged
OrderUpserter success + refund {:error, :invalid_refund_list_response}
  -> same permanent atom; cursor page remains unchanged
OrderUpserter error
  -> refund fake has no calls
two members, second refund error
  -> page error; cursor does not advance; first member is replayable
```

- [ ] **Step 4: Run the M focused tests and observe the feature-missing failures.**

Run:

```bash
mix test test/event_sales/ingestion/historical_manifest_execution_test.exs
```

Expected: new assertions fail because production M execution does not yet call
the refund fake; existing tests should still expose any harness mistakes.

### Task 2: Implement M refund gating minimally

**Files:**
- Modify: `lib/event_sales/ingestion/historical_manifest_execution.ex`

- [ ] **Step 1: Thread the validated `source` into M execution.**

Change the successful `run_step/3` branch to call
`execute_state(run, cursor, evidence, source, opts)`, then pass `source` through
`resolve_page/4`, `resolve_item/5`, `resolve_fetched_order/6`, and
`resolve_line_items/6` without changing page evidence or count keys.

- [ ] **Step 2: Call C1 after an empty or non-empty M Order path.**

Use the existing default alias:

```elixir
@order_refund_sync OrderRefundSync
```

For an empty matching subset, increment only `orders_seen_count` after
`sync_order/3` returns `:ok`. For a non-empty subset, preserve the existing
OrderUpserter result/count branch, then call C1 for both persisted and
`:stale_noop` results. A failed Order write must halt before C1. Return
`{:error, reason}` unchanged so no checkpoint path runs.

- [ ] **Step 3: Build fixed C1 options from the preloaded source.**

Merge optional `:order_refund_sync_opts` first, then override with:

```elixir
woocommerce_client: Keyword.get(opts, :woocommerce_client, @woocommerce_client)
woocommerce_client_opts: woocommerce_client_opts(opts)
source_system_loader: fn requested_id ->
  if requested_id == run.source_system_id,
    do: {:ok, source},
    else: {:error, :source_system_mismatch}
end
```

Call the configured `:order_refund_sync` module with the exact run source ID
and exact manifest source order ID. Do not add a Repo transaction or a second
parent Order fetch.

- [ ] **Step 4: Run the M focused suite and verify green.**

Run:

```bash
mix test test/event_sales/ingestion/historical_manifest_execution_test.exs
```

Expected: all existing and new M tests pass, including unchanged M counts and
checkpoint behavior on successful pages.

### Task 3: Add the U refund-sync seam and failing tests

**Files:**
- Modify: `test/event_sales/ingestion/historical_catchup_execution_test.exs`

- [ ] **Step 1: Add/reset a queued-response `RefundSync` fake and inject it in `base_opts/0`.**

Record exact source/order IDs and the final options. Keep the existing
Selector and F4C1 Upserter fakes as the Order authority.

- [ ] **Step 2: Add failing tests for U F4C1-before-refund ordering.**

Cover both `{:ok, %Order{}}` and `{:ok, :stale_noop}`. The fake must observe
the F4C1 call before the refund call. Assert the exact empty selected subset
still reaches F4C1 and then C1.

- [ ] **Step 3: Add failing tests for U failures and terminal behavior.**

Cover:

```text
F4C1 failure -> refund fake not called; cursor unchanged
F4C1 success + refund timeout -> cursor remains active/page unchanged
terminal U refund success -> existing :ok/completed behavior
terminal U refund failure -> run stays running and cursor active
two U members, second refund error -> no checkpoint
same page replay -> repeated C1 call is allowed and page remains replay-safe
```

- [ ] **Step 4: Run the U focused tests and observe the feature-missing failures.**

Run:

```bash
mix test test/event_sales/ingestion/historical_catchup_execution_test.exs
```

Expected: new assertions fail because U execution does not yet invoke C1.

### Task 4: Implement U refund gating minimally

**Files:**
- Modify: `lib/event_sales/ingestion/historical_catchup_execution.ex`

- [ ] **Step 1: Keep the loaded `source` in the existing resolve pipeline.**

The executor already passes `source` into `resolve_page/5` and
`resolve_order/7`; preserve that shape and add only the C1 call after
`normalize_reconcile_result/1` returns `:ok`.

- [ ] **Step 2: Call C1 after both accepted F4C1 results.**

Use the same fixed option construction as M, with the U executor's injected
Woo client and `woocommerce_client_opts/1`. The call must be after
`reconcile_event_order` and before `resolve_order` returns `:ok`; any refund
error must halt `resolve_page/5` before `before_checkpoint/1` and before
terminal metadata/cursor completion.

- [ ] **Step 3: Run the U focused suite and verify green.**

Run:

```bash
mix test test/event_sales/ingestion/historical_catchup_execution_test.exs
```

Expected: all existing and new U tests pass, including terminal completion
only after refund success and unchanged M counters.

### Task 5: Extend worker classification with C1 errors

**Files:**
- Modify: `lib/event_sales/ingestion/workers/backfill_orders_worker.ex`
- Modify: `test/event_sales/ingestion/workers/backfill_orders_worker_test.exs`

- [ ] **Step 1: Add failing worker tests for refund timeout, rate-limit, and integrity atoms.**

Use `ExecutionFake` and `CatchupExecutionFake` responses to prove
`:timeout` pauses/snoozes, `:rate_limited` uses the rate-limit pause delay,
`:invalid_refund_list_response` discards and marks run/cursor failed, and
`:voided_refund_reappeared` also fails closed with an atom-only cursor summary.

- [ ] **Step 2: Run the worker tests and observe the permanent-classification failures.**

Run:

```bash
mix test test/event_sales/ingestion/workers/backfill_orders_worker_test.exs
```

Expected: transient tests pass through existing behavior; new integrity tests
initially return a retryable `{:error, reason}` instead of `{:discard, reason}`.

- [ ] **Step 3: Add only reachable C1/Woo permanent atoms.**

Keep the existing transient set exactly:
`:rate_limited`, `:timeout`, `:server_error`, `:queue_timeout`, `:circuit_open`,
`:transport_error`.

Add to `@permanent_reasons` and therefore `@failure_reasons`:

```elixir
:invalid_refund_list_response
:duplicate_refund_id
:invalid_refund_detail_response
:refund_upsert_failed
:refund_void_failed
:voided_refund_reappeared
:unauthorized
:forbidden
:client_error
:not_found
:invalid_json
:response_mismatch
:pagination_limit
:invalid_request
:misconfigured
```

These are the C1 integrity outcomes and non-transient `WooCommerceError`
reasons reachable from `list_refunds/3` and `fetch_refund/3`; do not add an
unbounded catch-all or change unknown-error behavior.

- [ ] **Step 4: Run the worker focused suite and verify green.**

Run:

```bash
mix test test/event_sales/ingestion/workers/backfill_orders_worker_test.exs
```

Expected: transient refund errors pause/snooze, known integrity/source errors
fail closed, and failure summaries contain only the stable atom string.

### Task 6: Refactor only after green and run gates

**Files:**
- Modify: the three production executors/worker only if a green-preserving helper cleanup is necessary.
- Modify: the three focused test files only for test-helper cleanup.

- [ ] **Step 1: Run all focused tests together.**

```bash
mix test test/event_sales/ingestion/historical_manifest_execution_test.exs test/event_sales/ingestion/historical_catchup_execution_test.exs test/event_sales/ingestion/workers/backfill_orders_worker_test.exs test/event_sales/ingestion/order_refund_sync_test.exs
```

Expected: all focused tests pass.

- [ ] **Step 2: Check the architecture boundary.**

```bash
git diff --check
bash scripts/check_no_web_woocommerce_refs.sh
```

Expected: no whitespace errors and no LiveView/controller WooCommerce REST
references introduced. Do not start local WordPress/Phoenix runtime because
this slice has no integration requiring it.

- [ ] **Step 3: Run the required quality gates.**

Run each command and record its actual result:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix ash.codegen --dry-run
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

Do not claim a gate passed without fresh output. If a gate fails, fix only the
concrete C2 issue or report the blocker.

- [ ] **Step 4: Request review, commit, push, and open one draft PR.**

Review `git diff main...HEAD`, confirm no migration/resource/schema/new worker
changes, commit the implementation coherently, and push:

```bash
git push -u origin path1/m3-05c2-historical-refund-integration
gh pr create --draft --title "Path 1 M3-05C2: integrate refunds into historical execution"
```

Do not mark the PR ready or merge. Report the exact HEAD SHA, draft PR URL,
focused/full test results, quality-gate results, and the explicit C1/webhook/
cursor/schema scope confirmation.
