# M3-01/02F3 Manifest-Driven Historical Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute one immutable Woo order-index manifest page per worker step, resolve every identity by exact order ID, write event-relevant orders only through `OrderUpserter`, and checkpoint progress transactionally without completing the historical run.

**Architecture:** Keep normal collection reconciliation in `OrderReconciliation` and add `HistoricalManifestExecution` as the isolated historical membership consumer. Extend the existing bounded evidence and cursor action for state-specific continuation, then let the worker perform one page and snooze only after a successful short Postgres checkpoint transaction.

**Tech Stack:** Elixir, Phoenix, Ash 3.x, AshPostgres, Ecto/PostgreSQL, Oban, Jason, existing WooCommerce REST and Woo order-index clients, ExUnit, Credo, Dialyzer, and project quality tooling.

---

## Files and responsibilities

- Modify `lib/event_sales/ingestion/historical_manifest_evidence.ex` to validate the four manifest states, exact state-specific key sets, bounded cursors/terminal proof, and failure-preserving metadata helpers.
- Create `test/event_sales/ingestion/historical_manifest_evidence_test.exs` for state and metadata regressions.
- Modify `lib/event_sales/ingestion/resources/sync_cursor.ex` to add the page/metadata-only `record_manifest_progress` Ash action.
- Modify `lib/event_sales/ingestion/clients/woocommerce_client.ex` to expose only `configured_base_url/1` and preserve all existing REST behavior.
- Modify `test/event_sales/ingestion/resources/sync_cursor_test.exs` and `test/event_sales/ingestion/clients/woocommerce_client_test.exs` for action and non-secret configuration coverage.
- Create `lib/event_sales/ingestion/historical_manifest_execution.ex` for one-page validation, exact-ID fetches, exact mapping, page counts, and the short transactional checkpoint.
- Create `test/event_sales/ingestion/historical_manifest_execution_test.exs` for the F3 execution contract and replay/transaction regressions.
- Modify `lib/event_sales/ingestion/workers/backfill_orders_worker.ex` to bootstrap and execute one page with bounded Oban behavior.
- Create `test/event_sales/ingestion/workers/backfill_orders_worker_test.exs` for worker settings, one-step scheduling, terminal behavior, and failure preservation.
- Modify `config/config.exs` to add `historical_backfill: 1` to Oban queues.
- Modify `lib/event_sales/ingestion/manual_sync.ex` and `test/event_sales/ingestion/manual_sync_test.exs` to audit and enqueue the historical worker with distinct bounded cleanup failures.
- Modify `test/event_sales/ingestion/historical_backfill_test.exs` only where existing queue expectations must change from no job to the F3 worker.
- Regenerate project indexes with `mix project.index`; do not hand-edit `INDEX.md` or architecture JSON files.

No resource migration or snapshot change is expected.

### Task 1: Specify strict manifest evidence states

**Files:**

- Modify: `lib/event_sales/ingestion/historical_manifest_evidence.ex`
- Create: `test/event_sales/ingestion/historical_manifest_evidence_test.exs`

- [ ] **Step 1: Write failing state/metadata tests.** Add tests that construct the existing F2 evidence and assert:

```elixir
assert HistoricalManifestEvidence.state(%{}) == :missing
assert HistoricalManifestEvidence.state(HistoricalManifestEvidence.claim_metadata()) == :create_claimed
assert HistoricalManifestEvidence.state(pending_metadata()) == :pending_first_page
assert HistoricalManifestEvidence.state(in_progress_metadata()) == :manifest_in_progress
assert HistoricalManifestEvidence.state(terminal_metadata()) == :manifest_terminal
refute match?({:ok, _}, HistoricalManifestEvidence.from_metadata(in_progress_with_terminal_evidence()))
refute match?({:ok, _}, HistoricalManifestEvidence.from_metadata(terminal_with_next_cursor()))
```

