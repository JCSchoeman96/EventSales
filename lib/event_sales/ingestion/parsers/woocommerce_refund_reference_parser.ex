defmodule EventSales.Ingestion.Parsers.WoocommerceRefundReferenceParser do
  @moduledoc """
  Normalizes refund discovery references embedded in a WooCommerce order.

  The embedded `refunds` array is intentionally limited to discovery data. Full
  financial facts come from the parent-scoped refund detail endpoint.
  """

  @type error :: {:invalid_refund_reference, atom(), atom()}
  @type result :: {:ok, [map()]} | {:error, error()}

  @spec parse(map()) :: result()
  def parse(payload) when is_map(payload) do
    case Map.get(payload, "refunds", []) do
      nil -> {:ok, []}
      references when is_list(references) -> parse_references(references)
      _other -> {:error, {:invalid_refund_reference, :refunds, :not_list}}
    end
  end

  def parse(_payload), do: {:error, {:invalid_refund_reference, :payload, :not_map}}

  defp parse_references(references) do
    references
    |> Enum.reduce_while({:ok, []}, fn reference, {:ok, acc} ->
      case parse_reference(reference) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} ->
        parsed
        |> Enum.reverse()
        |> Enum.uniq_by(& &1.woo_refund_id)
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_reference(reference) when is_map(reference) do
    with {:ok, woo_refund_id} <- required_positive_integer(reference, "id", :id),
         {:ok, summary_total_amount} <-
           optional_magnitude(reference, "total", :total),
         {:ok, reason} <- optional_string(reference, "reason", :reason) do
      {:ok,
       %{
         woo_refund_id: woo_refund_id,
         reason: reason,
         summary_total_amount: summary_total_amount
       }}
    end
  end

  defp parse_reference(_reference),
    do: {:error, {:invalid_refund_reference, :reference, :not_map}}

  defp required_positive_integer(payload, key, field) do
    case Map.get(payload, key) do
      nil ->
        {:error, {:invalid_refund_reference, field, :required}}

      value ->
        case positive_integer(value) do
          {:ok, integer} -> {:ok, integer}
          :zero_or_negative -> {:error, {:invalid_refund_reference, field, :must_be_positive}}
          :error -> {:error, {:invalid_refund_reference, field, :invalid}}
        end
    end
  end

  defp optional_magnitude(payload, key, field) do
    case Map.get(payload, key) do
      nil -> {:ok, nil}
      value -> parse_magnitude(value, field)
    end
  end

  defp optional_string(payload, key, field) do
    case Map.get(payload, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, blank_to_nil(value)}
      _value -> {:error, {:invalid_refund_reference, field, :invalid}}
    end
  end

  defp parse_magnitude(value, field) do
    with {:ok, decimal} <- parse_decimal(value),
         false <- Decimal.nan?(decimal) or Decimal.inf?(decimal) do
      {:ok, Decimal.abs(decimal)}
    else
      true -> {:error, {:invalid_refund_reference, field, :invalid}}
      :error -> {:error, {:invalid_refund_reference, field, :invalid}}
    end
  end

  defp parse_decimal(%Decimal{} = decimal), do: {:ok, decimal}
  defp parse_decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}

  defp parse_decimal(value) when is_binary(value) do
    {:ok, Decimal.new(value)}
  rescue
    Decimal.Error -> :error
  end

  defp parse_decimal(_value), do: :error

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(value) when is_integer(value), do: :zero_or_negative

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      {integer, ""} when integer <= 0 -> :zero_or_negative
      _other -> :error
    end
  end

  defp positive_integer(_value), do: :error

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
