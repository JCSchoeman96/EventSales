# M3-08D2A — Order Coverage Invalidation Authority Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

Goal: Add a bounded HistoricalCoverageInvalidator that invalidates only current Event certificates whose inclusive sales coverage contains a proven-mutated Order.

Architecture: Validate the durable Order and every candidate UUID before writing, normalize and deduplicate candidates in input order, then process each candidate sequentially through HistoricalCoverageResolver.resolve_current/1. Source mismatch and authority/persistence failures return stable errors; only no-current and outside-B→C conditions become explicit skips. In-scope candidates invoke the existing SyncRun :invalidate_order_coverage action exactly once.

Tech Stack: Elixir 1.19, Ash 3.x, AshPostgres, PostgreSQL-backed EventSales.DataCase, ExUnit, HistoricalCoverageResolver, and SyncRun.

---

## File map

- Create test/event_sales/ingestion/historical_coverage_invalidator_test.exs with durable Ash/Postgres fixtures proving the result contract, source guard, inclusive boundaries, deterministic dedupe, audit preservation, and replay behavior.
- Create lib/event_sales/ingestion/historical_coverage_invalidator.ex with the public API, UUID normalization, sequential resolver-driven decision loop, inclusive B→C predicate, and exact SyncRun invalidation action.
- Regenerate the repository's deterministic project-index documentation after adding the module; this is documentation only and does not add a database index.
- Do not modify Order, OrderItem, SyncRun, HistoricalCoverageResolver, OrderUpserter, WebhookProcessor, migrations, resource snapshots, or dependency declarations.

The worktree has no private dependency checkout, so commands below reuse the verified root dependency/build caches with MIX_DEPS_PATH and MIX_BUILD_PATH; this does not change tracked source or dependency declarations.

## Task 1: Write and run the failing focused tests

Files:

- Create: test/event_sales/ingestion/historical_coverage_invalidator_test.exs

- [x] Step 1: Add the complete contract test module before production code.

Create the test file with the following tests and local durable fixture helpers:

