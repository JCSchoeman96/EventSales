# M3-05B Refund Persistence and Binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox ( - [ ] ) syntax for tracking.

**Goal:** Build EventSales.Sales.RefundUpserter as the sole transactional writer for source-scoped WooCommerce refund facts, exact parent/line binding, replay convergence, and cumulative ticket-refund quantity safety.

**Architecture:** Parse raw WooCommerce detail before the database boundary. Inside one EventSales.Repo.transaction/1, lock the source-scoped parent Order, existing Refund, and affected OrderItems in deterministic order; use existing Ash actions for persistence and direct read-only Ecto queries only for grouped active-quantity aggregation. Preserve source facts on conflicts and return durable review evidence as {:ok, refund}.

**Tech Stack:** Elixir, Ash 3.31, AshPostgres, Ecto/PostgreSQL row locks, Decimal, ExUnit SQL Sandbox.

---

## File map

- Create lib/event_sales/sales/refund_upserter.ex: public parse/reference/normalized boundaries, validation, lock ordering, source-fact convergence, exact binding, line persistence, and quantity validation.
- Create test/event_sales/sales/refund_upserter_test.exs: focused unit/integration coverage using EventSales.TestSupport.SalesHelpers, Ash reads, and SQL Sandbox concurrency.
- Modify lib/event_sales/sales/resources/refund.ex only if a focused failing test proves an existing action cannot persist the specified state transition.
- Modify lib/event_sales/sales/resources/refund_line.ex only under the same condition.
- No migration, schema, index, worker, webhook, or analytics file is part of this plan.

## Shared implementation contract

Use these stable values in the module and tests:

~~~elixir
@parent_order_not_found "parent_order_not_found"
@order_item_not_found "order_item_not_found"
@parent_order_unavailable "parent_order_not_found"
@malformed_detail "malformed_refund_detail"
@source_detail_conflict "source_detail_conflict"
@over_refund "refunded_quantity_exceeds_original"
@validation_tokens [:product_id_mismatch, :variation_id_mismatch, :refunded_quantity_exceeds_original]
~~~

The public functions accept a UUID source ID, a positive Woo order ID, and a normalized map or raw map. upsert_refund/4 calls WoocommerceRefundParser.parse/1 before any transaction. If parsing fails but the raw id is a positive integer, it calls the normalized persistence path with an unresolved-detail marker and no lines; otherwise it returns {:error, {:invalid_refund_identity, :woo_refund_id}} without writing.

The transaction normalizes Ash results to {:ok, record} and calls EventSales.Repo.rollback(reason) for every persistence/query failure so a failure cannot commit a partial RefundLine set. A unique source-identity create failure is detected by the existing constraint name "sales_refunds_unique_source_order_refund_index"; the outer boundary retries one complete lock/refetch/converge transaction, then returns the original error if the second attempt also fails.

### Task 1: Add the first failing public-API tests

**Files:**

- Create: test/event_sales/sales/refund_upserter_test.exs

- [ ] **Step 1: Add test setup and the smallest reference tests.**

Use EventSales.DataCase with async: false, alias Sales, Refund, RefundLine, Order, OrderItem, RefundUpserter, and SalesHelpers. Add helpers that create a source, create an order from the existing order_completed fixture, and read refunds/lines with deterministic sorting. The first tests should be:

~~~elixir
test "creates one reference-only refund and replays it idempotently", %{source: source} do
  reference = %{woo_refund_id: 91_001, summary_total_amount: Decimal.new("45.00"), reason: "duplicate"}

  assert {:ok, first} = RefundUpserter.upsert_reference(source.id, 10_001, reference)
  assert {:ok, second} = RefundUpserter.upsert_reference(source.id, 10_001, reference)
  assert first.id == second.id
  assert second.detail_status == :reference_only
  assert second.source_state == :active
  assert Ash.count!(Refund, domain: Sales) == 1
end

test "rejects a reference without a positive refund identity", %{source: source} do
  assert {:error, {:invalid_refund_identity, :woo_refund_id}} =
           RefundUpserter.upsert_reference(source.id, 10_001, %{})

  assert Ash.count!(Refund, domain: Sales) == 0
end
~~~

- [ ] **Step 2: Run the new tests and verify the expected RED failure.**

Run:

~~~bash
mix test test/event_sales/sales/refund_upserter_test.exs
~~~

Expected: compilation fails because EventSales.Sales.RefundUpserter does not exist. Do not add production code before recording this failure.

### Task 2: Implement identity validation and reference convergence

**Files:**

- Create: lib/event_sales/sales/refund_upserter.ex

- [ ] **Step 1: Add the public functions and reference transaction.**

Implement these signatures and delegate reference writes through one private transaction function:

