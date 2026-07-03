defmodule EventSales.Maintenance.ObanQueueSnapshotWorker do
  @moduledoc """
  Emits grouped Oban queue depth snapshots for launch observability.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [
      period: 60,
      fields: [:worker],
      states: ~w(available scheduled executing retryable)a
    ]

  import Ecto.Query
  require Logger

  alias EventSales.Repo
  alias EventSales.Telemetry

  @tracked_queues ~w(webhooks reconciliation tickera_sync tickera_reconciliation csv_imports maintenance default)
  @tracked_states ~w(available executing retryable scheduled)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    started_at = System.monotonic_time()

    counts = grouped_counts()

    Enum.each(counts, fn {{queue, state}, count} ->
      Telemetry.emit(
        Telemetry.oban_queue_snapshot(),
        %{count: count},
        %{queue: queue, state: state}
      )
    end)

    webhooks_available = Map.get(counts, {"webhooks", "available"}, 0)
    threshold = webhook_backlog_threshold()

    if webhooks_available > threshold do
      Logger.warning(
        "oban_webhook_queue_backlog queue=webhooks state=available count=#{webhooks_available} threshold=#{threshold}"
      )
    end

    Telemetry.emit(
      Telemetry.oban_queue_snapshot(),
      %{count: map_size(counts), duration: System.monotonic_time() - started_at},
      %{
        worker: :oban_queue_snapshot_worker,
        webhooks_available: webhooks_available,
        threshold: threshold,
        reason: backlog_reason(webhooks_available, threshold)
      }
    )

    :ok
  end

  defp grouped_counts do
    from(j in Oban.Job,
      where: j.queue in ^@tracked_queues and j.state in ^@tracked_states,
      group_by: [j.queue, j.state],
      select: {{j.queue, j.state}, count(j.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp webhook_backlog_threshold do
    :event_sales
    |> Application.get_env(:maintenance, [])
    |> Keyword.get(:webhook_queue_backlog_threshold, 100)
  end

  defp backlog_reason(count, threshold) when count > threshold, do: :threshold_exceeded
  defp backlog_reason(_count, _threshold), do: :below_threshold
end
