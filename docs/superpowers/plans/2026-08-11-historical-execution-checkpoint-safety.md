# Historical Execution & Checkpoint Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate historical `SyncRun` execution as one-page, deterministic, fail-closed Woo traversal with durable checkpoint and replay safety.

**Architecture:** Add a single-page Woo client boundary, an explicit historical step in `OrderReconciliation`, and a dedicated `BackfillOrdersWorker`. Historical page counts, cursor progress, and terminal run completion are committed together after all matching writes succeed; normal reconciliation retains its current behavior behind explicit worker dispatch.

**Tech Stack:** Elixir, Phoenix/Ash 3.x, AshPostgres, Ecto/PostgreSQL, Oban, Jason, ExUnit, existing Woo transport/rate-limiter/circuit-breaker and `OrderUpserter`.

---

## File map

| File | Responsibility in this slice |
| --- | --- |
| `lib/event_sales/ingestion/clients/woocommerce_client.ex` | Add one raw Woo order page request without iteration. |
| `lib/event_sales/ingestion/order_reconciliation.ex` | Add historical page validation, mapping/upsert processing, high-water calculation, and atomic checkpointing while preserving reconciliation mode. |
| `lib/event_sales/ingestion/resources/sync_cursor.ex` | Allow terminal progress fields to be persisted with `:done`. |
| `lib/event_sales/ingestion/manual_sync.ex` | Activate queued historical runs with one unique `BackfillOrdersWorker` job and cleanup on pre-enqueue errors. |
| `lib/event_sales/ingestion/workers/backfill_orders_worker.ex` | Own historical execution, lifecycle, isolation, retry exhaustion, and one-page-per-perform behavior. |
| `lib/event_sales/ingestion/workers/reconcile_orders_worker.ex` | Discard historical runs instead of executing them. |
| `config/config.exs` | Add bounded `historical_backfill: 1` Oban queue. |
| `test/event_sales/ingestion/clients/woocommerce_client_test.exs` | Prove one-page client semantics and reserved page controls. |
| `test/event_sales/ingestion/resources/sync_cursor_test.exs` | Prove terminal progress persistence. |
| `test/event_sales/ingestion/historical_backfill_test.exs` | Prove queue activation, exactly-one enqueue, and enqueue cleanup. |
| `test/event_sales/ingestion/historical_execution_test.exs` | Prove adversarial historical page, tie, bound, write, replay, and checkpoint behavior. |
| `test/event_sales/ingestion/workers/backfill_orders_worker_test.exs` | Prove worker lifecycle, isolation, cursor requirement, invalidation, one-page execution, and retry exhaustion. |
| `test/event_sales/ingestion/workers/reconcile_orders_worker_test.exs` | Prove reconciliation rejects historical runs without regression. |

No new Ash resource, durable table, migration, order writer, refund model, analytics readiness projection, or financial behavior is introduced.

### Task 1: Add and certify the one-page Woo boundary

**Files:**
- Modify: `lib/event_sales/ingestion/clients/woocommerce_client.ex`
- Test: `test/event_sales/ingestion/clients/woocommerce_client_test.exs`

- [ ] **Step 1: Write the failing one-page test**

Add this test beside the existing `list_orders/2` tests. It uses the existing `FakeTransport` and configured `per_page: 2`:

```elixir
test "list_orders_page returns one full raw page without pagination-limit completion" do
  FakeTransport.reset!([
    {:ok, 200, [], Jason.encode!([%{"id" => 1}, %{"id" => 2}])}
  ])

  assert {:ok, [%{"id" => 1}, %{"id" => 2}]} =
           WooCommerceClient.list_orders_page(%{
             "page" => "3",
             "per_page" => "2",
             "modified_after" => "2026-05-01T00:00:00Z"
           })

  assert [%{url: url}] = FakeTransport.requests()
  assert URI.decode_query(URI.parse(url).query) == %{
           "modified_after" => "2026-05-01T00:00:00Z",
           "page" => "3",
           "per_page" => "2"
         }
end
```