Also assert `next_cursor` and `terminal_evidence` are the only additions for their states, failure merging preserves the nested namespace, and every canonical state remains at or below `metadata_max_bytes/0`.

- [ ] **Step 2: Run the new test and verify the expected RED failure.**

```bash
mix test test/event_sales/ingestion/historical_manifest_evidence_test.exs
```

Expected: failure because the new state parsers/builders do not yet exist.

- [ ] **Step 3: Implement the smallest evidence extension.** Add optional `next_cursor` and `terminal_evidence` fields to the evidence struct, state constants, exact key sets, and public constructors/parsers with this shape:

```elixir
def in_progress_metadata(%__MODULE__{} = evidence, next_cursor) do
  Map.update!(metadata(evidence), "historical_manifest", &Map.merge(&1, %{
    "state" => "manifest_in_progress",
    "next_cursor" => next_cursor
  }))
end

def terminal_metadata(%__MODULE__{} = evidence, terminal_evidence) do
  Map.update!(metadata(evidence), "historical_manifest", &Map.merge(&1, %{
    "state" => "manifest_terminal",
    "terminal_evidence" => terminal_evidence
  }))
end

def with_failure(metadata, failure) when is_map(metadata) and is_binary(failure) do
  Map.put(metadata, "failure", failure)
end
```

`from_metadata/1` must accept exactly the seven F2 keys for pending, eight keys for in-progress, or eight keys for terminal, and reject all other key sets. Keep `canonical_metadata/2` and all existing F2 behavior unchanged.

- [ ] **Step 4: Run the evidence tests and existing F2 bootstrap tests.**

```bash
mix test test/event_sales/ingestion/historical_manifest_evidence_test.exs test/event_sales/ingestion/historical_manifest_bootstrap_test.exs
```

Expected: PASS with no F2 one-shot regression.

- [ ] **Step 5: Commit the evidence slice.**

```bash
git add lib/event_sales/ingestion/historical_manifest_evidence.ex test/event_sales/ingestion/historical_manifest_evidence_test.exs
git commit -m "feat: model historical manifest execution states"
```

### Task 2: Add cursor checkpoint action and Woo source binding helper

**Files:**

- Modify: `lib/event_sales/ingestion/resources/sync_cursor.ex`
- Modify: `lib/event_sales/ingestion/clients/woocommerce_client.ex`
- Modify: `test/event_sales/ingestion/resources/sync_cursor_test.exs`
- Modify: `test/event_sales/ingestion/clients/woocommerce_client_test.exs`

- [ ] **Step 1: Write failing action and URL accessor tests.** Add an Ash test that calls only:

```elixir
Ash.update(cursor, %{page: 2, metadata: metadata},
  action: :record_manifest_progress,
  domain: Ingestion
)
```

and verifies `modified_after`, `modified_before`, `last_seen_order_id`, `sync_run_id`, and `status` are unchanged. Add a client test asserting:

```elixir
assert {:ok, "https://shop.example"} = WooCommerceClient.configured_base_url()
refute inspect(WooCommerceClient.configured_base_url()) =~ "consumer-secret"
```

- [ ] **Step 2: Run the focused tests and verify RED.**

```bash
mix test test/event_sales/ingestion/resources/sync_cursor_test.exs test/event_sales/ingestion/clients/woocommerce_client_test.exs
```

Expected: unknown-action/accessor failures.

- [ ] **Step 3: Implement the page-only Ash action and non-secret accessor.** Add:

```elixir
update :record_manifest_progress do
  accept [:page, :metadata]
  require_atomic? false
  validate {BoundedMetadata, max_bytes: @metadata_max_bytes}
end
```

Implement `WooCommerceClient.configured_base_url/1` by using the existing configuration validation and returning only the normalized base URL. Do not return credentials or runtime config.

- [ ] **Step 4: Run the focused tests and existing client/resource regressions.**

