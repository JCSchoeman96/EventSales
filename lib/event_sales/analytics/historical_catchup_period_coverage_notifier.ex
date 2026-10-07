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
    case terminal_anchor(run, cursor) do
      {:ok, event_id, %DateTime{} = captured_now} ->
        coverage_opts = Keyword.get(opts, :period_coverage_opts, [])

        case PeriodCoverage.ensure_event_buckets(event_id, captured_now, coverage_opts) do
          {:ok, _result} -> :ok
          {:error, _reason} -> :ok
        end

      _invalid ->
        :ok
    end
  end

  defp terminal_anchor(
         %SyncRun{sync_type: :historical_backfill, status: :completed} = run,
         %SyncCursor{} = cursor
       ) do
    with :ok <- validate_terminal_shape(run, cursor),
         :catchup_terminal <- HistoricalCatchupEvidence.state(cursor.metadata),
         {:ok, %{source_observed_at: %DateTime{} = source_observed_at}} <-
           HistoricalCatchupEvidence.from_metadata(cursor.metadata) do
      {:ok, run.event_id, source_observed_at}
    else
      _invalid -> :error
    end
  end

  defp terminal_anchor(_run, _cursor), do: :error

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
