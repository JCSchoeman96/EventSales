defmodule EventSales.Analytics.PeriodCoverageEligibleEvents do
  @moduledoc false

  import Ecto.Query

  alias EventSales.Repo

  @default_batch_size 50

  @doc """
  Pages event ids that have a certified historical coverage certificate and a
  terminal passed financial reconciliation for that exact certificate.

  Stable ascending `event_id` order; caller passes the last seen id as `after_id`.
  """
  @spec page_event_ids(term(), keyword()) :: [Ecto.UUID.t()]
  def page_event_ids(after_id \\ nil, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_batch_size)
    base_after = normalize_after_id(after_id)

    from(e in "catalog_events",
      join: sr in "ingestion_sync_runs",
      on: sr.event_id == e.id,
      join: fr in "ingestion_financial_reconciliation_runs",
      on:
        fr.event_id == e.id and fr.historical_sync_run_id == sr.id and
          fr.status == "passed",
      where:
        sr.sync_type == "historical_backfill" and not is_nil(sr.coverage_certified_at) and
          e.id > ^base_after,
      distinct: e.id,
      order_by: [asc: e.id],
      limit: ^limit,
      select: e.id
    )
    |> Repo.all()
    |> Enum.map(&Ecto.UUID.cast!/1)
  end

  @zero_uuid "00000000-0000-0000-0000-000000000000"

  defp normalize_after_id(nil), do: Ecto.UUID.dump!(@zero_uuid)
  defp normalize_after_id(id) when is_binary(id), do: Ecto.UUID.dump!(id)
end
