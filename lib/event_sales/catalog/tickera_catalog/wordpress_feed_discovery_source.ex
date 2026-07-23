defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedDiscoverySource do
  @moduledoc """
  DiscoverySource adapter for the VS-26C WordPress Tickera catalog feed.
  """

  @behaviour EventSales.Catalog.TickeraCatalog.DiscoverySource

  alias EventSales.Catalog.TickeraCatalog.{DiscoveryResult, WordPressFeedClient}

  @impl true
  def discover(source_system_id, scope) when is_binary(source_system_id) and is_map(scope) do
    with {:ok, query} <- normalize_scope(scope),
         {:ok, response} <- WordPressFeedClient.fetch(query) do
      {:ok,
       %DiscoveryResult{
         schema_version: response.schema_version,
         auto_apply_proof_complete?: response.auto_apply_proof_complete?,
         events: response.events,
         catalog_rows: response.catalog_rows,
         source_snapshot_at: response.source_snapshot_at
       }}
    end
  end

  def discover(_source_system_id, _scope), do: {:error, :invalid_scope}

  defp normalize_scope(scope) do
    scope = string_key_map(scope)

    with true <- scope["kind"] == "wordpress_feed",
         {:ok, modes} <- selected_modes(scope),
         {:one_mode, [mode]} <- {:one_mode, modes},
         {:ok, query} <- query_for_mode(mode, scope) do
      {:ok, query}
    else
      _error -> {:error, :invalid_scope}
    end
  end

  defp selected_modes(scope) do
    modes =
      []
      |> maybe_add(scope["mode"] == "full", :full)
      |> maybe_add(present?(scope["product_id"]), :product_id)
      |> maybe_add(present?(scope["variation_id"]), :variation_id)
      |> maybe_add(present?(scope["event_id"]), :event_id)
      |> maybe_add(present?(scope["updated_since"]), :updated_since)

    {:ok, modes}
  end

  defp query_for_mode(:full, _scope), do: {:ok, %{"mode" => "full"}}

  defp query_for_mode(:product_id, scope) do
    with {:ok, id} <- positive_id(scope["product_id"]) do
      {:ok, %{"product_id" => id}}
    end
  end

  defp query_for_mode(:variation_id, scope) do
    with {:ok, id} <- positive_id(scope["variation_id"]) do
      {:ok, %{"variation_id" => id}}
    end
  end

  defp query_for_mode(:event_id, scope) do
    with {:ok, id} <- positive_id(scope["event_id"]) do
      {:ok, %{"event_id" => id}}
    end
  end

  defp query_for_mode(:updated_since, scope) do
    value = scope["updated_since"]

    with true <- is_binary(value),
         true <-
           Regex.match?(
             ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/,
             value
           ),
         {:ok, _datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, %{"updated_since" => value}}
    else
      _error -> {:error, :invalid}
    end
  end

  defp positive_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, :invalid}
    end
  end

  defp positive_id(_value), do: {:error, :invalid}

  defp string_key_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp present?(value), do: value not in [nil, ""]
  defp maybe_add(modes, true, mode), do: modes ++ [mode]
  defp maybe_add(modes, false, _mode), do: modes
end
