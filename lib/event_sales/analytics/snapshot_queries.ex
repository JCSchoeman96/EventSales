defmodule EventSales.Analytics.SnapshotQueries do
  @moduledoc """
  Bounded durable queries used by hot-state rebuild workers.

  These queries only discover event ids from Postgres. Metric aggregation stays
  in `EventSales.Analytics.Aggregators.EventAggregator`.
  """

  import Ecto.Query

  alias EventSales.Repo

  @doc "Returns a bounded page of event ids that have normalized order items."
  @spec event_ids_page(String.t() | nil, pos_integer()) :: [String.t()]
  def event_ids_page(after_event_id, limit) when is_integer(limit) and limit > 0 do
    "sales_order_items"
    |> base_query(after_event_id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp base_query(table, nil) do
    from item in table,
      where: not is_nil(field(item, :event_id)),
      distinct: true,
      order_by: [asc: field(item, :event_id)],
      select: type(field(item, :event_id), :binary_id)
  end

  defp base_query(table, after_event_id) when is_binary(after_event_id) do
    from item in table,
      where:
        not is_nil(field(item, :event_id)) and
          field(item, :event_id) > type(^after_event_id, :binary_id),
      distinct: true,
      order_by: [asc: field(item, :event_id)],
      select: type(field(item, :event_id), :binary_id)
  end
end
