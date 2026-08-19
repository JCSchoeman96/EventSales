defmodule EventSales.Ingestion.HistoricalCoverageCertifier do
  @moduledoc """
  Evaluates durable authority for one historical SyncRun without performing writes.

  The evaluator certifies transport and refund coverage boundaries only. It does
  not inspect financial primitives, refund rows, or analytics readiness.
  """

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}

  @type coverage :: %{
          required(:coverage_start) => DateTime.t(),
          required(:sales_covered_through) => DateTime.t(),
          required(:refunds_covered_through) => DateTime.t()
        }

  @type reason ::
          :invalid_input
          | :not_historical_backfill
          | :sync_run_not_running
          | :invalid_source_system_id
          | :missing_event_id
          | :invalid_backfill_start
          | :invalid_backfill_cutoff
          | :invalid_historical_bounds
          | :coverage_already_certified
          | :order_coverage_not_incomplete
          | :refund_coverage_not_incomplete
          | :orders_failed_count_nonzero
          | :errors_count_nonzero
          | :historical_event_missing
          | :historical_event_source_mismatch
          | :historical_event_not_backfill_pending
          | :missing_source_created_at
          | :historical_event_backfill_start_mismatch
          | :cursor_run_mismatch
          | :invalid_historical_cursor
          | :corrupt_cursor_metadata
          | :cursor_failure_metadata
          | :manifest_evidence_missing
          | :manifest_not_terminal
          | :corrupt_manifest_evidence
          | :catchup_evidence_missing
          | :catchup_not_terminal
          | :corrupt_catchup_evidence
          | :catchup_parent_binding_mismatch
          | :catchup_before_manifest
          | :invalid_coverage_range

  @spec evaluate(SyncRun.t(), SyncCursor.t(), keyword()) ::
          {:ok, coverage()} | {:error, reason()}
  def evaluate(run, cursor, opts \\ [])

  def evaluate(%SyncRun{} = run, %SyncCursor{} = cursor, _opts) do
    with :ok <- validate_run(run),
         {:ok, event} <- load_event(run.event_id),
         :ok <- validate_event(event, run),
         :ok <- validate_cursor(cursor, run),
         {:ok, manifest} <- terminal_manifest(cursor.metadata),
         {:ok, catchup} <- terminal_catchup(cursor.metadata),
         :ok <- validate_parent_binding(catchup, manifest),
         :ok <- validate_coverage_range(event.source_created_at, run.date_to) do
      {:ok,
       %{
         coverage_start: event.source_created_at,
         sales_covered_through: run.date_to,
         refunds_covered_through: catchup.source_observed_at
       }}
    end
  end

  def evaluate(_run, _cursor, _opts), do: {:error, :invalid_input}

  defp validate_run(%SyncRun{sync_type: :historical_backfill, status: :running} = run) do
    with :ok <- validate_run_identity(run),
         :ok <- validate_run_bounds(run),
         :ok <- validate_run_coverage(run) do
      validate_run_failures(run)
    end
  end

  defp validate_run(%SyncRun{sync_type: :historical_backfill}),
    do: {:error, :sync_run_not_running}

  defp validate_run(%SyncRun{}), do: {:error, :not_historical_backfill}

  defp validate_run_identity(run) do
    cond do
      not valid_uuid?(run.source_system_id) -> {:error, :invalid_source_system_id}
      not valid_uuid?(run.event_id) -> {:error, :missing_event_id}
      true -> :ok
    end
  end

  defp validate_run_bounds(run) do
    cond do
      not utc_datetime?(run.date_from) ->
        {:error, :invalid_backfill_start}

      not utc_datetime?(run.date_to) ->
        {:error, :invalid_backfill_cutoff}

      DateTime.compare(run.date_from, run.date_to) == :gt ->
        {:error, :invalid_historical_bounds}

      true ->
        :ok
    end
  end

  defp validate_run_coverage(run) do
    cond do
      not is_nil(run.coverage_certified_at) ->
        {:error, :coverage_already_certified}

      run.order_coverage_status != :incomplete ->
        {:error, :order_coverage_not_incomplete}

      run.refund_coverage_status not in [:not_started, :incomplete] ->
        {:error, :refund_coverage_not_incomplete}

      true ->
        :ok
    end
  end

  defp validate_run_failures(run) do
    cond do
      run.orders_failed_count != 0 -> {:error, :orders_failed_count_nonzero}
      run.errors_count != 0 -> {:error, :errors_count_nonzero}
      true -> :ok
    end
  end

  defp load_event(event_id) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %Event{} = event} -> {:ok, event}
      _other -> {:error, :historical_event_missing}
    end
  end

  defp validate_event(%Event{} = event, %SyncRun{} = run) do
    cond do
      event.id != run.event_id ->
        {:error, :historical_event_missing}

      event.source_system_id != run.source_system_id ->
        {:error, :historical_event_source_mismatch}

      event.analytics_onboarding_state != :backfill_pending ->
        {:error, :historical_event_not_backfill_pending}

      not utc_datetime?(event.source_created_at) ->
        {:error, :missing_source_created_at}

      not same_datetime?(event.source_created_at, run.date_from) ->
        {:error, :historical_event_backfill_start_mismatch}

      true ->
        :ok
    end
  end

  defp validate_cursor(%SyncCursor{sync_run_id: sync_run_id}, %SyncRun{id: run_id})
       when sync_run_id != run_id,
       do: {:error, :cursor_run_mismatch}

  defp validate_cursor(%SyncCursor{status: status}, _run) when status != :active,
    do: {:error, :invalid_historical_cursor}

  defp validate_cursor(%SyncCursor{metadata: metadata}, _run) when not is_map(metadata),
    do: {:error, :corrupt_cursor_metadata}

  defp validate_cursor(%SyncCursor{metadata: metadata}, _run) do
    if Map.has_key?(metadata, "failure"),
      do: {:error, :cursor_failure_metadata},
      else: :ok
  end

  defp terminal_manifest(metadata) when is_map(metadata) do
    case HistoricalManifestEvidence.state(metadata) do
      :manifest_terminal ->
        case HistoricalManifestEvidence.from_metadata(metadata) do
          {:ok, manifest} -> {:ok, manifest}
          {:error, _reason} -> {:error, :corrupt_manifest_evidence}
        end

      :missing ->
        {:error, :manifest_evidence_missing}

      :corrupt ->
        {:error, :corrupt_manifest_evidence}

      _other ->
        {:error, :manifest_not_terminal}
    end
  end

  defp terminal_manifest(_metadata), do: {:error, :corrupt_manifest_evidence}

  defp terminal_catchup(metadata) when is_map(metadata) do
    case HistoricalCatchupEvidence.state(metadata) do
      :catchup_terminal ->
        case HistoricalCatchupEvidence.from_metadata(metadata) do
          {:ok, catchup} -> {:ok, catchup}
          {:error, _reason} -> {:error, :corrupt_catchup_evidence}
        end

      :missing ->
        {:error, :catchup_evidence_missing}

      :corrupt ->
        {:error, :corrupt_catchup_evidence}

      _other ->
        {:error, :catchup_not_terminal}
    end
  end

  defp terminal_catchup(_metadata), do: {:error, :corrupt_catchup_evidence}

  defp validate_parent_binding(catchup, manifest) do
    case HistoricalCatchupEvidence.validate_parent_binding(catchup, manifest) do
      :ok -> :ok
      {:error, :catchup_high_water_before_parent} -> {:error, :catchup_before_manifest}
      {:error, _reason} -> {:error, :catchup_parent_binding_mismatch}
    end
  end

  defp validate_coverage_range(%DateTime{} = coverage_start, %DateTime{} = sales_covered_through) do
    if DateTime.compare(coverage_start, sales_covered_through) in [:lt, :eq],
      do: :ok,
      else: {:error, :invalid_coverage_range}
  end

  defp validate_coverage_range(_coverage_start, _sales_covered_through),
    do: {:error, :invalid_coverage_range}

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false

  defp utc_datetime?(%DateTime{} = value) do
    value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0
  end

  defp utc_datetime?(_value), do: false
end
