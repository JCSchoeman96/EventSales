defmodule EventSales.Analytics.PeriodCoverageEligibleEvents do
  @moduledoc false

  alias EventSales.Repo

  @default_batch_size 50
  @zero_uuid "00000000-0000-0000-0000-000000000000"
  @terminal_statuses ~w(passed mismatched superseded failed cancelled)

  @doc """
  Pages event ids in the canonical analytics-ready set.

  Semantics match `HistoricalCoverageResolver.resolve_current/1` on the newest
  certified historical run plus `AnalyticsReadinessResolver` terminal
  reconciliation authority for that exact certificate. One bounded query per page.
  """
  @spec page_event_ids(term(), keyword()) :: [Ecto.UUID.t()]
  def page_event_ids(after_id \\ nil, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_batch_size)
    after_uuid = normalize_after_id(after_id) |> Ecto.UUID.dump!()

    case Repo.query(page_sql(), [@terminal_statuses, after_uuid, limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id] -> Ecto.UUID.cast!(id) end)

      {:error, reason} ->
        raise "period coverage eligible event page failed: #{inspect(reason)}"
    end
  end

  @doc false
  @spec explain_sql() :: String.t()
  def explain_sql, do: page_sql()

  defp page_sql do
    """
    SELECT e.id
    FROM catalog_events e
    INNER JOIN LATERAL (
      SELECT sr.*
      FROM ingestion_sync_runs sr
      WHERE sr.event_id = e.id
        AND sr.sync_type = 'historical_backfill'
        AND sr.coverage_certified_at IS NOT NULL
      ORDER BY sr.coverage_certified_at DESC, sr.finished_at DESC, sr.id DESC
      LIMIT 1
    ) cert ON TRUE
    INNER JOIN LATERAL (
      SELECT fr.*
      FROM ingestion_financial_reconciliation_runs fr
      WHERE fr.event_id = e.id
        AND fr.historical_sync_run_id = cert.id
        AND fr.status = ANY($1::varchar[])
      ORDER BY fr.finished_at DESC NULLS LAST, fr.inserted_at DESC, fr.id DESC
      LIMIT 1
    ) term ON TRUE
    WHERE cert.status = 'completed'
      AND cert.order_coverage_status = 'complete'
      AND cert.refund_coverage_status = 'complete'
      AND cert.coverage_invalidated_at IS NULL
      AND cert.coverage_invalidation_reason IS NULL
      AND cert.coverage_start IS NOT NULL
      AND cert.sales_covered_through IS NOT NULL
      AND cert.refunds_covered_through IS NOT NULL
      AND cert.coverage_start <= cert.sales_covered_through
      AND cert.coverage_evidence->>'result' = 'certified'
      AND term.status = 'passed'
      AND term.finished_at IS NOT NULL
      AND term.historical_sync_run_id = cert.id
      AND term.event_id = cert.event_id
      AND term.source_system_id = cert.source_system_id
      AND term.coverage_start = cert.coverage_start
      AND term.sales_covered_through = cert.sales_covered_through
      AND term.refunds_covered_through = cert.refunds_covered_through
      AND NOT EXISTS (
        SELECT 1
        FROM ingestion_financial_reconciliation_findings f
        WHERE f.financial_reconciliation_run_id = term.id
      )
      AND e.id > $2::uuid
    ORDER BY e.id ASC
    LIMIT $3
    """
  end

  defp normalize_after_id(nil), do: @zero_uuid
  defp normalize_after_id(id) when is_binary(id), do: id
end
