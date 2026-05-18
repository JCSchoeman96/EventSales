defmodule EventSales.Analytics.Workers.RefreshSnapshotWorker do
  @moduledoc """
  Refreshes scoped durable analytics reporting snapshots.
  """

  use Oban.Worker,
    queue: :analytics_rebuilds,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:args],
      keys: [:scope, :event_id, :business_date],
      states: ~w(available scheduled executing retryable)a
    ]

  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Telemetry

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scope" => "event", "event_id" => event_id}})
      when is_binary(event_id) do
    case cast_uuid(event_id) do
      {:ok, event_id} -> refresh(:event, fn -> SnapshotRefresh.refresh_event(event_id) end)
      :error -> :discard
    end
  end

  def perform(%Oban.Job{
        args: %{"scope" => "daily", "event_id" => event_id, "business_date" => business_date}
      })
      when is_binary(event_id) and is_binary(business_date) do
    with {:ok, event_id} <- cast_uuid(event_id),
         {:ok, date} <- Date.from_iso8601(business_date) do
      refresh(:daily, fn -> SnapshotRefresh.refresh_daily(event_id, date) end)
    else
      :error -> :discard
      {:error, _reason} -> :discard
    end
  end

  def perform(%Oban.Job{}), do: :discard

  defp refresh(scope, fun) do
    started_at = System.monotonic_time()
    emit_start(scope)

    case fun.() do
      {:ok, _snapshot} ->
        emit_stop(scope, System.monotonic_time() - started_at)
        :ok

      {:error, reason} ->
        emit_exception(scope, reason)
        {:error, reason}
    end
  end

  defp emit_start(scope) do
    Telemetry.emit(Telemetry.snapshot_refresh_start(), %{count: 1}, %{
      scope: scope,
      source: :postgres
    })
  end

  defp emit_stop(scope, duration) do
    Telemetry.emit(Telemetry.snapshot_refresh_stop(), %{duration: duration}, %{
      result: :ok,
      scope: scope,
      source: :postgres
    })
  end

  defp emit_exception(scope, reason) do
    Telemetry.emit(Telemetry.snapshot_refresh_exception(), %{count: 1}, %{
      reason: low_cardinality_reason(reason),
      scope: scope,
      source: :postgres
    })
  end

  defp low_cardinality_reason(reason) when is_atom(reason), do: reason
  defp low_cardinality_reason({reason, _detail}) when is_atom(reason), do: reason
  defp low_cardinality_reason(_reason), do: :error

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end
end
