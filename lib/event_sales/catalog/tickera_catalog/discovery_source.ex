defmodule EventSales.Catalog.TickeraCatalog.DiscoverySource do
  @moduledoc """
  Behaviour for VS-26A Tickera Bridge catalog discovery sources.
  """

  alias EventSales.Catalog.TickeraCatalog.DiscoveryResult

  @callback discover(source_system_id :: String.t(), scope :: map()) ::
              {:ok, DiscoveryResult.t()} | {:error, term()}
end