- [ ] **Step 2: Run the focused test and confirm the expected red failure**

Run:

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/clients/woocommerce_client_test.exs
```

Expected: compilation/test failure because `list_orders_page/1` is undefined.

- [ ] **Step 3: Write the minimal implementation**

Add `list_orders_page(params \\ %{}, opts \\ [])` that loads the same `config/2`, extracts positive page/per-page values from `params`, removes those reserved keys from the remaining query, calls `guarded_request(:list_orders_page, config, url(...))` once, and returns a list or the existing typed error. Do not call `request_pages/4`. Change `normalize_query_params/1` only to omit reserved `page` and `per_page` keys so existing `list_orders/2` callers cannot duplicate client-controlled pagination parameters.

- [ ] **Step 4: Run the client tests green**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/clients/woocommerce_client_test.exs
```

Expected: all client tests pass, including existing bounded `list_orders/2` pagination and typed `pagination_limit` behavior for products.

- [ ] **Step 5: Commit the client boundary**

```bash
git add lib/event_sales/ingestion/clients/woocommerce_client.ex test/event_sales/ingestion/clients/woocommerce_client_test.exs
git commit -m "feat: add one-page Woo order fetch boundary"
```

### Task 2: Persist terminal cursor progress and dedicate the queue

**Files:**
- Modify: `lib/event_sales/ingestion/resources/sync_cursor.ex`
- Modify: `config/config.exs`
- Test: `test/event_sales/ingestion/resources/sync_cursor_test.exs`

- [ ] **Step 1: Write the failing cursor test**

Add a test that creates an active cursor, calls `:mark_done` with `page`, `modified_after`, `modified_before`, and `last_seen_order_id`, then reloads it and asserts all progress fields plus `status == :done`.

- [ ] **Step 2: Run the focused cursor test and confirm it fails**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/resources/sync_cursor_test.exs
```

Expected: Ash rejects the new `mark_done` attributes.

- [ ] **Step 3: Implement the smallest resource/config change**

Expand `SyncCursor` action `:mark_done` acceptance to `:page`, `:modified_after`, `:modified_before`, `:last_seen_order_id`, and `:metadata`. Add `historical_backfill: 1` next to `reconciliation: 1` in `config/config.exs`; do not change existing queue concurrency.

- [ ] **Step 4: Run the cursor test green and compile**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/resources/sync_cursor_test.exs
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix compile --warnings-as-errors
```

- [ ] **Step 5: Commit the cursor/queue foundation**

```bash
git add lib/event_sales/ingestion/resources/sync_cursor.ex config/config.exs test/event_sales/ingestion/resources/sync_cursor_test.exs
git commit -m "feat: reserve historical backfill queue and terminal cursor progress"
```

### Task 3: Specify historical page semantics with failing tests

**Files:**
- Create: `test/event_sales/ingestion/historical_execution_test.exs`
- Modify: `test/event_sales/ingestion/order_reconciliation_test.exs` only if a shared test helper must be generalized

- [ ] **Step 1: Add bounded test fixtures and doubles**

Define an `Agent`-backed `FakeClient` exposing `list_orders_page/2`, a `FakeNotifier` exposing `notify_order_reconciled/4`, and a `FakeUpserter` whose responses can be changed between attempts. Keep each response a single raw list and record calls so tests can assert at most one fetch per step.

- [ ] **Step 2: Write the failing historical behavior tests**

Cover these individually named behaviors:

```text
full raw page returns :continue and does not complete
configured max_pages never completes a full historical page
short raw page completes transport and marks cursor done/run completed
empty raw page completes transport and marks cursor done/run completed
full raw page with zero Event matches still advances transport
raw progress uses raw page length, not Event match count
orders sharing a modified timestamp are sorted and IDs are not skipped
last_seen_order_id filters already-covered same-time overlap rows
full overlap/replay page continues instead of completing
missing ID and invalid/missing date_modified_gmt fail closed
lower-bound rows are included and upper-bound rows outside date_to are not written
one historical step performs exactly one client page request
```

