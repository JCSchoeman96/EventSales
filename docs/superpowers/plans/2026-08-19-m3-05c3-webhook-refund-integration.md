# M3-05C3 Webhook Refund Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make accepted WooCommerce order webhooks synchronize refunds after the existing OrderUpserter and before the existing order-processed notifier, while preserving webhook gates and retry lifecycle.

**Architecture:** Keep the change inside `WebhookProcessor`. After a successful OrderUpserter result, including `:stale_noop`, call the configurable `OrderRefundSync` with the webhook's source UUID and exact string `resource_id`; classify only C1's six transient atoms as retryable and fail closed for every other C1 error. The existing worker and WebhookEvent lifecycle remain unchanged.

**Tech Stack:** Elixir, Ash 3.x, AshPostgres, ExUnit, existing `WebhookProcessor`, `OrderUpserter`, `OrderRefundSync`, `OrderProcessedNotifier`, and Oban worker contract.

---

## File map

- Modify: `test/event_sales/ingestion/webhook_processor_test.exs` — configure the application refund-sync seam, add a recording fake and sequence fake, and prove accepted ordering, source identity, stale-noop behavior, retry classification, permanent failure, and ignored-event protection.
- Modify: `lib/event_sales/ingestion/webhook_processor.ex` — call C1 after accepted OrderUpserter results, classify C1 errors, and expose the existing `:order_refund_sync` application seam.
- Create: `docs/superpowers/specs/2026-08-19-m3-05c3-webhook-refund-integration-design.md` — approved design, committed in `ad3b9dd`.
- Create: `docs/superpowers/plans/2026-08-19-m3-05c3-webhook-refund-integration.md` — this plan.

No `ProcessWebhookWorker`, `WebhookEvent` resource, `OrderRefundSync`, `RefundUpserter`, migration, index, queue, cache, or topic changes are allowed.

### Task 1: Add the failing webhook integration tests

**Files:**
- Modify: `test/event_sales/ingestion/webhook_processor_test.exs`

- [ ] **Step 1: Add the configured refund-sync fake and isolate its response queue.**

In `setup`, capture and restore `Application.get_env(:event_sales, :order_refund_sync)`, set the configured module to `__MODULE__.RefundSync`, and initialize a per-test process-dictionary response queue with `[:ok]`. Preserve the existing upserter/notifier environment restoration and test PID.

Add this test-only module; it performs no HTTP or database writes and sends one trace message for every call:

    defmodule RefundSync do
      @moduledoc false

      def sync_order(source_system_id, woo_order_id) do
        test_pid = Application.fetch_env!(:event_sales, :webhook_processor_test_pid)
        send(test_pid, {:webhook_step, {:refund_sync, source_system_id, woo_order_id}})

        case Process.get(:webhook_processor_refund_sync_responses, [:ok]) do
          [response | rest] ->
            Process.put(:webhook_processor_refund_sync_responses, rest)
            response

          [] ->
            :ok
        end
      end
    end

Add trace sends to the existing `SuccessfulUpserter`, `StaleNoopUpserter`, and `Notifier` test modules so a test can assert the call sequence without relying on final database state alone. Add a `SequenceUpserter` that consumes `Process.get(:webhook_processor_order_upserter_responses, [])`, returning each queued result in order and sending `{:webhook_step, :order_upsert}` before it returns.

- [ ] **Step 2: Add the accepted `order.updated` and `order.created` red tests.**

Extend the existing real-upserter supported-order test to assert that C1 receives `{source.id, "10001"}` and that the event is processed only after the refund fake succeeds. Add an `order.created` test using the same valid order fixture and assert the same processed state and exact string resource ID.

Add this ordering assertion to the configured-fake path:

    assert :ok = WebhookProcessor.process(event.id)

    assert_receive {:webhook_step, :order_upsert}
    assert_receive {:webhook_step, {:refund_sync, ^source_id, "10001"}}
    assert_receive {:webhook_step, :notifier}
    assert reload!(event.id).status == :processed

The production code at this point does not call the refund fake, so the new refund assertion must fail for the missing integration rather than pass immediately.

- [ ] **Step 3: Add the stale-noop, order-failure, and retry red tests.**

Cover these exact behaviors:

    OrderUpserter -> {:ok, :stale_noop}
      -> exactly one C1 call with the source UUID and string resource ID
      -> no notifier; WebhookEvent becomes processed after C1 :ok

    OrderUpserter -> {:error, %DBConnection.ConnectionError{}}
      -> no C1 call; WebhookEvent remains queued and returns the existing transient tuple

    OrderUpserter -> %Order{}
    C1 -> {:error, :timeout}
      -> no notifier; WebhookEvent remains queued and returns {:error, {:transient, :timeout}}

    first processing: OrderUpserter -> %Order{}, C1 -> {:error, :timeout}
    retry:           OrderUpserter -> {:ok, :stale_noop}, C1 -> :ok
      -> second C1 call succeeds, no notifier occurs on either attempt, event is processed

The retry test must assert `processing_attempt_count == 2` and that the event does not become processed after the first transient failure.

- [ ] **Step 4: Add red tests for all C1 transient atoms and representative permanent atoms.**

Use the fake response queue to exercise each transient atom:

    [:rate_limited, :timeout, :server_error, :queue_timeout, :circuit_open, :transport_error]

