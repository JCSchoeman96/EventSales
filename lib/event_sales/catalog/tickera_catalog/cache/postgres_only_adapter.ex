defmodule EventSales.Catalog.TickeraCatalog.Cache.PostgresOnlyAdapter do
  @moduledoc """
  No-op cache adapter; durable previews live on TickeraCatalogSyncRun.
  """

  @behaviour EventSales.Catalog.TickeraCatalog.Cache

  @impl true
  def put_preview(_run_id, _preview, _opts), do: :ok

  @impl true
  def get_preview(_run_id), do: :miss

  @impl true
  def delete_preview(_run_id), do: :ok
end
