defmodule EventSales.Audit.MetadataSanitizer do
  @moduledoc """
  Sanitizes operational audit metadata before durable storage.

  Metadata is recursively normalized to string-keyed maps, sensitive keys are
  removed at any depth, and the final JSON representation is bounded to 2048
  bytes.
  """

  @max_bytes 2048

  @blocked_keys MapSet.new([
                  "raw_body",
                  "body",
                  "payload",
                  "headers",
                  "authorization",
                  "cookie",
                  "x-wc-webhook-signature",
                  "signature",
                  "token",
                  "api_key",
                  "consumer_key",
                  "consumer_secret",
                  "secret",
                  "password",
                  "email",
                  "phone",
                  "first_name",
                  "last_name",
                  "billing",
                  "shipping",
                  "customer"
                ])

  @doc """
  Sanitizes audit metadata.

  Returns `{:error, :invalid_metadata}` if metadata is not a map.
  """
  @spec sanitize(map()) :: {:ok, map()} | {:error, :invalid_metadata}
  def sanitize(metadata) when is_map(metadata) do
    metadata
    |> normalize()
    |> ensure_size()
  end

  def sanitize(_metadata), do: {:error, :invalid_metadata}

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  defp normalize(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      normalized_key = normalize_key(key)

      if blocked_key?(normalized_key) do
        acc
      else
        Map.put(acc, normalized_key, normalize(value))
      end
    end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value), do: value

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_key(key) when is_binary(key), do: String.downcase(key)
  defp normalize_key(key), do: key |> to_string() |> String.downcase()

  defp blocked_key?(key), do: MapSet.member?(@blocked_keys, key)

  defp ensure_size(metadata) do
    if encoded_size(metadata) <= @max_bytes do
      {:ok, metadata}
    else
      {:ok, shrink(metadata)}
    end
  end

  defp shrink(metadata) do
    truncated =
      metadata
      |> drop_large_values()
      |> Map.put("metadata_truncated", true)

    if encoded_size(truncated) <= @max_bytes do
      truncated
    else
      %{"metadata_truncated" => true}
    end
  end

  defp drop_large_values(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      cond do
        key == "metadata_truncated" ->
          acc

        is_binary(value) and byte_size(value) > 256 ->
          acc

        is_map(value) or is_list(value) ->
          Map.put(acc, key, drop_large_values(value))

        true ->
          Map.put(acc, key, value)
      end
    end)
  end

  defp drop_large_values(list) when is_list(list) do
    list
    |> Enum.map(&drop_large_values/1)
    |> Enum.reject(&(&1 in [%{}, []]))
  end

  defp drop_large_values(value), do: value

  defp encoded_size(metadata) do
    case Jason.encode(metadata) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _error} -> @max_bytes + 1
    end
  end
end
