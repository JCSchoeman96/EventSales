defmodule EventSales.Analytics.SnapshotCodec do
  @moduledoc """
  Encodes and decodes warm hot-state snapshots for Redis.

  Snapshots are a recoverable read model only. This codec keeps Decimal and
  DateTime values explicit so Redis restore can rebuild ETS safely without
  depending on JSON library implementation details.
  """

  @summary_keys ~w(total_sold total_revenue today_sold today_revenue status_breakdown updated_at)
  @atom_summary_keys Enum.map(@summary_keys, &String.to_atom/1)
  @status_keys ~w(cancelled completed draft failed on_hold pending processing refunded)

  @doc "Encodes a hot-state summary into JSON."
  @spec encode(map()) :: {:ok, String.t()} | {:error, :malformed}
  def encode(summary) when is_map(summary) do
    summary
    |> normalize_summary()
    |> case do
      {:ok, normalized} -> Jason.encode(encode_value(normalized))
      {:error, :malformed} -> {:error, :malformed}
    end
    |> case do
      {:ok, encoded} -> {:ok, encoded}
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  end

  def encode(_summary), do: {:error, :malformed}

  @doc "Decodes a hot-state summary from JSON."
  @spec decode(term()) :: {:ok, map()} | {:error, :malformed}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, decoded} <- Jason.decode(encoded),
         {:ok, decoded} <- decode_value(decoded),
         {:ok, summary} <- normalize_summary(decoded) do
      {:ok, summary}
    else
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  end

  def decode(_encoded), do: {:error, :malformed}

  defp normalize_summary(summary) when is_map(summary) do
    normalized =
      Enum.reduce(summary, %{}, fn {key, value}, acc ->
        case normalize_summary_key(key) do
          {:ok, normalized_key} -> Map.put(acc, normalized_key, value)
          :error -> acc
        end
      end)

    with true <- Enum.all?(@atom_summary_keys, &Map.has_key?(normalized, &1)),
         true <- is_integer(normalized.total_sold),
         true <- is_integer(normalized.today_sold),
         true <- match?(%Decimal{}, normalized.total_revenue),
         true <- match?(%Decimal{}, normalized.today_revenue),
         true <- is_map(normalized.status_breakdown),
         true <- match?(%DateTime{}, normalized.updated_at),
         {:ok, status_breakdown} <- normalize_status_breakdown(normalized.status_breakdown) do
      {:ok, %{normalized | status_breakdown: status_breakdown}}
    else
      _ -> {:error, :malformed}
    end
  end

  defp normalize_summary(_summary), do: {:error, :malformed}

  defp normalize_summary_key(key) when is_atom(key) and key in @atom_summary_keys, do: {:ok, key}

  defp normalize_summary_key(key) when is_binary(key) and key in @summary_keys do
    {:ok, String.to_existing_atom(key)}
  end

  defp normalize_summary_key(_key), do: :error

  defp normalize_status_breakdown(status_breakdown) do
    Enum.reduce_while(status_breakdown, {:ok, %{}}, fn {key, count}, {:ok, acc} ->
      with {:ok, key} <- normalize_status_key(key),
           true <- is_integer(count) and count >= 0 do
        {:cont, {:ok, Map.put(acc, key, count)}}
      else
        _ -> {:halt, {:error, :malformed}}
      end
    end)
  end

  defp normalize_status_key(key) when is_atom(key), do: {:ok, key}

  defp normalize_status_key(key) when is_binary(key) and key in @status_keys do
    {:ok, String.to_existing_atom(key)}
  end

  defp normalize_status_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_status_key(_key), do: {:error, :malformed}

  defp encode_value(%Decimal{} = decimal) do
    %{"__type__" => "decimal", "value" => Decimal.to_string(decimal)}
  end

  defp encode_value(%DateTime{} = datetime) do
    %{"__type__" => "datetime", "value" => DateTime.to_iso8601(datetime)}
  end

  defp encode_value(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), encode_value(value)} end)
  end

  defp encode_value(list) when is_list(list), do: Enum.map(list, &encode_value/1)
  defp encode_value(value), do: value

  defp decode_value(%{"__type__" => "decimal", "value" => value}) when is_binary(value) do
    {:ok, Decimal.new(value)}
  rescue
    _ -> {:error, :malformed}
  end

  defp decode_value(%{"__type__" => "datetime", "value" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :malformed}
    end
  end

  defp decode_value(%{"__type__" => _type}), do: {:error, :malformed}

  defp decode_value(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case decode_value(value) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
        {:error, :malformed} -> {:halt, {:error, :malformed}}
      end
    end)
  end

  defp decode_value(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case decode_value(value) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, :malformed} -> {:halt, {:error, :malformed}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_value(value), do: {:ok, value}
end
