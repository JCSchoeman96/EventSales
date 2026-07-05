defmodule EventSales.Catalog.TickeraCatalog.ConfiguredDiscoverySource do
  @moduledoc """
  Dispatches Tickera catalog discovery to the configured source adapter.
  """

  @behaviour EventSales.Catalog.TickeraCatalog.DiscoverySource

  alias EventSales.Catalog.TickeraCatalog.ManualRowsDiscoverySource

  @impl true
  def discover(source_system_id, scope) when is_binary(source_system_id) and is_map(scope) do
    adapter = Application.get_env(:event_sales, :tickera_catalog_discovery_source)

    cond do
      manual_rows_scope?(scope) ->
        ManualRowsDiscoverySource.discover(source_system_id, scope)

      adapter ->
        adapter.discover(source_system_id, scope)

      true ->
        {:error, :not_configured}
    end
  end

  defp manual_rows_scope?(%{"kind" => "manual_rows"}), do: true
  defp manual_rows_scope?(%{kind: "manual_rows"}), do: true
  defp manual_rows_scope?(_scope), do: false
end
