defmodule EventSales.Catalog.TickeraCatalog.Cache do
  @moduledoc """
  Optional preview cache facade.

  VS-26A defaults to Postgres-only behavior; apply never depends on Redis.
  """

  @callback put_preview(String.t(), map(), keyword()) :: :ok | {:error, term()}
  @callback get_preview(String.t()) :: {:ok, map()} | :miss | {:error, term()}
  @callback delete_preview(String.t()) :: :ok | {:error, term()}

  def put_preview(run_id, preview, opts \\ []), do: adapter().put_preview(run_id, preview, opts)
  def get_preview(run_id), do: adapter().get_preview(run_id)
  def delete_preview(run_id), do: adapter().delete_preview(run_id)

  defp adapter do
    :event_sales
    |> Application.get_env(:tickera_catalog_cache, [])
    |> Keyword.get(:adapter, EventSales.Catalog.TickeraCatalog.Cache.PostgresOnlyAdapter)
  end
end