Create running historical `SyncRun` rows and pre-created cursors directly with Ash. Use the existing catalog mapping helpers and sanitized Woo fixture payloads; do not use production credentials or source calls.

- [ ] **Step 3: Run the new historical tests and verify they fail for missing API**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/historical_execution_test.exs
```

Expected: compile failure because the explicit historical step is not implemented.

### Task 4: Implement deterministic historical page processing and checkpointing

**Files:**
- Modify: `lib/event_sales/ingestion/order_reconciliation.ex`
- Test: `test/event_sales/ingestion/historical_execution_test.exs`

- [ ] **Step 1: Add the explicit historical step API**

Expose `run_historical_step(%SyncRun{}, %SyncCursor{}, keyword())`. It must reject non-`:historical_backfill` runs, require the supplied cursor, validate the run/cursor scope and Event onboarding state, and fetch through `list_orders_page/2` with the configured page/per-page and existing transport options.

- [ ] **Step 2: Validate and normalize the entire raw page before writes**

Implement private helpers that accept only positive integer Woo IDs and parse nonblank `date_modified_gmt` values using the repository’s UTC/no-offset source precision. Return bounded errors such as `{:invalid_historical_source_order, :id}` or `:date_modified_gmt`; never derive progress from `date_created_gmt`, `date_paid_gmt`, `date_completed_gmt`, or wall clock. Sort normalized rows by modified timestamp then ID.

- [ ] **Step 3: Implement inclusive scope and durable high-water comparison**

Retain only normalized rows with `date_modified_gmt >= run.date_from` and `<= run.date_to`, and only rows strictly after the cursor tuple: timestamp first, then ID when timestamps tie. Treat overlap rows at or below the cursor tuple as safe replay duplicates. Derive the greatest successfully covered tuple and calculate the next page: reset to page `1` when the timestamp advances, otherwise increment the current transport page. Never move `modified_after` backward.

- [ ] **Step 4: Implement fail-closed mapping/upsert processing**

Use existing `active_mappings/1`, `filter_matching_line_items/2`, notifier selection, and `OrderUpserter`. Count only newly covered in-scope raw rows. For a matching order, stop immediately on any `OrderUpserter.upsert_order/2` error and return an error; do not record that page’s counts or cursor. Preserve existing reconciliation `process_order/6` behavior unchanged.

- [ ] **Step 5: Implement the atomic checkpoint transaction**

After all page writes succeed, run `Repo.transaction/1` containing `record_counts/2`, either `SyncCursor.upsert_active` with next progress or `SyncCursor.mark_done` with terminal progress, and `SyncRun.complete` only for a raw page shorter than `per_page`. Roll back on any checkpoint error. Do not place the order writes inside this page-wide transaction. Use an optional `:checkpoint_fun` test hook that defaults to `:ok` only to model a checkpoint failure after durable writes without adding a new production resource or dependency.

- [ ] **Step 6: Run all historical execution tests green**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/historical_execution_test.exs test/event_sales/ingestion/order_reconciliation_test.exs
```

- [ ] **Step 7: Commit historical page processing**

```bash
git add lib/event_sales/ingestion/order_reconciliation.ex test/event_sales/ingestion/historical_execution_test.exs test/event_sales/ingestion/order_reconciliation_test.exs
git commit -m "feat: make historical order pages checkpoint-safe"
```

### Task 5: Prove crash/replay and failure safety with database-backed tests

**Files:**
- Test: `test/event_sales/ingestion/historical_execution_test.exs`

- [ ] **Step 1: Add a partial page failure test**

Configure `FakeUpserter` to return success for the first matching order and an error for the second. Assert the first durable order remains, cursor remains at its prior tuple and active, run remains non-completed, and no successful page counts were recorded.