~~~elixir
@spec upsert_reference(Ecto.UUID.t(), pos_integer(), map(), keyword()) ::
        {:ok, Refund.t()} | {:error, term()}
def upsert_reference(source_system_id, woo_order_id, normalized_reference, opts \\ [])

@spec upsert_refund(Ecto.UUID.t(), pos_integer(), map(), keyword()) ::
        {:ok, Refund.t()} | {:error, term()}
def upsert_refund(source_system_id, woo_order_id, raw_refund_payload, opts \\ [])

@spec upsert_normalized_refund(Ecto.UUID.t(), pos_integer(), map(), keyword()) ::
        {:ok, Refund.t()} | {:error, term()}
def upsert_normalized_refund(source_system_id, woo_order_id, normalized_refund, opts \\ [])
~~~

Validate source UUID and positive order/refund IDs before calling Ash. The reference path must load the parent with:

~~~elixir
Order
|> Ash.Query.filter(source_system_id == ^source_system_id and woo_order_id == ^woo_order_id)
|> Ash.Query.limit(1)
|> Ash.Query.lock(:for_update)
|> Ash.read_one(domain: Sales)
~~~

Then lock the existing Refund by all three identity fields. Create with :create_reference when absent; otherwise hydrate only nil reference fields, preserve complete detail/voided state, and update the exact parent/currency binding. Clear only the local parent_order_not_found reason after a parent is found; preserve source_detail_conflict.

- [ ] **Step 2: Run the reference tests and verify GREEN.**

Run:

~~~bash
mix test test/event_sales/sales/refund_upserter_test.exs
~~~

Expected: the two reference tests pass. If Ash action return shapes or query locks differ, correct the module while keeping the tests unchanged.

- [ ] **Step 3: Commit the reference slice.**

~~~bash
git add lib/event_sales/sales/refund_upserter.ex test/event_sales/sales/refund_upserter_test.exs
git commit -m "feat: persist refund references"
~~~

### Task 3: Add exact detail, parent binding, line binding, and validation tests

**Files:**

- Modify: test/event_sales/sales/refund_upserter_test.exs

- [ ] **Step 1: Add a normalized detail fixture helper and failing tests.**

Use normalized maps matching the parser output, for example:

~~~elixir
defp normalized_refund(refund_id, line_items \\ []) do
  %{
    woo_refund_id: refund_id,
    header_amount: Decimal.new("45.00"),
    reason: "customer request",
    source_created_at: ~U[2026-05-01 10:00:00Z],
    line_items: line_items,
    shipping_refund_amount: nil,
    shipping_refund_tax: nil,
    fee_refund_amount: nil,
    fee_refund_tax: nil,
    unallocated_header_amount: Decimal.new("45.00")
  }
end

defp refund_line(line_id, refunded_item_id, attrs \\ %{}) do
  Map.merge(%{
    woo_refund_line_item_id: line_id,
    woo_refunded_item_id: refunded_item_id,
    woo_product_id: 501,
    woo_variation_id: 601,
    refunded_quantity: 1,
    refund_subtotal_amount: Decimal.new("40.00"),
    refund_total_amount: Decimal.new("45.00"),
    refund_total_tax: Decimal.new("5.00"),
    binding_reason: nil,
    validation_reason: nil
  }, attrs)
end
~~~

Add tests for exact source-scoped parent binding and currency inheritance; missing parent with detail_status: :complete, nil order_id/currency, and parent_order_not_found; same-row binding after creating the parent later; valid _refunded_item_id binding to the exact parent OrderItem; missing, invalid, and unknown binders remaining nil with reasons; product/variation mismatch retaining the exact OrderItem and stable pipe-delimited warning; cross-source parent and global line IDs never binding; and a positive header with no lines creating zero RefundLines.

Run the new tests to confirm they fail because normalized persistence and binding are not implemented.

- [ ] **Step 2: Implement exact parent and batched line resolution.**

Add private helpers with these responsibilities:

~~~elixir
lock_parent_order(source_system_id, woo_order_id)
lock_refund(source_system_id, woo_order_id, woo_refund_id)
lock_order_items(order_id, positive_line_ids)
resolve_line_bindings(parent_order, incoming_lines, locked_items)
validation_tokens(line, bound_order_item, over_refund?)
~~~

Collect unique positive woo_refunded_item_id values first. Query all matching OrderItems once with order_id == ^parent_order.id and woo_line_item_id in ^ids, sort ascending by woo_line_item_id, and apply Ash.Query.lock(query, :for_update). Do not query by product, variation, SKU, name, or global line ID. Preserve any parser-provided binding_reason; set order_item_not_found only for a valid binder missing under the exact parent. If the parent is absent, leave the line unbound and use parent_order_not_found as its derived binding reason.