~~~elixir
defmodule EventSales.Ingestion.HistoricalCoverageInvalidatorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageInvalidator
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Sales
  alias EventSales.Sales.Resources.Order
  alias EventSales.TestSupport.SalesHelpers

  @coverage_start ~U[2026-08-01 08:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @within_sales_scope ~U[2026-08-05 12:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "rejects an invalid Order before resolving candidates", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Invalid Order Event"})
    _run = certified_run!(event)
    invalid_order = %Order{source_system_id: source.id, created_at_source: nil}

    assert {:error, :invalid_order} =
             HistoricalCoverageInvalidator.invalidate_order_change(invalid_order, [event.id])

    assert {:ok, _current} = HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "rejects malformed Event IDs before making any invalidation write", %{
    source: source
  } do
    event = SalesHelpers.create_event!(source, %{name: "Malformed Candidate Event"})
    run = certified_run!(event)
    order = create_order!(source, @within_sales_scope)

    assert {:error, :invalid_event_id} =
             HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id, "bad-id"])

    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  test "skips an Event with no current historical coverage", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Uncertified Event"})
    order = create_order!(source, @within_sales_scope)

    assert {:ok,
            %{
              invalidated_event_ids: [],
              skipped: [%{event_id: event_id, reason: :no_current_coverage}]
            }} = HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id])

    assert event_id == event.id
  end

  test "deduplicates candidates and preserves deterministic result order", %{source: source} do
    no_current = SalesHelpers.create_event!(source, %{name: "No Current Event"})

    outside = SalesHelpers.create_event!(source, %{name: "Outside Event"})

    outside_run =
      certified_run!(outside, %{
        sales_covered_through: DateTime.add(@within_sales_scope, -1, :second)
      })

    inside = SalesHelpers.create_event!(source, %{name: "Inside Event"})
    inside_run = certified_run!(inside)
    order = create_order!(source, @within_sales_scope, DateTime.add(@sales_covered_through, 1, :day))

    assert {:ok,
            %{
              invalidated_event_ids: [invalidated_id],
              skipped: [
                %{event_id: skipped_no_current_id, reason: :no_current_coverage},
                %{event_id: skipped_outside_id, reason: :outside_sales_coverage}
              ]
            }} =
             HistoricalCoverageInvalidator.invalidate_order_change(order, [
               no_current.id,
               outside.id,
               inside.id,
               no_current.id,
               inside.id
             ])

    assert invalidated_id == inside.id
    assert skipped_no_current_id == no_current.id
    assert skipped_outside_id == outside.id
    assert outside_run.id != inside_run.id
    assert {:ok, _current} = HistoricalCoverageResolver.resolve_current(outside.id)
    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(inside.id)
  end

  test "skips Orders before B and after C", %{source: source} do
    before_event = SalesHelpers.create_event!(source, %{name: "Before B Event"})
    _before_run = certified_run!(before_event)
    before_order = create_order!(source, DateTime.add(@coverage_start, -1, :second))

    assert {:ok, %{invalidated_event_ids: [], skipped: [%{reason: :outside_sales_coverage}]}} =
             HistoricalCoverageInvalidator.invalidate_order_change(before_order, [before_event.id])

    after_event = SalesHelpers.create_event!(source, %{name: "After C Event"})
    _after_run = certified_run!(after_event)
    after_order = create_order!(source, DateTime.add(@sales_covered_through, 1, :second))

    assert {:ok, %{invalidated_event_ids: [], skipped: [%{reason: :outside_sales_coverage}]}} =
             HistoricalCoverageInvalidator.invalidate_order_change(after_order, [after_event.id])
  end

  test "treats both B and C as inclusive and ignores updated/refund/certification times", %{
    source: source
  } do
    for created_at_source <- [@coverage_start, @sales_covered_through] do
      event = SalesHelpers.create_event!(source, %{name: "Inclusive Event"})

      run =
        certified_run!(event, %{
          refunds_covered_through: @coverage_start
        })

      order =
        create_order!(
          source,
          created_at_source,
          DateTime.add(@sales_covered_through, 1, :day)
        )

      assert {:ok, %{invalidated_event_ids: [event_id], skipped: []}} =
               HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id])

      assert event_id == event.id
      assert {:error, :historical_coverage_not_current} =
               HistoricalCoverageResolver.resolve_current(event.id)

      invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
      assert invalidated.coverage_start == @coverage_start
      assert invalidated.sales_covered_through == @sales_covered_through
      assert invalidated.refunds_covered_through == @coverage_start
      assert %DateTime{} = invalidated.coverage_certified_at
    end
  end

  test "fails closed when the Order and certificate have different source systems", %{
    source: source
  } do
    other_source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(other_source, %{name: "Foreign Source Event"})
    run = certified_run!(event)
    order = create_order!(source, @within_sales_scope)

    assert {:error, :coverage_source_mismatch} =
             HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id])

    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  test "invalidates the exact certificate and replay becomes no current coverage", %{
    source: source
  } do
    event = SalesHelpers.create_event!(source, %{name: "Replay Event"})
    run = certified_run!(event)
    order = create_order!(source, @within_sales_scope)

    assert {:ok, %{invalidated_event_ids: [event.id], skipped: []}} =
             HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id])

    invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert invalidated.order_coverage_status == :incomplete
    assert invalidated.refund_coverage_status == :incomplete
    assert invalidated.coverage_invalidation_reason == :historical_order_changed
    assert %DateTime{} = invalidated.coverage_invalidated_at
    assert invalidated.coverage_start == run.coverage_start
    assert invalidated.sales_covered_through == run.sales_covered_through
    assert invalidated.refunds_covered_through == run.refunds_covered_through
    assert invalidated.coverage_certified_at == run.coverage_certified_at

    assert {:ok,
            %{
              invalidated_event_ids: [],
              skipped: [%{event_id: event.id, reason: :no_current_coverage}]
            }} = HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id])
  end

  defp certified_run!(event, attrs \\ %{}) do
    coverage =
      Map.merge(
        %{
          coverage_start: @coverage_start,
          sales_covered_through: @sales_covered_through,
          refunds_covered_through: @sales_covered_through
        },
        attrs
      )

    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: coverage.sales_covered_through
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, event.source_system_id)
    |> Ash.Changeset.force_change_attribute(:date_from, coverage.coverage_start)
    |> Ash.create!(domain: Ingestion)
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
    |> Ash.update!(coverage, action: :record_coverage_certification, domain: Ingestion)
    |> Ash.update!(%{}, action: :complete, domain: Ingestion)
  end

  defp create_order!(source, created_at_source),
    do: create_order!(source, created_at_source, created_at_source)

  defp create_order!(source, created_at_source, updated_at_source) do
    Ash.create!(
      Order,
      %{
        source_system_id: source.id,
        woo_order_id: System.unique_integer([:positive]),
        status: :completed,
        currency: "ZAR",
        created_at_source: created_at_source,
        updated_at_source: updated_at_source,
        raw_total: Decimal.new("100.00")
      },
      action: :create_normalized,
      domain: Sales
    )
  end
end
~~~

- [x] Step 2: Run the focused test and verify the red failure is the missing service.

Run:

~~~bash
MIX_DEPS_PATH=/home/jcschoeman96/projects/current/EventSales/deps \
MIX_BUILD_PATH=/home/jcschoeman96/projects/current/EventSales/_build \
mix test test/event_sales/ingestion/historical_coverage_invalidator_test.exs
~~~

