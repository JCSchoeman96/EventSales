defmodule EventSales.Ingestion.HistoricalRefundOrderItemImpactResolver do
  @moduledoc """
  Resolves read-only Event allocation impact for a captured Refund snapshot.

  The historical Refund mutation detector remains the authority for allocation
  rules. This module exposes those rules for parent OrderItem mutations and
  compares the allocation before and after a write.
  """

  alias EventSales.Ingestion.HistoricalRefundMutationDetector

  @type snapshot :: HistoricalRefundMutationDetector.snapshot()
  @type allocation :: HistoricalRefundMutationDetector.allocation()
  @type impact :: %{changed?: boolean(), candidate_event_ids: [String.t()]}

  @doc """
  Resolves one captured Refund snapshot into its allocation mode and Event IDs.
  """
  @spec resolve(snapshot()) :: allocation()
  def resolve(snapshot) when is_map(snapshot) do
    HistoricalRefundMutationDetector.allocation(snapshot)
  end

  @doc """
  Compares before and after allocation and returns bounded Event candidates.

  `nil` is accepted as the before value for a newly observed Refund.
  """
  @spec compare(nil | snapshot(), snapshot()) :: impact()
  def compare(nil, after_snapshot) when is_map(after_snapshot) do
    %{
      changed?: true,
      candidate_event_ids: resolve(after_snapshot).event_ids
    }
  end

  def compare(before_snapshot, after_snapshot)
      when is_map(before_snapshot) and is_map(after_snapshot) do
    before_allocation = resolve(before_snapshot)
    after_allocation = resolve(after_snapshot)

    changed? = allocation_truth(before_allocation) != allocation_truth(after_allocation)

    %{
      changed?: changed?,
      candidate_event_ids:
        if(changed?, do: candidate_event_ids(before_allocation, after_allocation), else: [])
    }
  end

  defp allocation_truth(allocation) do
    Map.take(allocation, [:allocation_mode, :event_ids])
  end

  defp candidate_event_ids(before_allocation, after_allocation) do
    [before_allocation, after_allocation]
    |> Enum.flat_map(&Map.get(&1, :event_ids, []))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