Compare optional source product/variation values only after exact binding. Build the warning vocabulary from the fixed token order product_id_mismatch, variation_id_mismatch, refunded_quantity_exceeds_original, then join present tokens with |.

- [ ] **Step 3: Implement normalized Refund/RefundLine persistence.**

For a new refund, create with :create_normalized, detail_status: :complete, active source state, parent/currency when available, and all normalized header financial fields. For an existing reference or malformed-detail row, update through :sync_normalized only after source-fact convergence permits it. For each incoming line, create or update by (refund_id, woo_refund_line_item_id) using :create_normalized/:sync_normalized; never delete lines. Do not set source_state: :active on an existing voided record.

- [ ] **Step 4: Run the binding/detail tests and verify GREEN.**

~~~bash
mix test test/event_sales/sales/refund_upserter_test.exs
~~~

Expected: all reference, parent, line, validation, and value-only tests pass.

- [ ] **Step 5: Commit the exact detail slice.**

~~~bash
git add lib/event_sales/sales/refund_upserter.ex test/event_sales/sales/refund_upserter_test.exs
git commit -m "feat: bind exact refund detail"
~~~

### Task 4: Add replay, enrichment, conflict, and void tests

**Files:**

- Modify: test/event_sales/sales/refund_upserter_test.exs

- [ ] **Step 1: Add failing replay tests.**

Cover exact duplicate replay with one Refund and one line set; nil-to-known hydration for summary, reason, source timestamp, optional source product, variation, quantity, and money; known source values never being cleared; known source changes marking the Refund unresolved with source_detail_conflict while preserving prior header/line financial facts; an established line-ID set changing without deleting/replacing lines; malformed raw detail with a valid positive ID creating one unresolved Refund and no lines; a later valid detail hydrating that malformed row; and a voided refund remaining voided after reference or exact replay.

Use assertions against fresh Ash.get!/Ash.read! results rather than relying only on returned structs, so the tests prove durable convergence.

- [ ] **Step 2: Implement monotonic source-fact comparison.**

Add a helper that compares each source field using Decimal.equal?/2 for Decimal values, DateTime.compare/2 for timestamps, and exact equality for integers/strings/atoms:

~~~elixir
defp merge_source_field(existing, incoming) do
  cond do
    is_nil(existing) -> {:ok, incoming}
    is_nil(incoming) -> {:conflict, existing}
    source_values_equal?(existing, incoming) -> {:ok, existing}
    true -> {:conflict, existing}
  end
end
~~~

Use it for authoritative Refund financial/source fields and RefundLine source facts. On a conflict, do not call an update/create for the conflicting source facts. Keep existing lines and financial values, set detail_status: :unresolved and unresolved_reason: "source_detail_conflict", and return {:ok, refund}. Treat a malformed unresolved row with no established exact facts as hydratable; do not hydrate a row already marked with source_detail_conflict.

Track whether an exact line set is established by existing RefundLine rows plus an existing complete detail row: an existing complete empty set conflicts with an incoming non-empty set, while a reference-only or malformed row with no exact lines can accept its first valid detail.

- [ ] **Step 3: Implement bounded unique-create convergence.**

Wrap the transaction in one attempt counter. On a unique source identity constraint error from a no-parent create, discard the failed transaction and retry exactly once through the normal locked lookup path. Do not sleep, loop, lock SourceSystem, or use advisory/Redis/GenServer state.

- [ ] **Step 4: Run replay/conflict tests and commit.**

~~~bash
mix test test/event_sales/sales/refund_upserter_test.exs
git add lib/event_sales/sales/refund_upserter.ex test/event_sales/sales/refund_upserter_test.exs
git commit -m "feat: converge refund replays safely"
~~~

Expected: all focused replay tests pass and git diff --check is clean.

### Task 5: Add quantity-safety tests and implement grouped locked aggregation

**Files:**

- Modify: test/event_sales/sales/refund_upserter_test.exs

- [ ] **Step 1: Add failing quantity tests.**

Create a mapped ticket OrderItem with a known original quantity and assert:

- one partial refund within quantity persists unchanged;
- distinct partial refunds accumulate;
- cumulative equality passes;
- replaying the same refund does not double-count it;
- money changes do not affect quantity math;
- an over-refund retains full incoming quantity and exact order_item_id, leaves OrderItem.quantity unchanged, and adds refunded_quantity_exceeds_original;
- a voided prior RefundLine is excluded from the active sum;
- non-ticket bound lines do not participate in ticket quantity safety.

Use Decimal assertions for money and integer assertions for quantity to prove the two dimensions remain independent.

- [ ] **Step 2: Implement deterministic OrderItem locks and one grouped sum.**