Expected: FAIL because EventSales.Ingestion.HistoricalCoverageInvalidator has not been defined. Do not add production code until this failure is observed.

## Task 2: Implement the minimal resolver-driven invalidator

Files:

- Create: lib/event_sales/ingestion/historical_coverage_invalidator.ex

- [x] Step 1: Add the minimal production implementation.

Create the module with the exact result/error vocabulary and no optional adapters, callbacks, caches, transactions, or external calls:

~~~elixir
defmodule EventSales.Ingestion.HistoricalCoverageInvalidator do
  @moduledoc """
  Invalidates current historical coverage for bounded, proven Order changes.

  The caller proves that the Order changed and supplies candidate Event IDs.
  This module only evaluates current certificates against the Order's
  original source creation timestamp.
  """

  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Sales.Resources.Order

  @type skip_reason :: :no_current_coverage | :outside_sales_coverage
  @type result :: %{
          invalidated_event_ids: [String.t()],
          skipped: [%{event_id: String.t(), reason: skip_reason()}]
        }
  @type error_reason ::
          :invalid_order
          | :invalid_event_id
          | :historical_coverage_lookup_failed
          | :coverage_source_mismatch
          | :order_coverage_invalidation_failed

  @spec invalidate_order_change(term(), term()) ::
          {:ok, result()} | {:error, error_reason()}
  def invalidate_order_change(order, event_ids) do
    with :ok <- validate_order(order),
         {:ok, normalized_event_ids} <- normalize_event_ids(event_ids) do
      process_candidates(order, normalized_event_ids)
    end
  end

  defp validate_order(%Order{
         source_system_id: source_system_id,
         created_at_source: %DateTime{}
       }) do
    case Ecto.UUID.cast(source_system_id) do
      {:ok, _canonical_source_system_id} -> :ok
      :error -> {:error, :invalid_order}
    end
  end

  defp validate_order(_order), do: {:error, :invalid_order}

  defp normalize_event_ids(event_ids) when is_list(event_ids) do
    event_ids
    |> Enum.reduce_while({:ok, {MapSet.new(), []}}, fn event_id,
                                                         {:ok, {seen, normalized}} ->
      case Ecto.UUID.cast(event_id) do
        {:ok, canonical_event_id} ->
          {next_seen, next_normalized} =
            deduplicate_event_id(seen, normalized, canonical_event_id)

          {:cont, {:ok, {next_seen, next_normalized}}}

        :error ->
          {:halt, {:error, :invalid_event_id}}
      end
    end)
    |> case do
      {:ok, {_seen, normalized}} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_event_ids(_event_ids), do: {:error, :invalid_event_id}

  defp deduplicate_event_id(seen, normalized, canonical_event_id) do
    case MapSet.member?(seen, canonical_event_id) do
      true ->
        {seen, normalized}

      false ->
        {MapSet.put(seen, canonical_event_id), [canonical_event_id | normalized]}
    end
  end

  defp process_candidates(order, event_ids) do
    case Enum.reduce_while(event_ids, {:ok, {[], []}}, fn event_id,
                                                         {:ok, {invalidated, skipped}} ->
           process_candidate(order, event_id, invalidated, skipped)
         end) do
      {:ok, {invalidated, skipped}} ->
        {:ok,
         %{
           invalidated_event_ids: Enum.reverse(invalidated),
           skipped: Enum.reverse(skipped)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_candidate(order, event_id, invalidated, skipped) do
    case HistoricalCoverageResolver.resolve_current(event_id) do
      {:error, :historical_coverage_not_current} ->
        {:cont,
         {:ok,
          {invalidated, [%{event_id: event_id, reason: :no_current_coverage} | skipped]}}}

      {:error, reason} ->
        {:halt, {:error, reason}}

      {:ok, %SyncRun{} = certificate} ->
        process_current_certificate(order, event_id, certificate, invalidated, skipped)
    end
  end

  defp process_current_certificate(
         %Order{} = order,
         event_id,
         %SyncRun{} = certificate,
         invalidated,
         skipped
       ) do
    cond do
      order.source_system_id != certificate.source_system_id ->
        {:halt, {:error, :coverage_source_mismatch}}

      order_in_sales_scope?(order, certificate) ->
        case invalidate_certificate(certificate) do
          :ok -> {:cont, {:ok, {[event_id | invalidated], skipped}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      true ->
        {:cont,
         {:ok,
          {invalidated, [%{event_id: event_id, reason: :outside_sales_coverage} | skipped]}}}
    end
  end

  defp order_in_sales_scope?(
         %Order{created_at_source: %DateTime{} = created_at_source},
         %SyncRun{
           coverage_start: %DateTime{} = coverage_start,
           sales_covered_through: %DateTime{} = sales_covered_through
         }
       ) do
    DateTime.compare(created_at_source, coverage_start) in [:eq, :gt] and
      DateTime.compare(created_at_source, sales_covered_through) in [:eq, :lt]
  end

  defp order_in_sales_scope?(_order, _certificate), do: false

  defp invalidate_certificate(%SyncRun{} = certificate) do
    case Ash.update(
           certificate,
           %{coverage_invalidation_reason: :historical_order_changed},
           action: :invalidate_order_coverage,
           domain: Ingestion
         ) do
      {:ok, %SyncRun{}} -> :ok
      {:ok, %SyncRun{}, _notifications} -> :ok
      _other -> {:error, :order_coverage_invalidation_failed}
    end
  rescue
    _error -> {:error, :order_coverage_invalidation_failed}
  catch
    :exit, _reason -> {:error, :order_coverage_invalidation_failed}
    :throw, _value -> {:error, :order_coverage_invalidation_failed}
  end
end
~~~

- [x] Step 2: Run the focused tests and verify the green result.

Run:

~~~bash
MIX_DEPS_PATH=/home/jcschoeman96/projects/current/EventSales/deps \
MIX_BUILD_PATH=/home/jcschoeman96/projects/current/EventSales/_build \
mix test test/event_sales/ingestion/historical_coverage_invalidator_test.exs
~~~

Expected: all D2A tests pass with zero failures. If a test fails, inspect the actual failure and adjust the implementation, not the contract test.

- [x] Step 3: Format the new files and rerun the focused suite.

Run:

~~~bash
MIX_DEPS_PATH=/home/jcschoeman96/projects/current/EventSales/deps \
MIX_BUILD_PATH=/home/jcschoeman96/projects/current/EventSales/_build \
mix format lib/event_sales/ingestion/historical_coverage_invalidator.ex \
  test/event_sales/ingestion/historical_coverage_invalidator_test.exs
MIX_DEPS_PATH=/home/jcschoeman96/projects/current/EventSales/deps \
MIX_BUILD_PATH=/home/jcschoeman96/projects/current/EventSales/_build \
mix test test/event_sales/ingestion/historical_coverage_invalidator_test.exs
~~~

Expected: the formatter changes only the two D2A files and the focused suite still passes with zero failures.

## Task 3: Verify boundaries, quality, and commit the implementation

Files:

- Verify: lib/event_sales/ingestion/historical_coverage_invalidator.ex
- Verify: test/event_sales/ingestion/historical_coverage_invalidator_test.exs
- Verify: no migration, resource snapshot, or unrelated file changes

- [x] Step 1: Inspect the diff and structural scope.

Run:

~~~bash
git diff --check
git status --short
git diff --stat
git diff -- lib/event_sales/ingestion/historical_coverage_invalidator.ex \
  test/event_sales/ingestion/historical_coverage_invalidator_test.exs
~~~

Expected: only the new service, focused test, and generated project-index documentation are uncommitted after the design commit; no OrderUpserter, OrderItem, Refund, SyncRun, migration, or resource snapshot changes appear.

- [x] Step 2: Run focused compilation and the full fast quality gate.

Run:

~~~bash
MIX_DEPS_PATH=/home/jcschoeman96/projects/current/EventSales/deps \
MIX_BUILD_PATH=/home/jcschoeman96/projects/current/EventSales/_build \
mix compile --warnings-as-errors
MIX_DEPS_PATH=/home/jcschoeman96/projects/current/EventSales/deps \
MIX_BUILD_PATH=/home/jcschoeman96/projects/current/EventSales/_build \
mix quality.fast
~~~

Expected: compilation succeeds without warnings, the focused tests and all quality.fast checks pass, and the architecture boundary script reports no new WooCommerce references.

- [x] Step 3: Commit the implementation as one coherent checkpoint.

Run:

~~~bash
git add lib/event_sales/ingestion/historical_coverage_invalidator.ex \
  test/event_sales/ingestion/historical_coverage_invalidator_test.exs
git commit -m "feat: invalidate historical order coverage by event"
~~~

Expected: a new local implementation commit contains only D2A production code and its focused tests. Do not merge, begin D2B, or integrate with OrderUpserter.

## Plan self-review

- The exact module/API, two skip reasons, five stable errors, UUID normalization/deduplication, sequential resolver authority, exact source check, inclusive B→C predicate, and exact invalidation action are covered.
- The plan has no new database index, schema, resource, dependency, HTTP, cache, Oban, PubSub, refund, mutation-detection, or D2B work; the project-index refresh is generated documentation only.
- All code names and paths are consistent between the tests and implementation.
- The only expected implementation error paths not directly induced by the durable fixture tests are resolver database failures and unexpected Ash write failures; the production module maps both to the frozen stable error vocabulary without adding test-only injection options.
