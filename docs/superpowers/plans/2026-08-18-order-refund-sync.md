# M3-05C1 Order Refund Sync Implementation Plan

> For agentic workers: use the executing-plans skill to implement this plan task-by-task. Steps use checkbox syntax for tracking.

Goal: Synchronize one WooCommerce order's current refund membership and full refund objects into durable Refund facts, voiding only refunds whose exact source deletion is confirmed.

Architecture: OrderRefundSync validates the source/client binding, performs one bounded parent-scoped list, delegates every full object to RefundUpserter, and confirms only omitted local active IDs with exact detail requests. RefundUpserter.mark_source_deleted/5 is the only void writer and owns a short row-lock transaction; all source HTTP happens outside that transaction.

Tech Stack: Elixir, Ash 3.x, AshPostgres, Ecto/Postgres, WooCommerceClient, ExUnit.

---

## File map

- Create: lib/event_sales/ingestion/order_refund_sync.ex — source validation, list validation, full-detail orchestration, candidate discovery, exact deletion confirmation, and error normalization.
- Create: test/event_sales/ingestion/order_refund_sync_test.exs — focused sync contract tests with a fake client and the real durable RefundUpserter where persistence is under test.
- Modify: lib/event_sales/sales/refund_upserter.ex — add the narrow transactional mark_source_deleted/5 operation; do not add another writer.
- Modify: test/event_sales/sales/refund_upserter_test.exs — verify exact void scope, idempotency, preserved audit/financial facts, and cross-source isolation.

No migration, resource change, historical integration, webhook integration, worker, completeness watermark, analytics, Redis, ETS, or PubSub file is part of this plan.

### Task 1: Add the failing void-writer contract tests

Files:
- Modify: test/event_sales/sales/refund_upserter_test.exs

- [ ] Step 1: Add tests for the public operation before implementation.

Cover these behaviors with the existing SalesHelpers fixtures:

    marks the exact active refund source-deleted
      -> source_state is :voided
      -> void_reason is "source_deleted"
      -> voided_at equals the injected DateTime
      -> existing RefundLines remain

    source-deleted void replay preserves the original voided_at
      -> the second call returns the same row
      -> the second observed time is ignored
      -> source_state never returns to :active

    source-deleted void is scoped by source, order, and refund identity
      -> same refund ID under another source is untouched
      -> same source with another order is untouched

    source-deleted void returns :refund_not_found for a missing exact refund

Use the real upsert_normalized_refund/3 helper to create the durable facts that the new operation will void.

- [ ] Step 2: Run the focused test and verify the intended red failure.

Run: mix test test/event_sales/sales/refund_upserter_test.exs

Expected: compilation/test failure because RefundUpserter.mark_source_deleted/4 is not yet defined. Do not implement production code before observing this feature-missing failure.

### Task 2: Implement the short transactional void writer

Files:
- Modify: lib/event_sales/sales/refund_upserter.ex

- [ ] Step 1: Add the public signature and identity validation.

Add mark_source_deleted(source_system_id, woo_order_id, woo_refund_id, observed_at, opts \\ []) with a result type matching the existing upserter. Reuse validate_identity/2 and positive_identity/2, and reject a non-DateTime observed_at with {:error, {:invalid_refund_identity, :observed_at}}.

- [ ] Step 2: Lock the exact row and use the existing Ash action.

Implement a short Repo.transaction/1 around the existing exact lock_refund/3 query:

    active exact row
      -> ash_update(row, %{void_reason: "source_deleted", voided_at: observed_at}, :mark_voided)
    already voided exact row
      -> return it unchanged
    missing exact row
      -> rollback :refund_not_found
    other lock/update error
      -> rollback :refund_void_failed

The transaction must not call WooCommerceClient, delete a row, or reactivate a row. Normalize its result using the existing upserter transaction conventions.

- [ ] Step 3: Run the focused tests and verify green.

Run: mix test test/event_sales/sales/refund_upserter_test.exs

Expected: all existing and new RefundUpserter tests pass.

### Task 3: Add failing source-safe synchronization tests

Files:
- Create: test/event_sales/ingestion/order_refund_sync_test.exs

- [ ] Step 1: Add a fake client with URL, list, fetch, and call recording.

Define a test-only client with configured_base_url/1, list_refunds/3, and fetch_refund/3. Record every list/fetch call in an Agent and return test-configured responses. It must never perform HTTP.

- [ ] Step 2: Add source-safety tests.

Cover an exact active Woo source, missing source, inactive source, non-Woo source, invalid base URL, configured URL mismatch, and misconfigured client. Assert that no list/fetch call is recorded after each validation failure.

- [ ] Step 3: Add list and detail tests.

Cover empty list, one full object, multiple full objects, replay, invalid/missing/non-positive IDs, duplicate IDs, and a listed full object that is already voided. Assert that every listed object goes through the injected upserter and fetch_refund/3 is never called for listed IDs.

- [ ] Step 4: Run the new focused test and verify the intended red failure.

Run: mix test test/event_sales/ingestion/order_refund_sync_test.exs

Expected: compilation/test failure because OrderRefundSync does not yet exist. Fix only test-harness mistakes; keep the feature-missing failure observable.

### Task 4: Implement source validation and full-list processing

Files:
- Create: lib/event_sales/ingestion/order_refund_sync.ex

- [ ] Step 1: Add the public API and narrow dependency seams.

Implement:

    sync_order(source_system_id, woo_order_id, opts \\ [])

with production defaults for SourceSystem loader, WooCommerceClient, client options, RefundUpserter, upserter options, and DateTime.utc_now/0 observation time. Support {:ok, source}, a source struct, and missing/error loader results. Normalize missing/error loader results to :source_system_not_found.

- [ ] Step 2: Implement fail-closed source and client binding validation.

