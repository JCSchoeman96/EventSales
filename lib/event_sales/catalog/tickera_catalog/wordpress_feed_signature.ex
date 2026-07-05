defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedSignature do
  @moduledoc """
  HMAC request signing for the VS-26C WordPress Tickera catalog feed.
  """

  @type query :: %{optional(String.t() | atom()) => term()} | keyword()

  @spec headers(atom() | String.t(), String.t(), query(), String.t(), integer()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, :invalid_request}
  def headers(method, path, query, secret, now \\ System.system_time(:second))
      when is_binary(path) and is_binary(secret) and is_integer(now) do
    with {:ok, canonical_query} <- canonical_query(query) do
      timestamp = Integer.to_string(now)

      base_string =
        [
          method |> to_string() |> String.upcase(),
          path,
          canonical_query,
          timestamp
        ]
        |> Enum.join("\n")

      signature =
        :hmac
        |> :crypto.mac(:sha256, secret, base_string)
        |> Base.encode16(case: :lower)

      {:ok,
       [
         {"x-eventsales-timestamp", timestamp},
         {"x-eventsales-signature", "v1=" <> signature},
         {"accept", "application/json"}
       ]}
    end
  end

  @spec canonical_query(query()) :: {:ok, String.t()} | {:error, :invalid_request}
  def canonical_query(query) when is_map(query) or is_list(query) do
    query
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      cond do
        is_nil(value) ->
          {:cont, {:ok, acc}}

        scalar?(value) ->
          {:cont, {:ok, [{to_string(key), to_string(value)} | acc]}}

        true ->
          {:halt, {:error, :invalid_request}}
      end
    end)
    |> case do
      {:ok, params} ->
        encoded =
          params
          |> Enum.sort_by(fn {key, _value} -> key end)
          |> Enum.map_join("&", fn {key, value} ->
            rfc3986(key) <> "=" <> rfc3986(value)
          end)

        {:ok, encoded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def canonical_query(_query), do: {:error, :invalid_request}

  defp scalar?(value),
    do: is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value)

  defp rfc3986(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