```bash
mix test test/event_sales/ingestion/resources/sync_cursor_test.exs test/event_sales/ingestion/clients/woocommerce_client_test.exs test/event_sales/ingestion/clients/woo_order_index_client_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit the authority-boundary slice.**

```bash
git add lib/event_sales/ingestion/resources/sync_cursor.ex lib/event_sales/ingestion/clients/woocommerce_client.ex test/event_sales/ingestion/resources/sync_cursor_test.exs test/event_sales/ingestion/clients/woocommerce_client_test.exs
git commit -m "feat: add historical cursor checkpoint action"
```

### Task 3: Build one-page historical manifest execution

**Files:**

- Create: `lib/event_sales/ingestion/historical_manifest_execution.ex`
- Create: `test/event_sales/ingestion/historical_manifest_execution_test.exs`

- [ ] **Step 1: Write the first failing execution tests.** Create isolated fakes with request logs for the manifest client, Woo order client, and `OrderUpserter`, then specify these behaviors before implementation:

```elixir
test "pending state requests the first page with nil cursor" do
  assert {:continue, _, _} = run_step(run, cursor, opts)
  assert ManifestClient.calls() == [{:fetch_manifest_page, "boundary", nil}]
end

test "in-progress state uses exactly its persisted opaque cursor" do
  assert {:continue, _, _} = run_step(run, cursor_with_next_cursor, opts)
  assert ManifestClient.calls() == [{:fetch_manifest_page, "boundary", "opaque.next"}]
end

test "one step fetches exactly one manifest page and never list_orders" do
  assert {:continue, _, _} = run_step(run, cursor, opts)
  assert length(ManifestClient.calls()) == 1
  refute WooClient.calls() |> Enum.any?(&match?({:list_orders, _}, &1))
end
```

Add tests for continuity mismatch, expiry before/after GET, invalid returned IDs, not-found orders, current `date_modified_gmt > run.date_to`, exact product/variation matching, nonmatching orders, and upserter errors. Use `fetch_order` request logs to prove every source identity is fetched by ID.

- [ ] **Step 2: Run the execution test and verify RED.**

```bash
mix test test/event_sales/ingestion/historical_manifest_execution_test.exs
```

Expected: module/function failures.

- [ ] **Step 3: Implement validation and page fetch.** Define:

```elixir
@spec run_step(SyncRun.t(), SyncCursor.t() | nil, keyword()) :: step_result()
def run_step(%SyncRun{} = run, %SyncCursor{} = cursor, opts \\ []) do
  with :ok <- validate_run_and_cursor(run, cursor),
       {:ok, source} <- load_and_validate_source(run, opts),
       {:ok, evidence} <- load_evidence(cursor),
       :ok <- validate_state(evidence),
       :ok <- validate_unexpired(evidence, now(opts)),
       :ok <- validate_client_bindings(source, opts),
       {:ok, page} <- fetch_one_page(evidence, opts),
       :ok <- HistoricalManifestEvidence.validate_continuity(evidence, page),
       :ok <- validate_unexpired(evidence, now_after_page(opts)),
       {:ok, counts} <- resolve_page(run, page, opts),
       {:ok, result} <- checkpoint_page(run, cursor, evidence, page, counts, opts) do
    result
  end
