defmodule EventSales.Ingestion.CatalogChangeDispatch do
  @moduledoc "Generation-aware exact-target dispatch orchestration."
  require Ash.Query
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{CatalogChangePendingTarget, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.TickeraCatalogSync

  @active [:queued, :discovering, :retry_scheduled, :dry_run_ready, :applying]

  def perform(source_system_id) do
    if enabled?() do
      case next_target(source_system_id) do
        nil -> :ok
        target -> dispatch(target)
      end
    else
      :ok
    end
  end

  defp dispatch(%{catalog_sync_run_id: run_id} = target) when not is_nil(run_id) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %{status: :dry_run_ready}} when target.generation == target.dispatched_generation ->
        update(target, %{state: :preview_ready, recheck_at: nil})
        :ok

      {:ok, %{status: status}} when status in @active ->
        update(target, %{
          state:
            if(target.generation > target.dispatched_generation, do: :deferred, else: :queued),
          recheck_at: recheck_at()
        })

        {:snooze, recheck_seconds()}

      {:ok, %{status: status}} when status in [:applied, :cancelled, :failed] ->
        if target.generation > target.dispatched_generation do
          update(target, %{state: :pending, catalog_sync_run_id: nil, recheck_at: nil})
          dispatch(%{target | catalog_sync_run_id: nil})
        else
          update(target, %{state: :settled, recheck_at: nil})
          :ok
        end

      _ ->
        {:snooze, recheck_seconds()}
    end
  end

  defp dispatch(target) do
    now = DateTime.utc_now()

    if DateTime.compare(target.quiet_until, now) == :gt do
      {:snooze, max(1, min(recheck_seconds(), DateTime.diff(target.quiet_until, now, :second)))}
    else
      queue_or_defer(target, active_run(target.source_system_id))
    end
  end

  defp queue_or_defer(target, nil) do
    case TickeraCatalogSync.queue_triggered_dry_run(target.id, target.generation) do
      {:ok, _} -> {:snooze, recheck_seconds()}
      {:error, :catalog_sync_already_active} -> defer(target)
      {:error, _} -> fail(target)
    end
  end

  defp queue_or_defer(target, _active_run), do: defer(target)

  defp next_target(source_id) do
    CatalogChangePendingTarget
    |> Ash.Query.filter(
      source_system_id == ^source_id and state in [:pending, :deferred, :queued]
    )
    |> Ash.Query.sort(quiet_until: :asc, first_received_at: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Ingestion)
    |> case do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp active_run(source_id) do
    TickeraCatalogSyncRun
    |> Ash.Query.filter(source_system_id == ^source_id and status in ^@active)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Ingestion)
    |> case do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp defer(target) do
    update(target, %{state: :deferred, recheck_at: recheck_at()})
    {:snooze, recheck_seconds()}
  end

  defp fail(target) do
    update(target, %{
      state: :failed,
      recheck_at: nil,
      last_error: "catalog_change_dispatch_failed"
    })

    :discard
  end

  defp update(target, attrs),
    do: Ash.update(target, attrs, action: :transition, domain: Ingestion)

  defp recheck_at, do: DateTime.add(DateTime.utc_now(), recheck_seconds(), :second)

  defp recheck_seconds,
    do:
      Application.get_env(:event_sales, :catalog_change_trigger, [])
      |> Keyword.get(:active_run_recheck_seconds, 60)

  defp enabled?,
    do:
      Application.get_env(:event_sales, :catalog_change_trigger, [])
      |> Keyword.get(:dispatcher_enabled, true)
end
