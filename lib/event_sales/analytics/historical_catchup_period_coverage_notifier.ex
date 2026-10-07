defmodule EventSales.Analytics.HistoricalCatchupPeriodCoverageNotifier do
  @moduledoc """
  Post-commit period bucket coverage bootstrap after terminal historical catch-up.
  """

  alias EventSales.Analytics.PeriodCoverage
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}

  @type notifier_opts :: keyword()

  @doc "Ensures comparison bucket coverage exists after terminal catch-up success."
  @spec notify_terminal_success(SyncRun.t(), SyncCursor.t(), notifier_opts()) :: :ok
  def notify_terminal_success(run, cursor, opts \\ []) do
    with :ok <- validate_terminal_shape(run, cursor),
         :catchup_terminal <- HistoricalCatchupEvidence.state(cursor.metadata),
         {:ok, event_id} <- terminal_event_id(run, cursor) do
      captured_now = coverage_captured_now(opts)

      coverage = Keyword.get(opts, :period_coverage, PeriodCoverage)

      case coverage.ensure_event_buckets(event_id, captured_now, coverage_opts(opts)) do
        {:ok, _result} -> :ok
        {:error, _reason} -> :ok
      end
    else
      _invalid -> :ok
    end
  end

  defp terminal_event_id(%SyncRun{event_id: event_id}, _cursor) when is_binary(event_id),
    do: {:ok, event_id}

  defp terminal_event_id(_run, _cursor), do: :error

  defp coverage_captured_now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = instant -> DateTime.truncate(instant, :microsecond)
      fun when is_function(fun, 0) -> DateTime.truncate(fun.(), :microsecond)
      nil -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp coverage_opts(opts), do: Keyword.get(opts, :period_coverage_opts, [])

  defp validate_terminal_shape(run, cursor) do
    if valid_uuid?(run.id) and valid_uuid?(run.event_id) and cursor.sync_run_id == run.id and
         cursor.status == :done and is_map(cursor.metadata) do
      :ok
    else
      :error
    end
  end

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_value), do: false
end