end
```

`fetch_one_page/2` must call only `fetch_manifest_page/3`, selecting nil or the exact persisted cursor by state. Terminal evidence returns without a GET. `resolve_page/3` must fetch each item through `fetch_order/2`, validate a map and exact positive ID, ignore current Woo dates for membership, filter only exact product/variation mappings, and call `OrderUpserter` for matches.

- [ ] **Step 4: Add the short transactional checkpoint.** Implement `checkpoint_page/6` with one `Repo.transaction/1`: lock and re-read the exact cursor row using `FOR UPDATE`, verify active status/page/current manifest state and cursor equality, re-read `SyncRun`, update counts from current durable run values, then call the `SyncCursor` action `:record_manifest_progress` with page + 1 and the state-specific metadata. Build `manifest_in_progress` only when `has_more == true` and require `next_cursor`; build `manifest_terminal` only when `has_more == false` and require exact nonempty `terminal_evidence`. Return `{:continue, updated_run, updated_cursor}` or `{:manifest_terminal, updated_run, updated_cursor}`. Never call `:complete` or `:mark_done`.

- [ ] **Step 5: Add replay and checkpoint-conflict tests, then run green.** Test an injected failure immediately before checkpoint, assert no page/count advance, retry the same page, and assert idempotent upserter calls with counts applied once. Test a cursor mutation between page processing and checkpoint and assert a conflict error with zero double advancement. Test short pages with `has_more: true`, empty terminal pages, no `next_cursor` in terminal metadata, terminal evidence authority, unchanged B/C bounds, and nil last-seen ID.

```bash
mix test test/event_sales/ingestion/historical_manifest_execution_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit the execution slice.**

```bash
git add lib/event_sales/ingestion/historical_manifest_execution.ex test/event_sales/ingestion/historical_manifest_execution_test.exs
git commit -m "feat: execute immutable historical manifest pages"
```

### Task 4: Activate the historical worker and manual queue path

**Files:**

- Modify: `lib/event_sales/ingestion/workers/backfill_orders_worker.ex`
- Create: `test/event_sales/ingestion/workers/backfill_orders_worker_test.exs`
- Modify: `config/config.exs`
- Modify: `lib/event_sales/ingestion/manual_sync.ex`
- Modify: `test/event_sales/ingestion/manual_sync_test.exs`
- Modify: `test/event_sales/ingestion/historical_backfill_test.exs`

- [ ] **Step 1: Write failing worker/manual queue tests.** Assert worker reflection exposes queue `historical_backfill`, max attempts 25, unique `sync_run_id`, and that queue configuration sets concurrency 1. Add worker fakes proving bootstrap then one execution step, `{:continue, updated_run, updated_cursor}` snoozes only after checkpoint, and `{:manifest_terminal, updated_run, updated_cursor}` returns `:ok` without completion. Add manual tests for audit failure (`failure = audit_failed`, no job) and enqueue failure (`failure = worker_enqueue_failed`, no active job), with existing manifest evidence retained.

- [ ] **Step 2: Run the worker/manual tests and verify RED.**

```bash
mix test test/event_sales/ingestion/workers/backfill_orders_worker_test.exs test/event_sales/ingestion/manual_sync_test.exs test/event_sales/ingestion/historical_backfill_test.exs
```

Expected: placeholder worker and no historical job failures.

- [ ] **Step 3: Implement worker settings and one-page perform.** Use:

```elixir
use Oban.Worker,
  queue: :historical_backfill,
  max_attempts: 25,
  unique: [
    period: :infinity,
    fields: [:args],
    keys: [:sync_run_id],
    states: ~w(available scheduled executing retryable)a
  ]
```

Load only historical active runs, start/resume queued/paused runs, call `HistoricalManifestBootstrap.ensure_manifest/2`, load the cursor, and call `HistoricalManifestExecution.run_step/3` once. Snooze 1 second only for a successful continue. Return `:ok` for terminal. Map transient source errors to existing pause/snooze semantics; on permanent errors or final attempt, merge a bounded failure summary into cursor metadata, mark the cursor failed if possible, and fail the run without replacing `historical_manifest`.

- [ ] **Step 4: Activate queueing after audit.** Add `historical_backfill: 1` to Oban config. In `ManualSync`, enqueue `BackfillOrdersWorker` only after successful audit; keep injectable audit/enqueuer seams. On audit error cancel and mark the cursor failed with `%{"failure" => "audit_failed"}` merged into existing metadata. On enqueue error use `%{"failure" => "worker_enqueue_failed"}` and safe cancellation. Return the worker in the historical success result and update only tests that currently assert no job.