- [ ] **Step 2: Add replay-after-failure tests**

Retry the same page with a successful upserter and assert the page completes, the cursor advances once, counters reflect one successful page, and the durable order/order-item counts do not duplicate. Run the same successful page again from the same cursor fixture and assert `OrderUpserter` identity keeps durable rows unique.

- [ ] **Step 3: Add checkpoint-failure replay test**

Use the real `OrderUpserter` for one valid mapped fixture. First invoke `run_historical_step/3` with `checkpoint_fun: fn -> {:error, :checkpoint_failed} end`; assert the order exists but cursor/run/counters are unchanged. Invoke again without the hook and assert the same durable order and item counts, with one committed page count and advanced cursor.

- [ ] **Step 4: Run the failure/replay tests and commit them**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/historical_execution_test.exs
git add test/event_sales/ingestion/historical_execution_test.exs
git commit -m "test: prove historical page replay safety"
```

### Task 6: Implement and test the isolated historical worker

**Files:**
- Modify: `lib/event_sales/ingestion/workers/backfill_orders_worker.ex`
- Modify: `lib/event_sales/ingestion/workers/reconcile_orders_worker.ex`
- Create: `test/event_sales/ingestion/workers/backfill_orders_worker_test.exs`
- Modify: `test/event_sales/ingestion/workers/reconcile_orders_worker_test.exs`

- [ ] **Step 1: Write failing worker isolation/lifecycle tests**

Cover:

```text
BackfillOrdersWorker discards reconciliation run IDs
ReconcileOrdersWorker discards historical run IDs
historical worker fails closed without creating a missing cursor
queued historical run starts and executes one page
future paused historical run snoozes without a Woo request
elapsed paused run resumes
completed/failed/cancelled historical run discards
invalidated Event blocks the next page without fetching
final retry attempt marks run failed and cursor failed
```

Use `Oban.Job` structs with explicit `attempt` and `max_attempts` for retry-exhaustion assertions and the fake client/upserter from the historical test support.

- [ ] **Step 2: Run worker tests and verify red**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/workers/backfill_orders_worker_test.exs test/event_sales/ingestion/workers/reconcile_orders_worker_test.exs
```

Expected: `BackfillOrdersWorker` has no worker behavior and reconciliation currently accepts historical runs.

- [ ] **Step 3: Implement the dedicated worker**

Use `use Oban.Worker, queue: :historical_backfill, max_attempts: 25, unique: [period: :infinity, fields: [:args], keys: [:sync_run_id], states: ~w(available scheduled executing retryable)a]`. Load the run, reject non-historical types, reject terminal states, verify scope/Event/cursor, apply queued/paused lifecycle transitions, call one historical step, snooze one second on `:continue`, and return `:ok` on terminal completion. On final `{:error, reason}`, mark the cursor failed and run failed with bounded error metadata; deterministic safety failures fail closed without fetching.

- [ ] **Step 4: Harden reconciliation dispatch**

In `ReconcileOrdersWorker.load_run/1`, return `:discard` for `%SyncRun{sync_type: :historical_backfill}` before lifecycle or cursor work. Keep normal reconciliation runs unchanged.

