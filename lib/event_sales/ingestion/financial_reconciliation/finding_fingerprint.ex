defmodule EventSales.Ingestion.FinancialReconciliation.FindingFingerprint do
  @moduledoc """
  Deterministic SHA-256 fingerprinting for durable structural reconciliation findings.
  """

  @spec compute(atom(), atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def compute(category, origin, details)
      when is_atom(category) and is_atom(origin) and is_map(details) do
    with {:ok, normalized_details} <- normalize_details(details),
         {:ok, canonical} <- canonical_payload(category, origin, normalized_details) do
      {:ok, :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)}
    end
  end

  def compute(_category, _origin, _details) do
    {:error, :invalid_fingerprint_input}
  end

  @spec normalize_details(term()) :: {:ok, term()} | {:error, term()}
  def normalize_details(nil), do: {:ok, nil}
  def normalize_details(value) when is_boolean(value), do: {:ok, value}
  def normalize_details(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}
  def normalize_details(%Decimal{} = value), do: {:ok, Decimal.to_string(value, :normal)}
  def normalize_details(value) when is_binary(value), do: {:ok, value}
  def normalize_details(value) when is_integer(value), do: {:ok, value}
  def normalize_details(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  def normalize_details(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> normalize_details()
  end

  def normalize_details(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_details(item) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_details(details) when is_map(details) do
    details
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      with {:ok, normalized_key} <- normalize_key(key),
           {:ok, normalized_value} <- normalize_details(value) do
        {:cont, {:ok, [{normalized_key, normalized_value} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pairs} ->
        {:ok, Map.new(pairs)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def normalize_details(_value), do: {:error, :unsupported_detail_value}

  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_integer(key), do: {:ok, Integer.to_string(key)}
  defp normalize_key(_key), do: {:error, :unsupported_detail_key}

  defp canonical_payload(category, origin, normalized_details) do
    payload =
      canonical_form(%{
        "category" => Atom.to_string(category),
        "details" => normalized_details,
        "origin" => Atom.to_string(origin)
      })

    case Jason.encode(payload) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:details_not_json_safe, reason}}
    end
  end

  # Type-tagged canonical form preserves JSON object vs array identity while
  # sorting object keys deterministically for the fingerprint hash input only.
  defp canonical_form(%{} = map) do
    [
      "$o",
      map
      |> Enum.map(fn {key, value} -> [key, canonical_form(value)] end)
      |> Enum.sort_by(&hd/1)
    ]
  end

  defp canonical_form(list) when is_list(list) do
    ["$a", Enum.map(list, &canonical_form/1)]
  end

  defp canonical_form(value), do: value
end