- [ ] **Step 5: Run worker/manual regressions.**

```bash
mix test test/event_sales/ingestion/workers/backfill_orders_worker_test.exs test/event_sales/ingestion/manual_sync_test.exs test/event_sales/ingestion/historical_backfill_test.exs test/event_sales/ingestion/historical_manifest_bootstrap_test.exs
```

Expected: PASS, including the F2 create-claim one-shot tests.

- [ ] **Step 6: Commit worker and queue activation.**

```bash
git add config/config.exs lib/event_sales/ingestion/workers/backfill_orders_worker.ex test/event_sales/ingestion/workers/backfill_orders_worker_test.exs lib/event_sales/ingestion/manual_sync.ex test/event_sales/ingestion/manual_sync_test.exs test/event_sales/ingestion/historical_backfill_test.exs
git commit -m "feat: activate manifest historical backfill worker"
```

### Task 5: Run slice validation and quality gates

**Files:**

- Generated by tooling only: `INDEX.md`, `docs/architecture/module_manifest.json`, `docs/architecture/domain_map.json`

- [ ] **Step 1: Run formatting, compile, and focused tests.**

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/event_sales/ingestion/historical_manifest_evidence_test.exs test/event_sales/ingestion/historical_manifest_execution_test.exs test/event_sales/ingestion/workers/backfill_orders_worker_test.exs test/event_sales/ingestion/historical_manifest_bootstrap_test.exs test/event_sales/ingestion/clients/woo_order_index_client_test.exs test/event_sales/ingestion/clients/woocommerce_client_test.exs test/event_sales/ingestion/order_reconciliation_test.exs
```

Expected: all focused tests pass with no warnings.

- [ ] **Step 2: Run repository boundary and generated-index checks.**

```bash
bash scripts/check_no_web_woocommerce_refs.sh
mix ash.codegen --dry-run
git diff --exit-code priv/repo/migrations priv/resource_snapshots
mix project.index --check
git diff --check
```

Expected: no migration/resource snapshot diff and no historical REST boundary violation.

- [ ] **Step 3: Run the required quality gates.**

```bash
mix credo --strict
mix test
mix dialyzer
mix quality.fast
mix quality.pr
mix hex.audit
```

Record each command's actual result; do not report a pass for an unrun or failed command.

- [ ] **Step 4: Review the final diff against the F3 checklist.** Confirm no catch-up H, no completion action, no list endpoint call, no per-ID table, no metadata item arrays, no source secrets, no production access, and no changes outside the current slice.

- [ ] **Step 5: Commit generated indexes if the canonical tooling changed them.**

```bash
git add INDEX.md docs/architecture/module_manifest.json docs/architecture/domain_map.json
git commit -m "chore: refresh project indexes for manifest execution"
```

If the tooling produced no diff, do not create this commit.

### Task 6: Push and open the draft PR

- [ ] **Step 1: Verify branch, baseline ancestry, and PR #188 untouched.**

```bash
git rev-parse HEAD
git merge-base --is-ancestor 38f56fa69ec3ceae274ef5e3322450df5fb871b5 HEAD
git diff --stat 38f56fa69ec3ceae274ef5e3322450df5fb871b5 2544c26351ba537792f789eff9f20f805f2e8169
```

Expected: current branch is `path1/m3-01-02f3-manifest-execution`, the canonical baseline is an ancestor, and no command targets PR #188's branch.

- [ ] **Step 2: Push the requested branch.**

```bash
git push -u origin path1/m3-01-02f3-manifest-execution
```

- [ ] **Step 3: Open a draft PR with title `Path 1 M3-01/02F3: execute historical manifest pages`.**

The body must name the exact baseline, explain one-page manifest execution, state that catch-up H remains unimplemented, and include the focused and quality results. Leave PR #188 open/draft/blocked and do not push to its branch.
