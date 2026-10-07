defmodule EventSales.Analytics.PeriodCoverageEligibleEvents do
  @moduledoc false

  alias EventSales.Ingestion.HistoricalCoverageEvidence
  alias EventSales.Repo

  @default_batch_size 50
  @zero_uuid "00000000-0000-0000-0000-000000000000"
  @terminal_statuses ~w(passed mismatched superseded failed cancelled)

  defmodule CandidatePage do
    @moduledoc false
    @enforce_keys [:event_ids, :next_after_event_id, :has_more?, :candidates_examined]
    defstruct [:event_ids, :next_after_event_id, :has_more?, :candidates_examined]

    @type t :: %__MODULE__{
            event_ids: [Ecto.UUID.t()],
            next_after_event_id: Ecto.UUID.t() | nil,
            has_more?: boolean(),
            candidates_examined: non_neg_integer()
          }
  end

  @doc """
  Returns analytics-ready event ids from one bounded raw candidate page.

  Canonical evidence acceptance uses `HistoricalCoverageEvidence.certified?/1`
  in BEAM. Use `page_candidates/2` when the raw paging cursor is required.
  """
  @spec page_event_ids(term(), keyword()) :: [Ecto.UUID.t()]
  def page_event_ids(after_id \\ nil, opts \\ []) do
    page_candidates(after_id, opts).event_ids
  end

  @doc """
  Pages raw SQL candidates (newest cert + terminal reconciliation columns).

  `next_after_event_id` and `has_more?` follow the raw candidate page, not
  only evidence-valid event ids.
  """
  @spec page_candidates(term(), keyword()) :: CandidatePage.t()
  def page_candidates(after_id \\ nil, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_batch_size)
    after_uuid = normalize_after_id(after_id) |> Ecto.UUID.dump!()

    case Repo.query(page_sql(), [@terminal_statuses, after_uuid, limit]) do
      {:ok, %{rows: rows}} ->
        build_page(rows, limit)

      {:error, reason} ->
        raise "period coverage eligible event page failed: #{inspect(reason)}"
    end
  end

  @doc false
  @spec collect_event_ids(keyword()) :: [Ecto.UUID.t()]
  def collect_event_ids(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_batch_size)
    collect_from_cursor(nil, limit, MapSet.new(), opts)
  end

  @doc false
  @spec explain_sql() :: String.t()
  def explain_sql, do: page_sql()

  defp collect_from_cursor(after_id, limit, acc, opts) do
    page = page_candidates(after_id, Keyword.put(opts, :limit, limit))
    acc = Enum.reduce(page.event_ids, acc, &MapSet.put(&2, &1))

    if page.has_more? and page.next_after_event_id do
      collect_from_cursor(page.next_after_event_id, limit, acc, opts)
    else
      acc |> MapSet.to_list() |> Enum.sort()
    end
  end

  defp build_page(rows, limit) do
    candidates =
      Enum.map(rows, fn [id, evidence] ->
        {Ecto.UUID.cast!(id), decode_evidence(evidence)}
      end)

    event_ids =
      candidates
      |> Enum.filter(fn {_id, evidence} -> HistoricalCoverageEvidence.certified?(evidence) end)
      |> Enum.map(fn {id, _} -> id end)

    last_raw_id =
      case List.last(candidates) do
        {id, _} -> id
        nil -> nil
      end

    %CandidatePage{
      event_ids: event_ids,
      next_after_event_id: last_raw_id,
      has_more?: length(rows) == limit,
      candidates_examined: length(rows)
    }
  end

  defp decode_evidence(evidence) when is_map(evidence), do: evidence

  defp decode_evidence(evidence) when is_binary(evidence) do
    case Jason.decode(evidence) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp decode_evidence(_), do: %{}

  defp page_sql do
    """
    SELECT e.id, cert.coverage_evidence
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
