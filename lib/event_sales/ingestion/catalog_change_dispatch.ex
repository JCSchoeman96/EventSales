defmodule EventSales.Ingestion.CatalogChangeDispatch do
  @moduledoc "Generation-aware exact-target dispatch orchestration."
  require Ash.Query
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{CatalogChangePendingTarget, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.TickeraCatalogSync

  @active [:queued, :discovering, :retry_scheduled, :dry_run_ready, :applying]

  def perform(source_system_id, opts \\ []) do
    if enabled?() do
      case next_target(source_system_id) do
        {:ok, nil} -> :ok
        {:ok, target} -> dispatch(target, opts)
        {:error, reason} -> {:error, reason}
      end
    else
      {:snooze, recheck_seconds()}
    end
  end

  defp dispatch(%{catalog_sync_run_id: run_id} = target, opts) when not is_nil(run_id) do
    TickeraCatalogSyncRun
    |> Ash.get(run_id, domain: Ingestion)
    |> reconcile_linked_run(target, opts)
  end

  defp dispatch(target, opts) do
    now = DateTime.utc_now()

    if DateTime.compare(target.quiet_until, now) == :gt do
      {:snooze, max(1, min(recheck_seconds(), DateTime.diff(target.quiet_until, now, :second)))}
    else
      case active_run(target.source_system_id) do
        {:ok, run} -> queue_or_defer(target, run, opts)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp reconcile_linked_run(
         {:ok, %{status: :dry_run_ready}},
         %{generation: generation, dispatched_generation: generation} = target,
         opts
       ),
       do: transition_result(target, %{state: :preview_ready, recheck_at: nil}, opts, :ok)

  defp reconcile_linked_run({:ok, %{status: status}}, target, opts) when status in @active do
    state = if target.generation > target.dispatched_generation, do: :deferred, else: :queued

    transition_result(
      target,
      %{state: state, recheck_at: recheck_at()},
      opts,
      {:snooze, recheck_seconds()}
    )
  end

  defp reconcile_linked_run({:ok, %{status: status}}, target, opts)
       when status in [:applied, :cancelled, :failed],
       do: reconcile_terminal_run(target, opts)

  defp reconcile_linked_run({:ok, _run}, _target, _opts), do: {:snooze, recheck_seconds()}
  defp reconcile_linked_run({:error, reason}, _target, _opts), do: {:error, reason}

  defp reconcile_terminal_run(target, opts)
       when target.generation > target.dispatched_generation do
    case update(target, %{state: :pending, catalog_sync_run_id: nil, recheck_at: nil}, opts) do
      {:ok, updated} -> dispatch(updated, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_terminal_run(target, opts),
    do: transition_result(target, %{state: :settled, recheck_at: nil}, opts, :ok)

  defp queue_or_defer(target, nil, opts) do
    queue_opts = Keyword.get(opts, :queue_opts, [])

    case TickeraCatalogSync.queue_triggered_dry_run(target.id, target.generation, queue_opts) do
      {:ok, _} ->
        {:snooze, recheck_seconds()}

      {:error, :catalog_sync_already_active} ->
        defer(target, opts)

      {:error, :stale_generation} ->
        {:snooze, 1}

      {:error, :not_found} ->
        :discard

      {:error, reason} when reason in [:invalid_scope, :source_not_eligible] ->
        fail(target, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp queue_or_defer(target, _active_run, opts), do: defer(target, opts)

  defp next_target(source_id) do
    CatalogChangePendingTarget
    |> Ash.Query.filter(
      source_system_id == ^source_id and state in [:pending, :deferred, :queued]
    )
    |> Ash.Query.sort(quiet_until: :asc, first_received_at: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Ingestion)
  end

  defp active_run(source_id) do
    TickeraCatalogSyncRun
    |> Ash.Query.filter(source_system_id == ^source_id and status in ^@active)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Ingestion)
  end

  defp defer(target, opts),
    do:
      transition_result(
        target,
        %{state: :deferred, recheck_at: recheck_at()},
        opts,
        {:snooze, recheck_seconds()}
      )

  defp fail(target, opts),
    do:
      transition_result(
        target,
        %{state: :failed, recheck_at: nil, last_error: "catalog_change_dispatch_failed"},
        opts,
        :discard
      )

  defp transition_result(target, attrs, opts, success_result) do
    case update(target, attrs, opts) do
      {:ok, _updated} -> success_result
      {:error, reason} -> {:error, reason}
    end
  end

  defp update(target, attrs, opts) do
    case Keyword.get(opts, :transition_fun) do
      fun when is_function(fun, 2) -> fun.(target, attrs)
      nil -> Ash.update(target, attrs, action: :transition, domain: Ingestion)
    end
  end

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