For each event, assert the return is `{:error, {:transient, reason}}`, the status is `:queued`, and `failed_at` is nil. Exercise representative permanent outcomes including `:invalid_refund_list_response`, `:duplicate_refund_id`, `:invalid_refund_detail_response`, `:refund_upsert_failed`, `:refund_void_failed`, `:voided_refund_reappeared`, `:unauthorized`, `:forbidden`, `:client_error`, and `:source_endpoint_mismatch`; assert the processor returns `:ok`, marks the event `:failed`, and never notifies.

- [ ] **Step 5: Extend ignored-gate tests to assert no refund call.**

For unsupported, duplicate processed resource-hash, and stale-against-newer processed events, retain the existing ignored assertions and add `refute_receive {:webhook_step, {:refund_sync, _, _}}`. Do not route these tests through a new handler or change the gate predicates.

- [ ] **Step 6: Run the focused test file and verify the expected RED state.**

Run:

    mix test test/event_sales/ingestion/webhook_processor_test.exs

Expected result: the newly added refund assertions fail because `WebhookProcessor` still goes directly from OrderUpserter to notifier or processed state. Existing unrelated tests must not fail for a test-harness reason; fix only harness mistakes before implementation.

### Task 2: Implement the minimal WebhookProcessor integration

**Files:**
- Modify: `lib/event_sales/ingestion/webhook_processor.ex`

- [ ] **Step 1: Add the existing C1 dependency and transient atom list.**

Add:

    alias EventSales.Ingestion.OrderRefundSync

    @transient_refund_reasons [
      :rate_limited,
      :timeout,
      :server_error,
      :queue_timeout,
      :circuit_open,
      :transport_error
    ]

Do not add source-ID parsing, a new validation helper, or a new dependency layer.

- [ ] **Step 2: Insert C1 after both accepted OrderUpserter outcomes.**

Change only `handle_order_event/1` and its directly supporting private helpers so the control flow is:

    defp handle_order_event(%WebhookEvent{} = event) do
      case order_upserter().upsert_from_webhook_event(event) do
        {:ok, %Order{} = order} ->
          with :ok <- sync_order_refunds(event) do
            notify_order_processed(order, event)
            :ok
          end

        {:ok, :stale_noop} ->
          sync_order_refunds(event)

        {:error, reason} ->
          classify_upsert_error(reason)
      end
    end

`sync_order_refunds/1` must call exactly:

    order_refund_sync().sync_order(event.source_system_id, event.resource_id)

It must map `:ok` to `:ok`, map `{:error, reason}` through the six-atom transient list, and map every other result/reason to `{:error, {:permanent, reason}}`. The application seam is:

    defp order_refund_sync do
      Application.get_env(:event_sales, :order_refund_sync, OrderRefundSync)
    end

Transient C1 errors return `{:error, {:transient, reason}}`; all other C1 errors return `{:error, {:permanent, reason}}`. This lets the existing `handle_supported_event/2` mark retryable events queued or permanent events failed, with no worker change.

- [ ] **Step 3: Run the focused test file and verify GREEN.**

Run:

    mix test test/event_sales/ingestion/webhook_processor_test.exs

Expected: all webhook processor tests pass, including both order topics, ordering, stale-noop convergence, retry behavior, permanent fail-closed behavior, and ignored-event refund protection.

- [ ] **Step 4: Format and compile the directly changed code.**

Run:

    mix format lib/event_sales/ingestion/webhook_processor.ex test/event_sales/ingestion/webhook_processor_test.exs
    mix compile --warnings-as-errors

Expected: both commands exit 0 with no new warnings. If formatting changes test structure, rerun the focused test file.

### Task 3: Verify slice boundaries and final local gates

**Files:**
- Inspect: `lib/event_sales/ingestion/webhook_processor.ex`
- Inspect: `test/event_sales/ingestion/webhook_processor_test.exs`
- Inspect: `lib/event_sales/ingestion/workers/process_webhook_worker.ex`

- [ ] **Step 1: Run the focused regression set.**

Run:

    mix test test/event_sales/ingestion/webhook_processor_test.exs \
      test/event_sales/ingestion/process_webhook_worker_test.exs \
      test/event_sales/ingestion/order_refund_sync_test.exs

Expected: all tests pass and the worker suite remains unchanged.

- [ ] **Step 2: Run the repository fast quality gate.**

Run:

    mix quality.fast

Expected: exit 0. Record any pre-existing warning separately from failures; do not broaden the implementation to unrelated cleanup.

- [ ] **Step 3: Check the architecture boundary and final diff scope.**

Run:

    bash scripts/check_no_web_woocommerce_refs.sh
    git diff --check
    git status --short
    git diff --stat 802271de1d05909e89b257c400952fb79f88d6cd..HEAD

Confirm only the approved C3 implementation/test files plus the committed design and plan documents are changed. Confirm the worker, C1, refund writer, WebhookEvent resource, migrations, and indexes are untouched. Do not merge, open a PR, or mark the branch ready.

- [ ] **Step 4: Commit the implementation as one coherent local checkpoint.**

After the fresh verification commands pass, commit the production and focused test changes with:

    git add lib/event_sales/ingestion/webhook_processor.ex test/event_sales/ingestion/webhook_processor_test.exs
    git commit -m "feat: sync refunds from order webhooks"

Do not push or merge this branch unless the user explicitly requests that separate integration step.