After locking the parent and Refund, collect all bound incoming lines with refunded_quantity > 0. Lock matching OrderItems once, sorted by ascending woo_line_item_id. Query active historical quantities in one grouped Ecto query, excluding the current Refund:

~~~elixir
from(line in "sales_refund_lines",
  join: refund in "sales_refunds",
  on: refund.id == line.refund_id,
  where:
    line.order_item_id in ^order_item_ids and
      refund.source_state == "active" and refund.id != ^refund_id,
  group_by: line.order_item_id,
  select: {line.order_item_id, coalesce(sum(line.refunded_quantity), 0)}
)
~~~

Aggregate current incoming quantities by order_item_id. For each locked OrderItem where item_kind == :ticket, compare historical plus current quantity to OrderItem.quantity. Pass the boolean overage into the line validation-token builder. Never clamp, drop, unbind, or mutate the OrderItem.

- [ ] **Step 3: Run the quantity tests and commit.**

~~~bash
mix test test/event_sales/sales/refund_upserter_test.exs
git add lib/event_sales/sales/refund_upserter.ex test/event_sales/sales/refund_upserter_test.exs
git commit -m "feat: validate cumulative refund quantities"
~~~

### Task 6: Add concurrency and rollback coverage

**Files:**

- Modify: test/event_sales/sales/refund_upserter_test.exs

- [ ] **Step 1: Add concurrent duplicate and distinct-refund tests.**

Use async: false, capture the setup owner with parent = self(), and allow each task through Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self()). Run duplicate normalized writes with Task.async_stream/3 and assert one Refund, one line per source identity, and one quantity contribution. Run two distinct Refund IDs against one ticket OrderItem with a source quantity that exceeds the original; assert both Refunds survive, neither quantity is clamped, and at least the transaction that observes the cumulative overage stores the over-refund token. Await all tasks and assert no deadlock or task timeout.

- [ ] **Step 2: Add malformed-identity and transaction-failure tests.**

Assert invalid source/refund identity writes no rows. For a controlled write failure, pass an intentionally invalid normalized line attribute through the public normalized boundary and assert the transaction returns {:error, _} with no RefundLine rows committed for that Refund. Keep the test on the real Ash/Postgres path; do not mock the repository.

- [ ] **Step 3: Implement test-only failure injection only if required by the existing options contract.**

If a deterministic rollback test needs a hook, add a private option such as before_line_write: fun consumed only inside the module and invoke it before the first line write. The hook must default to absent, must not change runtime behavior, and must not be exposed as a production integration. Do not add a new resource action or schema field solely for testing.

- [ ] **Step 4: Run focused concurrency tests and commit.**

~~~bash
mix test test/event_sales/sales/refund_upserter_test.exs
git diff --check
git add lib/event_sales/sales/refund_upserter.ex test/event_sales/sales/refund_upserter_test.exs
git commit -m "test: prove refund upsert concurrency"
~~~

### Task 7: Refactor, inspect scope, and run repository gates

**Files:**

- Modify only the files listed in the file map unless a failing quality gate identifies a directly necessary resource-action change.

- [ ] **Step 1: Format and compile the focused implementation.**

~~~bash
mix format
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/event_sales/sales/refund_upserter_test.exs
~~~

Expected: formatting, compilation, and the complete focused suite exit 0.

- [ ] **Step 2: Run repository structural and quality checks.**

~~~bash
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
~~~

Expected: no generated schema changes, no boundary violations, and zero failures. If Ash codegen requests a migration or a missing index, stop and report SCHEMA_GAP instead of creating one.

- [ ] **Step 3: Inspect final scope and commit any quality-only corrections.**

~~~bash
git status --short
git diff --stat
git diff --name-only main...HEAD
git diff main...HEAD -- lib/event_sales/sales/refund_upserter.ex test/event_sales/sales/refund_upserter_test.exs
~~~

Confirm that no worker, HTTP client, webhook, OrderUpserter, analytics, Redis/ETS, migration, or Path 2 file changed. Commit only any required quality corrections with a focused message.

- [ ] **Step 4: Request review before publishing.**

Review the final branch against baseline a9e668361efbbfc77ecb1eff94b19c551ea8a9cb, verify the focused and full test evidence, and request a code review. Fix all critical/important findings before pushing.

- [ ] **Step 5: Push and open exactly one draft PR.**

~~~bash
git push -u origin path1/m3-05b-refund-upserter-binding
gh pr create --draft --base main --head path1/m3-05b-refund-upserter-binding --title "Path 1 M3-05B: persist and bind exact refund facts" --body-file /tmp/m3-05b-pr-body.md
~~~

The PR body must report the exact baseline/head SHAs, public API, transaction and lock order, replay/conflict behavior, quantity behavior, test/gate output, and every non-goal as NOT IMPLEMENTED. Do not mark the PR ready and do not merge.
