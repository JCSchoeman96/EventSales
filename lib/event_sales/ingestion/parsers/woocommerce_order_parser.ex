defmodule EventSales.Ingestion.Parsers.WoocommerceOrderParser do
  @moduledoc """
  Normalizes WooCommerce order webhook payloads into EventSales sales attrs.
  """

  @type error :: {:invalid_order_payload, atom(), atom()}
  @type result :: {:ok, map()} | {:error, error()}

  @doc """
  Parses a WooCommerce order payload into normalized order, line item, and coupon maps.
  """
  @spec parse(map()) :: result()
  def parse(payload) when is_map(payload) do
    with {:ok, woo_order_id} <- required_integer(payload, "id", :id),
         {:ok, status} <- parse_status(Map.get(payload, "status")),
         {:ok, currency} <- required_string(payload, "currency", :currency),
         {:ok, created_at_source} <-
           required_gmt_datetime(payload, "date_created_gmt", :date_created_gmt),
         {:ok, updated_at_source} <-
           required_gmt_datetime(payload, "date_modified_gmt", :date_modified_gmt),
         {:ok, completed_at} <-
           optional_gmt_datetime(payload, "date_completed_gmt", :date_completed_gmt),
         {:ok, raw_total} <- required_decimal(payload, "total", :total),
         {:ok, raw_discount_total} <- optional_decimal(payload, "discount_total", :discount_total),
         {:ok, raw_tax_total} <- optional_decimal(payload, "total_tax", :total_tax),
         {:ok, line_items} <- parse_line_items(Map.get(payload, "line_items", [])),
         {:ok, coupons} <- parse_coupons(Map.get(payload, "coupon_lines", [])) do
      {:ok,
       %{
         woo_order_id: woo_order_id,
         order_number: blank_to_nil(Map.get(payload, "number")),
         status: status,
         currency: currency,
         completed_at: completed_at,
         created_at_source: created_at_source,
         updated_at_source: updated_at_source,
         customer_name: customer_name(Map.get(payload, "billing")),
         customer_email: customer_email(Map.get(payload, "billing")),
         raw_total: raw_total,
         raw_discount_total: raw_discount_total,
         raw_tax_total: raw_tax_total,
         payment_method: blank_to_nil(Map.get(payload, "payment_method")),
         payment_method_title: blank_to_nil(Map.get(payload, "payment_method_title")),
         payment_gateway_transaction_id: blank_to_nil(Map.get(payload, "transaction_id")),
         line_items: line_items,
         coupons: coupons
       }}
    end
  end

  def parse(_payload), do: {:error, {:invalid_order_payload, :payload, :not_map}}

  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status("processing"), do: {:ok, :processing}
  defp parse_status("on-hold"), do: {:ok, :on_hold}
  defp parse_status("on_hold"), do: {:ok, :on_hold}
  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("cancelled"), do: {:ok, :cancelled}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("failed"), do: {:ok, :failed}
  defp parse_status(_status), do: {:error, {:invalid_order_payload, :status, :unsupported}}

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

  defp parse_line_items(_lines), do: {:error, {:invalid_order_payload, :line_items, :not_list}}

  defp parse_line_item(line) when is_map(line) do
    with {:ok, woo_line_item_id} <- required_integer(line, "id", :line_item_id),
         {:ok, woo_product_id} <- required_integer(line, "product_id", :product_id),
         {:ok, quantity} <- positive_integer(line, "quantity", :quantity),
         {:ok, line_subtotal} <- required_decimal(line, "subtotal", :line_subtotal),
         {:ok, line_total} <- required_decimal(line, "total", :line_total),
         {:ok, woo_variation_id} <- optional_integer(line, "variation_id", :variation_id),
         {:ok, discount_total} <- line_discount_total(line, line_subtotal, line_total) do
      {:ok,
       %{
         woo_line_item_id: woo_line_item_id,
         woo_product_id: woo_product_id,
         woo_variation_id: zero_to_nil(woo_variation_id),
         name: blank_to_nil(Map.get(line, "name")),
         quantity: quantity,
         line_subtotal: line_subtotal,
         line_total: line_total,
         discount_total: discount_total,
         item_kind: :unknown,
         mapping_status: :pending_mapping_resolution
       }}
    end
  end

  defp parse_line_item(_line), do: {:error, {:invalid_order_payload, :line_item, :not_map}}

  defp parse_coupons(coupons) when is_list(coupons) do
    coupons
    |> Enum.reduce_while({:ok, []}, fn coupon, {:ok, acc} ->
      case parse_coupon(coupon) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_coupons(nil), do: {:ok, []}
  defp parse_coupons(_coupons), do: {:error, {:invalid_order_payload, :coupon_lines, :not_list}}

  defp parse_coupon(coupon) when is_map(coupon) do
    with {:ok, code} <- required_string(coupon, "code", :coupon_code),
         {:ok, discount_amount} <- required_decimal(coupon, "discount", :coupon_discount),
         {:ok, discount_tax} <- optional_decimal(coupon, "discount_tax", :coupon_discount_tax) do
      {:ok,
       %{
         code: code,
         discount_amount: discount_amount,
         discount_tax: discount_tax
       }}
    end
  end

  defp parse_coupon(_coupon), do: {:error, {:invalid_order_payload, :coupon, :not_map}}

  defp line_discount_total(line, line_subtotal, line_total) do
    case Map.fetch(line, "discount_total") do
      {:ok, value} -> parse_decimal(value, :discount_total, false)
      :error -> {:ok, Decimal.sub(line_subtotal, line_total)}
    end
  end

  defp required_integer(payload, key, field) do
    case Map.get(payload, key) do
      value when is_integer(value) -> {:ok, value}
      nil -> {:error, {:invalid_order_payload, field, :required}}
      _value -> {:error, {:invalid_order_payload, field, :invalid}}
    end
  end

  defp optional_integer(payload, key, field) do
    case Map.get(payload, key) do
      value when is_integer(value) -> {:ok, value}
      nil -> {:ok, nil}
      _value -> {:error, {:invalid_order_payload, field, :invalid}}
    end
  end

  defp positive_integer(payload, key, field) do
    case required_integer(payload, key, field) do
      {:ok, value} when value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_order_payload, field, :must_be_positive}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp required_string(payload, key, field) do
    case blank_to_nil(Map.get(payload, key)) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, {:invalid_order_payload, field, :required}}
      _value -> {:error, {:invalid_order_payload, field, :invalid}}
    end
  end

  defp required_decimal(payload, key, field),
    do: parse_decimal(Map.get(payload, key), field, true)

  defp optional_decimal(payload, key, field),
    do: parse_decimal(Map.get(payload, key), field, false)

  defp parse_decimal(nil, field, true), do: {:error, {:invalid_order_payload, field, :required}}
  defp parse_decimal(nil, _field, false), do: {:ok, Decimal.new("0")}

  defp parse_decimal(value, field, _required) when is_binary(value) do
    {:ok, Decimal.new(value)}
  rescue
    Decimal.Error -> {:error, {:invalid_order_payload, field, :invalid}}
  end

  defp parse_decimal(_value, field, _required),
    do: {:error, {:invalid_order_payload, field, :invalid}}

  defp required_gmt_datetime(payload, key, field) do
    case optional_gmt_datetime(payload, key, field) do
      {:ok, %DateTime{} = datetime} -> {:ok, datetime}
      {:ok, nil} -> {:error, {:invalid_order_payload, field, :required}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_gmt_datetime(payload, key, field) do
    case blank_to_nil(Map.get(payload, key)) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        value
        |> NaiveDateTime.from_iso8601()
        |> case do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          {:error, _reason} -> {:error, {:invalid_order_payload, field, :invalid}}
        end

      _value ->
        {:error, {:invalid_order_payload, field, :invalid}}
    end
  end

  defp customer_name(%{"first_name" => first_name, "last_name" => last_name}) do
    [first_name, last_name]
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> blank_to_nil()
  end

  defp customer_name(_billing), do: nil

  defp customer_email(%{"email" => email}), do: blank_to_nil(email)
  defp customer_email(_billing), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp zero_to_nil(0), do: nil
  defp zero_to_nil(value), do: value
end