Require source.id equal to source_system_id, kind :woocommerce, active true, a valid non-empty normalized http/https URI, and equality between normalized SourceSystem.base_url and normalized configured WooCommerce client URL. Normalize client configuration failures or missing callbacks to :source_client_misconfigured and URL inequality to :source_endpoint_mismatch. Perform no list/fetch call until validation completes.

- [ ] Step 3: Implement one bounded list call and strict ID validation.

Call exactly:

    client.list_refunds(woo_order_id, %{}, client_opts)

Accept a successful response only when it is a list of maps with unique positive IDs. Accept one string "id" or atom :id representation; reject missing, zero, negative, non-integer, conflicting representations, and duplicate IDs. Normalize malformed membership to :invalid_refund_list_response and duplicates to :duplicate_refund_id.

- [ ] Step 4: Delegate every listed object to RefundUpserter and stop before deletion discovery on failure.

Call the injected upserter's upsert_refund/4 once per returned object, in list order. Normalize a non-success to :refund_upsert_failed. If the returned record has source_state :voided, return :voided_refund_reappeared. Do not call fetch_refund/3 for listed IDs.

- [ ] Step 5: Run the sync focused tests and verify green for these cases.

Run: mix test test/event_sales/ingestion/order_refund_sync_test.exs

Expected: source-safety, list-validation, detail-delegation, replay, and no-N+1 tests pass. Candidate-confirmation tests are added in Task 5.

### Task 5: Add and implement exact deletion confirmation

Files:
- Modify: test/event_sales/ingestion/order_refund_sync_test.exs
- Modify: lib/event_sales/ingestion/order_refund_sync.ex

- [ ] Step 1: Add candidate confirmation tests before implementing the stage.

Create a local active refund omitted from the fake list and cover:

    fetch_refund -> {:ok, exact_refund}
      -> exact object is replayed through upsert_refund
      -> refund remains active and mark_source_deleted is not called

    fetch_refund -> {:error, %WooCommerceError{reason: :not_found}}
      -> mark_source_deleted receives the injected observed_at

    fetch_refund -> a transient WooCommerceError
      -> sync returns the transient atom and refund remains active

    fetch_refund -> a permanent or invalid response
      -> sync fails closed and refund remains active

Also cover two listed objects where the second upsert fails: sync returns :refund_upsert_failed and no fetch/void call occurs. A retry with both successful objects must converge to one durable row per identity and then allow deletion discovery.

- [ ] Step 2: Run the candidate tests and verify the intended red failure.

Run: mix test test/event_sales/ingestion/order_refund_sync_test.exs

Expected: failures showing that omitted active refunds are not yet confirmed/voided by the new module.

- [ ] Step 3: Read active candidates after all list upserts succeed.

Use a bounded Ash query filtered exactly by source_system_id, woo_order_id, and source_state :active. Compare IDs with the validated current list. Do not lock the candidate query for source confirmation and do not wrap later HTTP calls in Repo.transaction/1.

- [ ] Step 4: Confirm each candidate outside database locks.

For each absent ID call client.fetch_refund(woo_order_id, woo_refund_id, client_opts):

    {:error, %WooCommerceError{reason: :not_found}}
      -> upserter.mark_source_deleted(source_system_id, woo_order_id, woo_refund_id, observed_at, upserter_opts)

    {:ok, exact_refund} when is_map(exact_refund)
      -> upserter.upsert_refund(source_system_id, woo_order_id, exact_refund, upserter_opts)

    {:error, %WooCommerceError{reason: reason}}
      -> return {:error, reason}

    other
      -> return {:error, :invalid_refund_detail_response}

Normalize void-writer failures to :refund_void_failed and exact reappearance of a voided identity to :voided_refund_reappeared. The exact object path must not call mark_source_deleted.

- [ ] Step 5: Run the complete focused sync suite.

Run:

    mix test test/event_sales/ingestion/order_refund_sync_test.exs
    mix test test/event_sales/sales/refund_upserter_test.exs

Expected: all focused sync and upserter tests pass, including replay and retained-line/financial-fact assertions.

### Task 6: Refactor only after green and verify slice boundaries

Files:
- Modify: lib/event_sales/ingestion/order_refund_sync.ex only for small green-preserving cleanup.
- Modify: focused tests only to reduce helper duplication without changing behavior.

- [ ] Step 1: Keep stable helper boundaries.

Keep source calls, candidate reads, and upserter transactions in separate functions. Keep error normalization atom-only and never include credentials, credential-bearing URLs, response bodies, or customer data in returned/persisted reasons.

- [ ] Step 2: Verify no forbidden integration was touched.

Run:

    git diff --check
    rg -n "HistoricalManifestExecution|HistoricalCatchupExecution|BackfillOrdersWorker|WebhookProcessor|ProcessWebhookWorker|REFUND_COMPLETE|Redis|ETS|Cachex|PubSub" lib/event_sales/ingestion/order_refund_sync.ex lib/event_sales/sales/refund_upserter.ex test/event_sales/ingestion/order_refund_sync_test.exs test/event_sales/sales/refund_upserter_test.exs

Expected: no implementation references to the listed non-goal integrations.

- [ ] Step 3: Run the required quality gates at slice completion.

Run in order:

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

Record each command's actual exit status. Do not claim a gate passed if it was not run or if it failed.

- [ ] Step 4: Review final scope and prepare the coherent implementation commit.

Run:

    git status
    git diff main...HEAD

Confirm only the approved planning records, the new sync module/test, and the narrow upserter/test changes are present; no migration or resource snapshot changed. Commit implementation changes coherently, push the exact branch, and open one draft PR titled:

    Path 1 M3-05C1: synchronize order refunds and confirmed source deletion

Do not mark the PR ready or merge it.
