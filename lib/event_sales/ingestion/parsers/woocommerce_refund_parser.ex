defmodule EventSales.Ingestion.Parsers.WoocommerceRefundParser do
  @moduledoc """
  Normalizes one exact WooCommerce refund detail object.

  This parser performs no database lookup or OrderItem binding. It preserves
  quantity and money as independent source facts and normalizes WooCommerce's
  reversal signs into non-negative magnitudes.
  """

  @type error :: {:invalid_refund_payload, atom(), atom()}
  @type result :: {:ok, map()} | {:error, error()}

  @spec parse(map()) :: result()
  def parse(payload) when is_map(payload) do
    with {:ok, woo_refund_id} <- required_positive_integer(payload, "id", :id),
         {:ok, header_amount} <- required_magnitude(payload, "amount", :amount),
         {:ok, reason} <- optional_string(payload, "reason", :reason),
         {:ok, source_created_at} <-
           optional_gmt_datetime(payload, "date_created_gmt", :date_created_gmt),
         {:ok, line_items} <- parse_line_items(Map.get(payload, "line_items", [])),
         {:ok, shipping} <- parse_component_lines(payload, "shipping_lines", :shipping),
         {:ok, fees} <- parse_component_lines(payload, "fee_lines", :fee),
         {:ok, tax_lines} <- parse_tax_lines(Map.get(payload, "tax_lines", [])) do
      {:ok,
       %{
         woo_refund_id: woo_refund_id,
         header_amount: header_amount,
         reason: reason,
         source_created_at: source_created_at,
         line_items: line_items,
         shipping_refund_amount: shipping.amount,
         shipping_refund_tax: shipping.tax,
         fee_refund_amount: fees.amount,
         fee_refund_tax: fees.tax,
         unallocated_header_amount:
           unallocated_header_amount(header_amount, line_items, shipping, fees),
         tax_lines: tax_lines
       }}
    end
  end

  def parse(_payload), do: {:error, {:invalid_refund_payload, :payload, :not_map}}

  defp parse_line_items(lines) when is_list(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case parse_line_item(line) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_line_items(nil), do: {:ok, []}
  defp parse_line_items(_lines), do: {:error, {:invalid_refund_payload, :line_items, :not_list}}

  defp parse_line_item(line) when is_map(line) do
    with {:ok, woo_refund_line_item_id} <-
           required_positive_integer(line, "id", :refund_line_item_id),
         {:ok, woo_product_id} <- optional_product_id(line, "product_id", :product_id),
         {:ok, woo_variation_id} <- optional_product_id(line, "variation_id", :variation_id),
         {:ok, refunded_quantity} <- optional_quantity(line, "quantity", :quantity),
         {:ok, refund_subtotal_amount} <-
           optional_magnitude(line, "subtotal", :refund_subtotal),
         {:ok, refund_total_amount} <- optional_magnitude(line, "total", :refund_total),
         {:ok, refund_total_tax} <- optional_magnitude(line, "total_tax", :refund_total_tax) do
      {woo_refunded_item_id, binding_reason} = refunded_item_binding(line)

      {:ok,
       %{
         woo_refund_line_item_id: woo_refund_line_item_id,
         woo_refunded_item_id: woo_refunded_item_id,
         woo_product_id: woo_product_id,
         woo_variation_id: woo_variation_id,
         refunded_quantity: refunded_quantity,
         refund_subtotal_amount: refund_subtotal_amount,
         refund_total_amount: refund_total_amount,
         refund_total_tax: refund_total_tax,
         binding_reason: binding_reason,
         validation_reason: nil
       }}
    end
  end

  defp parse_line_item(_line),
    do: {:error, {:invalid_refund_payload, :refund_line, :not_map}}

  defp parse_component_lines(payload, key, field) do
    case Map.get(payload, key, []) do
      nil ->
        {:ok, %{amount: nil, tax: nil, present?: false}}

      [] ->
        {:ok, %{amount: nil, tax: nil, present?: false}}

      lines when is_list(lines) ->
        with {:ok, parsed} <- parse_components(lines, field) do
          {:ok,
           %{
             amount: sum_decimals(Enum.map(parsed, & &1.amount)),
             tax: sum_complete_taxes(parsed),
             present?: true
           }}
        end

      _other ->
        {:error, {:invalid_refund_payload, field_lines_field(field), :not_list}}
    end
  end

  defp parse_components(lines, field) do
    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case parse_component(line, field) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_component(line, field) when is_map(line) do
    with {:ok, amount} <- required_magnitude(line, "total", component_amount_field(field)),
         {:ok, tax} <- optional_magnitude(line, "total_tax", component_tax_field(field)) do
      {:ok, %{amount: amount, tax: tax}}
    end
  end

  defp parse_component(_line, field),
    do: {:error, {:invalid_refund_payload, field_lines_field(field), :not_map}}

  defp parse_tax_lines(lines) when is_list(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case parse_tax_line(line) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_tax_lines(nil), do: {:ok, []}
  defp parse_tax_lines(_lines), do: {:error, {:invalid_refund_payload, :tax_lines, :not_list}}

  defp parse_tax_line(line) when is_map(line) do
    with {:ok, tax_total} <- optional_magnitude(line, "tax_total", :tax_total),
         {:ok, shipping_tax_total} <-
           optional_magnitude(line, "shipping_tax_total", :shipping_tax_total),
         {:ok, rate_id} <- optional_positive_integer(line, "rate_id", :rate_id) do
      {:ok,
       %{
         rate_id: rate_id,
         label: optional_string_value(line, "label"),
         tax_total: tax_total,
         shipping_tax_total: shipping_tax_total
       }}
    end
  end

  defp parse_tax_line(_line),
    do: {:error, {:invalid_refund_payload, :tax_line, :not_map}}

  defp refunded_item_binding(line) do
    values =
      line
      |> Map.get("meta_data", [])
      |> metadata_values("_refunded_item_id")

    case values do
      [] -> {nil, "missing_refunded_item_id"}
      values -> normalize_refunded_item_values(values)
    end
  end

  defp metadata_values(metadata, key) when is_list(metadata) do
    metadata
    |> Enum.filter(&(metadata_key(&1) == key))
    |> Enum.map(&metadata_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp metadata_values(_metadata, _key), do: []

  defp normalize_refunded_item_values(values) do
    parsed = Enum.map(values, &positive_integer/1)

    if Enum.all?(parsed, &match?({:ok, _id}, &1)) do
      ids = parsed |> Enum.map(fn {:ok, id} -> id end) |> Enum.uniq()

      case ids do
        [id] -> {id, nil}
        _ids -> {nil, "conflicting_refunded_item_id"}
      end
    else
      {nil, "invalid_refunded_item_id"}
    end
  end

  defp metadata_key(%{"key" => key}) when is_binary(key), do: key
  defp metadata_key(%{key: key}) when is_binary(key), do: key
  defp metadata_key(_metadata), do: nil

  defp metadata_value(%{"value" => value}), do: value
  defp metadata_value(%{value: value}), do: value
  defp metadata_value(_metadata), do: nil

  defp optional_product_id(payload, key, field) do
    case Map.get(payload, key) do
      nil ->
        {:ok, nil}

      value ->
        case positive_integer(value) do
          {:ok, integer} -> {:ok, integer}
          :zero_or_negative -> {:ok, nil}
          :error -> {:error, {:invalid_refund_payload, field, :invalid}}
        end
    end
  end

  defp optional_quantity(payload, key, field) do
    case Map.get(payload, key) do
      nil ->
        {:ok, nil}

      value when is_integer(value) ->
        {:ok, abs(value)}

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} -> {:ok, abs(integer)}
          _other -> {:error, {:invalid_refund_payload, field, :invalid}}
        end

      _value ->
        {:error, {:invalid_refund_payload, field, :invalid}}
    end
  end

  defp required_positive_integer(payload, key, field) do
    case Map.get(payload, key) do
      nil ->
        {:error, {:invalid_refund_payload, field, :required}}

      value ->
        case positive_integer(value) do
          {:ok, integer} -> {:ok, integer}
          :zero_or_negative -> {:error, {:invalid_refund_payload, field, :must_be_positive}}
          :error -> {:error, {:invalid_refund_payload, field, :invalid}}
        end
    end
  end

  defp optional_positive_integer(payload, key, field) do
    case Map.get(payload, key) do
      nil ->
        {:ok, nil}

      value ->
        case positive_integer(value) do
          {:ok, integer} -> {:ok, integer}
          :zero_or_negative -> {:ok, nil}
          :error -> {:error, {:invalid_refund_payload, field, :invalid}}
        end
    end
  end

  defp optional_magnitude(payload, key, field) do
    case Map.get(payload, key) do
      nil ->
        {:ok, nil}

      value ->
        with {:ok, decimal} <- parse_decimal(value),
             false <- Decimal.nan?(decimal) or Decimal.inf?(decimal) do
          {:ok, Decimal.abs(decimal)}
        else
          true -> {:error, {:invalid_refund_payload, field, :invalid}}
          :error -> {:error, {:invalid_refund_payload, field, :invalid}}
        end
    end
  end

  defp required_magnitude(payload, key, field) do
    case Map.get(payload, key) do
      nil -> {:error, {:invalid_refund_payload, field, :required}}
      _value -> optional_magnitude(payload, key, field)
    end
  end

  defp optional_string(payload, key, field) do
    case Map.get(payload, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, blank_to_nil(value)}
      _value -> {:error, {:invalid_refund_payload, field, :invalid}}
    end
  end

  defp optional_string_value(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) -> blank_to_nil(value)
      _value -> nil
    end
  end

  defp optional_gmt_datetime(payload, key, field) do
    case Map.get(payload, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          {:error, _reason} -> {:error, {:invalid_refund_payload, field, :invalid}}
        end

      _value ->
        {:error, {:invalid_refund_payload, field, :invalid}}
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

  defp sum_decimals([]), do: nil
  defp sum_decimals(values), do: Enum.reduce(values, &Decimal.add/2)

  defp sum_complete_taxes(parsed) do
    taxes = Enum.map(parsed, & &1.tax)

    if Enum.all?(taxes, &match?(%Decimal{}, &1)) do
      Enum.reduce(taxes, &Decimal.add/2)
    end
  end

  defp unallocated_header_amount(header_amount, line_items, shipping, fees) do
    line_totals = Enum.map(line_items, & &1.refund_total_amount)
    amounts = line_totals ++ component_amounts(shipping) ++ component_amounts(fees)

    if Enum.all?(amounts, &match?(%Decimal{}, &1)) do
      residual = Decimal.sub(header_amount, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2))

      case Decimal.compare(residual, Decimal.new(0)) do
        :lt -> Decimal.new(0)
        _comparison -> residual
      end
    end
  end

  defp component_amounts(%{present?: false}), do: []
  defp component_amounts(%{amount: amount}), do: [amount]

  defp component_amount_field(:shipping), do: :shipping_total
  defp component_amount_field(:fee), do: :fee_total

  defp component_tax_field(:shipping), do: :shipping_total_tax
  defp component_tax_field(:fee), do: :fee_total_tax

  defp field_lines_field(:shipping), do: :shipping_lines
  defp field_lines_field(:fee), do: :fee_lines

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