- [ ] **Step 5: Run worker tests green and commit**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/workers/backfill_orders_worker_test.exs test/event_sales/ingestion/workers/reconcile_orders_worker_test.exs
git add lib/event_sales/ingestion/workers/backfill_orders_worker.ex lib/event_sales/ingestion/workers/reconcile_orders_worker.ex test/event_sales/ingestion/workers/backfill_orders_worker_test.exs test/event_sales/ingestion/workers/reconcile_orders_worker_test.exs
git commit -m "feat: isolate historical backfill worker execution"
```

### Task 7: Activate historical queueing and prove cleanup

**Files:**
- Modify: `lib/event_sales/ingestion/manual_sync.ex`
- Modify: `test/event_sales/ingestion/historical_backfill_test.exs`

- [ ] **Step 1: Write failing queue activation tests**

Change the existing historical queue test to assert:

```elixir
assert {:ok, %{sync_run: run, sync_cursor: cursor, job: job}} = queue(event, admin)
assert_enqueued(worker: BackfillOrdersWorker, args: %{"sync_run_id" => run.id})
assert job.args == %{"sync_run_id" => run.id}
assert length(all_enqueued(worker: BackfillOrdersWorker)) == 1
```

Add a test passing `oban_insert: fn _job -> {:error, :queue_unavailable} end` and assert `{:error, :enqueue_failed}`, run status `:cancelled`, cursor remains non-runnable, and no active historical run remains. Preserve the existing audit assertions and update the no-job expectation to exactly one historical job.

- [ ] **Step 2: Run historical queue tests and verify red**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/historical_backfill_test.exs
```

Expected: current queueing returns no job and uses `ReconcileOrdersWorker` only for normal manual syncs.

- [ ] **Step 3: Implement activation after audit**

Change `historical_result` to include `job`. Keep run/cursor creation atomic. After transaction notifications and the existing historical audit succeed, enqueue `BackfillOrdersWorker.new(%{"sync_run_id" => run.id})` through `Keyword.get(opts, :oban_insert, &Oban.insert/1)`. On audit or enqueue failure, cancel the queued run and return `:enqueue_failed` for enqueue failure or the original bounded error for audit failure. Do not enqueue in the run/cursor transaction.

- [ ] **Step 4: Run queue tests green and commit**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/historical_backfill_test.exs test/event_sales/ingestion/manual_sync_test.exs
git add lib/event_sales/ingestion/manual_sync.ex test/event_sales/ingestion/historical_backfill_test.exs
git commit -m "feat: activate historical backfill queueing"
```

### Task 8: Full focused regression and quality gates

- [ ] **Step 1: Run the complete focused slice suite**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:$PATH mix test test/event_sales/ingestion/historical_backfill_test.exs test/event_sales/ingestion/historical_execution_test.exs test/event_sales/ingestion/order_reconciliation_test.exs test/event_sales/ingestion/workers/backfill_orders_worker_test.exs test/event_sales/ingestion/workers/reconcile_orders_worker_test.exs test/event_sales/ingestion/clients/woocommerce_client_test.exs test/event_sales/ingestion/resources/sync_cursor_test.exs
```

- [ ] **Step 2: Run required repository gates**

```bash
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin mix format --check-formatted
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin mix compile --warnings-as-errors
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin mix project.index --check
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin mix quality.pr
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin mix quality.ci
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin mix hex.audit
PATH=/home/jcschoeman96/.local/share/mise/installs/elixir/1.19.3-otp-28/bin:/home/jcschoeman96/.local/share/mise/installs/erlang/28.1.1/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin mix deps.audit
git diff --check
git status --short
```

Fix only concrete M3-01/02B failures. Do not add a migration or generated artifact unless a gate proves it is legitimately required; if a schema change becomes necessary, stop and report blocked.

- [ ] **Step 3: Inspect diff for scope contamination**

```bash
git diff origin/main...HEAD --stat
git diff origin/main...HEAD --name-only
rg -n "date_paid_gmt|refund|ORDER_COMPLETE|REFUND_COMPLETE|ANALYTICS_READY|M3-03|HistoricalOrderWriter|BackfillOrderWriter" lib test config docs/superpowers
```

The final search may only show forbidden-scope terms in tests/spec language that explicitly states they are not implemented; no M3-03+ production behavior is allowed.

- [ ] **Step 4: Commit any final focused corrections, then hand off for review**

```bash
git status -sb
git log --oneline --decorate -8
```

After fresh verification, use the GitHub publish workflow to push
`path1/m3-01-02b-historical-execution-safety` and open a draft PR titled
`Path 1 M3-01/02B: make historical execution checkpoint-safe` against `main`.
