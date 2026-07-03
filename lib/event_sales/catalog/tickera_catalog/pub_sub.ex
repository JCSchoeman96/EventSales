defmodule EventSales.Catalog.TickeraCatalog.PubSub do
  @moduledoc """
  Admin lifecycle PubSub for Tickera catalog sync runs.
  """

  @spec topic(String.t()) :: String.t()
  def topic(run_id) when is_binary(run_id), do: "catalog_sync:#{run_id}"

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(run_id) when is_binary(run_id),
    do: Phoenix.PubSub.subscribe(EventSales.PubSub, topic(run_id))

  @spec broadcast(String.t(), atom(), map()) :: :ok
  def broadcast(run_id, event, payload \\ %{}) when is_binary(run_id) and is_atom(event) do
    Phoenix.PubSub.broadcast(EventSales.PubSub, topic(run_id), {event, payload})
  end
end
