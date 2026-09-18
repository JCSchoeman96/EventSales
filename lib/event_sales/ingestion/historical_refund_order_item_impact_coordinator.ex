defmodule EventSales.Ingestion.HistoricalRefundOrderItemImpactCoordinator do
  @moduledoc """
  Coordinates bounded Refund allocation evidence around parent OrderItem writes.

  The parent Order lock is owned by the caller. This module reads every Refund
  on that parent in deterministic order, delegates allocation semantics to the
  shared resolver, and invokes D3B while the caller's transaction is still
  open.
  """

  require Ash.Query

  alias EventSales.Ingestion.HistoricalCoverageFence
  alias EventSales.Ingestion.HistoricalRefundCoverageInvalidator
  alias EventSales.Ingestion.HistoricalRefundMutationDetector
  alias EventSales.Ingestion.HistoricalRefundOrderItemImpactResolver
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, Refund}

  @type snapshot :: HistoricalRefundMutationDetector.snapshot()
  @type changed_refund :: %{
          required(:refund_id) => Ecto.UUID.t(),
          required(:before_snapshot) => snapshot() | nil,
          required(:after_snapshot) => snapshot(),
          required(:event_ids) => [Ecto.UUID.t()]
        }

  @doc """
  Captures allocation evidence for every Refund belonging to one parent Order.

  The query is bounded by `order_id` and sorted by Refund UUID so callers can
  process multiple Refunds deterministically.
  """
  @spec capture_for_order(Order.t()) :: {:ok, [snapshot()]} | {:error, term()}
  def capture_for_order(%Order{
        id: order_id,
        source_system_id: source_system_id,
        woo_order_id: woo_order_id
      }) do
    Refund
    |> Ash.Query.filter(
      order_id == ^order_id or
        (source_system_id == ^source_system_id and woo_order_id == ^woo_order_id)
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read(domain: Sales)
    |> capture_refunds()
  end

  defp capture_refunds({:ok, refunds}) do
    Enum.reduce_while(refunds, {:ok, []}, fn refund, {:ok, snapshots} ->
      case HistoricalRefundMutationDetector.capture(refund) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | snapshots]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp capture_refunds({:error, reason}), do: {:error, reason}

  @doc """
  Compares BEFORE and AFTER Refund allocation captures.

  Returned changes are ordered by Refund UUID and carry the sorted union of
  Event IDs needed by D3B.
  """
  @spec compare([snapshot()], [snapshot()]) :: [changed_refund()]
  def compare(before_snapshots, after_snapshots)
      when is_list(before_snapshots) and is_list(after_snapshots) do
    before_by_id = Map.new(before_snapshots, &{refund_id(&1), &1})
    after_by_id = Map.new(after_snapshots, &{refund_id(&1), &1})

    before_by_id
    |> Map.keys()
    |> Kernel.++(Map.keys(after_by_id))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn refund_id ->
      before_snapshot = Map.get(before_by_id, refund_id)
      after_snapshot = Map.get(after_by_id, refund_id)

      case {before_snapshot, after_snapshot} do
        {before, after_snapshot} when is_map(before) and is_map(after_snapshot) ->
          impact = HistoricalRefundOrderItemImpactResolver.compare(before, after_snapshot)

          if impact.changed? do
            [changed_refund(refund_id, before, after_snapshot, impact.candidate_event_ids)]
          else
            []
          end

        {nil, after_snapshot} when is_map(after_snapshot) ->
          impact = HistoricalRefundOrderItemImpactResolver.compare(nil, after_snapshot)
          [changed_refund(refund_id, nil, after_snapshot, impact.candidate_event_ids)]

        {_before, nil} ->
          []
      end
    end)
  end

  defp changed_refund(refund_id, before_snapshot, after_snapshot, event_ids) do
    %{
      refund_id: refund_id,
      before_snapshot: before_snapshot,
      after_snapshot: after_snapshot,
      event_ids: normalize_event_ids(event_ids)
    }
  end

  @doc """
  Invalidates all changed Refund allocations inside the caller's transaction.

  The complete Event union is fenced before any D3B call. D3B is then invoked
  in Refund UUID order, using the existing invalidator and no new lock system.
  """
  @spec invalidate_changes([changed_refund()], keyword()) :: :ok | {:error, term()}
  def invalidate_changes(changes, opts \\ []) when is_list(changes) do
    changes = Enum.sort_by(changes, &Map.get(&1, :refund_id))

    event_ids =
      changes
      |> Enum.flat_map(&Map.get(&1, :event_ids, []))
      |> Kernel.++(Keyword.get(opts, :additional_event_ids, []))
      |> normalize_event_ids()

    with :ok <- HistoricalCoverageFence.acquire(event_ids) do
      invalidator =
        Keyword.get(
          opts,
          :historical_refund_coverage_invalidator,
          &HistoricalRefundCoverageInvalidator.invalidate_refund_change/3
        )

      Enum.reduce_while(changes, :ok, fn change, :ok ->
        case call_invalidator(invalidator, change) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp call_invalidator(invalidator, %{
         before_snapshot: before_snapshot,
         after_snapshot: after_snapshot,
         event_ids: event_ids
       })
       when is_function(invalidator, 3) do
    case invalidator.(before_snapshot, after_snapshot, event_ids) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_historical_refund_coverage_invalidator_result, other}}
    end
  end

  defp call_invalidator(_invalidator, _change),
    do: {:error, :invalid_historical_refund_coverage_invalidator}

  defp refund_id(%{refund_truth: %{id: id}}), do: id

  defp refund_id(_snapshot),
    do: raise(ArgumentError, "refund allocation snapshot is missing refund_truth.id")

  defp normalize_event_ids(event_ids) do
    event_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
