defmodule EventSales.Ingestion.HistoricalCoverageResolver do
  @moduledoc """
  Resolves the currently-valid historical coverage certificate for one Event.

  The newest certified historical run is the authority for the Event. The
  resolver evaluates that run locally and never mutates certification state.
  """

  require Ash.Query

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.SyncRun

  @type error_reason ::
          :invalid_event_id
          | :historical_coverage_not_current
          | :historical_coverage_lookup_failed

  @spec resolve_current(term()) ::
          {:ok, SyncRun.t()} | {:error, error_reason()}
  def resolve_current(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, canonical_event_id} -> resolve_certified_run(canonical_event_id)
      _error -> {:error, :invalid_event_id}
    end
  end

  defp resolve_certified_run(event_id) do
    case latest_certified_run(event_id) do
      {:ok, nil} ->
        {:error, :historical_coverage_not_current}

      {:ok, %SyncRun{} = run} ->
        current_certificate_result(run, event_id)

      {:error, :historical_coverage_lookup_failed} ->
        {:error, :historical_coverage_lookup_failed}
    end
  end

  defp latest_certified_run(event_id) do
    query =
      SyncRun
      |> Ash.Query.filter(
        event_id == ^event_id and
          sync_type == :historical_backfill and
          not is_nil(coverage_certified_at)
      )
      |> Ash.Query.sort(coverage_certified_at: :desc, finished_at: :desc, id: :desc)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, domain: Ingestion) do
      {:ok, %SyncRun{} = run} -> {:ok, run}
      {:ok, nil} -> {:ok, nil}
      _error -> {:error, :historical_coverage_lookup_failed}
    end
  rescue
    _error -> {:error, :historical_coverage_lookup_failed}
  catch
    :exit, _reason -> {:error, :historical_coverage_lookup_failed}
    :throw, _value -> {:error, :historical_coverage_lookup_failed}
  end

  defp current_certificate_result(%SyncRun{} = run, event_id) do
    if current_certificate?(run, event_id) do
      {:ok, run}
    else
      {:error, :historical_coverage_not_current}
    end
  end

  defp current_certificate?(%SyncRun{} = run, event_id) do
    historical_run_scope?(run, event_id) and
      complete_coverage?(run) and
      current_certification?(run) and
      complete_coverage_boundaries?(run)
  end

  defp historical_run_scope?(%SyncRun{} = run, event_id) do
    run.sync_type == :historical_backfill and
      run.event_id == event_id and
      run.status == :completed
  end

  defp complete_coverage?(%SyncRun{} = run) do
    run.order_coverage_status == :complete and
      run.refund_coverage_status == :complete
  end

  defp current_certification?(%SyncRun{} = run) do
    not is_nil(run.coverage_certified_at) and
      is_nil(run.coverage_invalidated_at) and
      is_nil(run.coverage_invalidation_reason)
  end

  defp complete_coverage_boundaries?(%SyncRun{} = run) do
    not is_nil(run.coverage_start) and
      not is_nil(run.sales_covered_through) and
      not is_nil(run.refunds_covered_through) and
      valid_sales_coverage_range?(run.coverage_start, run.sales_covered_through)
  end

  defp valid_sales_coverage_range?(%DateTime{} = coverage_start, %DateTime{} = covered_through) do
    DateTime.compare(coverage_start, covered_through) in [:lt, :eq]
  end

  defp valid_sales_coverage_range?(_coverage_start, _covered_through), do: false
end
