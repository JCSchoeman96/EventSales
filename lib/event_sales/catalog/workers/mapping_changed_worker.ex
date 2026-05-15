defmodule EventSales.Catalog.Workers.MappingChangedWorker do
  @moduledoc """
  Minimal Slice 3.0 guardrail worker for mapping-change recalculation enqueue.

  `perform/1` is intentionally a no-op. Slice 9.x (`RebuildHotStateWorker` /
  `HotStateAggregator`) owns real hot-state rebuild behavior.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => _event_id}}), do: :ok
end
