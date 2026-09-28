defmodule EventSales.Analytics.HistoricalCatchupFreshnessNotifier do
  @moduledoc """
  Projects terminal historical catch-up source evidence into event freshness
  after the catch-up completion transaction commits.
  """

  alias EventSales.Analytics.SourceFreshness
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Telemetry

  @type notifier_opts :: keyword()

  @doc "Notifies source freshness from a successfully completed terminal catch-up."
  @spec notify_terminal_success(SyncRun.t(), SyncCursor.t(), notifier_opts()) :: :ok
  def notify_terminal_success(run, cursor, opts \\ [])

  def notify_terminal_success(
        %SyncRun{sync_type: :historical_backfill, status: :completed} = run,
        cursor,
        opts
      ) do
    case terminal_evidence(run, cursor) do
      {:ok, event_id, %DateTime{} = source_observed_at} ->
        project(event_id, source_observed_at, opts)

      :invalid_terminal_evidence ->
        emit_failure(:terminal_evidence)
        :ok
    end
  end

  def notify_terminal_success(_run, _cursor, _opts), do: :ok

  defp terminal_evidence(%SyncRun{} = run, %SyncCursor{} = cursor) do
    with :ok <- validate_terminal_shape(run, cursor),
         :catchup_terminal <- HistoricalCatchupEvidence.state(cursor.metadata),
         {:ok, %{source_observed_at: %DateTime{} = source_observed_at}} <-
           HistoricalCatchupEvidence.from_metadata(cursor.metadata) do
      {:ok, run.event_id, source_observed_at}
    else
      _invalid_evidence ->
        :invalid_terminal_evidence
    end
  end

  defp terminal_evidence(_run, _cursor), do: :invalid_terminal_evidence

  defp validate_terminal_shape(run, cursor) do
    if valid_uuid?(run.id) and valid_uuid?(run.event_id) and cursor.sync_run_id == run.id and
         cursor.status == :done and is_map(cursor.metadata) do
      :ok
    else
      :invalid_terminal_shape
    end
  end

  defp project(event_id, source_observed_at, opts) do
    source_freshness = Keyword.get(opts, :source_freshness, SourceFreshness)

    try do
      case source_freshness.advance_sync_source_observed(event_id, source_observed_at) do
        :ok -> :ok
        {:error, _reason} -> emit_failure(:projection_write)
        _other -> emit_failure(:projection_write)
      end
    rescue
      _exception ->
        emit_failure(:projection_write)
    catch
      _kind, _reason ->
        emit_failure(:projection_write)
    end

    :ok
  end

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_value), do: false

  defp emit_failure(stage) do
    Telemetry.emit(
      Telemetry.source_freshness_advance_failed(),
      %{count: 1},
      %{component: :sync, source: :historical_catchup, stage: stage}
    )
  end
end
