defmodule EventSales.Analytics.Aggregators.EventAggregator do
  @moduledoc """
  Event-scoped sales summary queries.

  This is a plain module that reads durable Ash/Postgres order item rows and
  delegates all metric decisions to `EventSales.Analytics.MetricRules`.
  """

  require Ash.Query

  alias EventSales.Analytics.MetricRules
  alias EventSales.Sales
  alias EventSales.Sales.Resources.OrderItem

  @doc """
  Summarizes all order item rows scoped to one event.

  The query intentionally does not pre-filter by mapping status or order status.
  Sold, revenue, status, and today decisions belong to `MetricRules`.
  """
  @spec summary_for_event(Ecto.UUID.t(), keyword()) ::
          {:ok, MetricRules.summary()} | {:error, term()}
  def summary_for_event(event_id, opts \\ []) when is_binary(event_id) do
    OrderItem
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort(woo_line_item_id: :asc)
    |> Ash.Query.load(:order)
    |> Ash.read(domain: Sales)
    |> case do
      {:ok, items} -> {:ok, MetricRules.summarize(items, opts)}
      {:error, reason} -> {:error, reason}
    end
  end
end
