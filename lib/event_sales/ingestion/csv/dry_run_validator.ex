defmodule EventSales.Ingestion.Csv.DryRunValidator do
  @moduledoc """
  Validates event-scoped CSV import rows without mutating sales truth.
  """

  require Ash.Query

  alias EventSales.Catalog.MappingResolver
  alias EventSales.Ingestion.Csv.Parser
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}

  @chunk_size 500
  @statuses ~w(pending processing on-hold on_hold completed cancelled refunded failed)
  @money_fields ~w(line_subtotal line_total line_discount_total order_raw_total order_raw_discount_total order_raw_tax_total)
  @required_money_fields ~w(line_subtotal line_total order_raw_total)
  @optional_money_fields ~w(line_discount_total order_raw_discount_total order_raw_tax_total)

  @type result :: %{
          row_count: non_neg_integer(),
          valid_count: non_neg_integer(),
          error_count: non_neg_integer(),
          duplicate_count: non_neg_integer(),
          rows: [map()]
        }

  @doc """
  Validates a CSV file against existing mappings and durable sales identities.
  """
  @spec validate_file(Path.t(), %{event_id: Ecto.UUID.t(), source_system_id: Ecto.UUID.t()}) ::
          {:ok, result()} | {:error, term()}
  def validate_file(path, %{event_id: event_id, source_system_id: source_system_id}) do
    with {:ok, stream} <- Parser.stream_rows(path) do
      initial = %{seen: MapSet.new(), rows: [], row_count: 0, valid_count: 0, duplicate_count: 0}

      result =
        stream
        |> Stream.chunk_every(@chunk_size)
        |> Enum.reduce(initial, fn rows, acc ->
          Enum.reduce(rows, acc, &validate_row(&1, &2, event_id, source_system_id))
        end)

      rows = Enum.reverse(result.rows)
      error_count = Enum.count(rows, &(&1.status != :valid))

      {:ok,
       %{
         row_count: result.row_count,
         valid_count: result.valid_count,
         error_count: error_count,
         duplicate_count: result.duplicate_count,
         rows: rows
       }}
    end
  rescue
    error in NimbleCSV.ParseError -> {:error, {:invalid_csv, Exception.message(error)}}
    error in File.Error -> {:error, {:file_error, Exception.message(error)}}
  end

  defp validate_row(%{row_number: row_number, raw: raw}, acc, event_id, source_system_id) do
    {normalized, errors} = normalize(raw, event_id, source_system_id)
    key = duplicate_key(normalized, raw)
    duplicate_in_file? = key && MapSet.member?(acc.seen, key)
    durable_duplicate? = key && durable_duplicate?(source_system_id, normalized)

    duplicate_errors =
      cond do
        duplicate_in_file? -> ["duplicate row in CSV"]
        durable_duplicate? -> ["line already exists in EventSales"]
        true -> []
      end

    errors = errors ++ duplicate_errors

    row = %{
      row_number: row_number,
      raw_data: raw,
      normalized_data: normalized,
      status: row_status(errors, duplicate_errors),
      error_messages: errors,
      external_order_number: blank_to_nil(raw["order_number"]),
      external_line_key: key
    }

    update_acc(acc, row, key)
  end

  defp row_status(errors, duplicate_errors) do
    cond do
      duplicate_errors != [] -> :duplicate
      errors == [] -> :valid
      true -> :invalid
    end
  end

  defp update_acc(acc, row, key) do
    %{
      acc
      | seen: if(key, do: MapSet.put(acc.seen, key), else: acc.seen),
        rows: [row | acc.rows],
        row_count: acc.row_count + 1,
        valid_count: acc.valid_count + if(row.status == :valid, do: 1, else: 0),
        duplicate_count: acc.duplicate_count + if(row.status == :duplicate, do: 1, else: 0)
    }
  end

  defp normalize(raw, event_id, source_system_id) do
    {normalized, errors} =
      {%{}, []}
      |> put_integer(raw, "woo_order_id", required?: true)
      |> put_integer(raw, "woo_line_item_id", required?: true)
      |> put_integer(raw, "woo_product_id", required?: true)
      |> put_variation(raw)
      |> put_quantity(raw)
      |> put_money_fields(raw)
      |> put_status(raw)
      |> put_datetime(raw, "created_at_source", required?: true)
      |> put_datetime(raw, "updated_at_source", required?: true)
      |> put_datetime(raw, "completed_at", required?: false)
      |> put_required_string(raw, "order_number")
      |> put_currency(raw)
      |> put_string(raw, "name")
      |> put_string(raw, "customer_name")
      |> put_string(raw, "customer_email")
      |> put_string(raw, "payment_method")
      |> put_string(raw, "payment_method_title")
      |> put_string(raw, "payment_gateway_transaction_id")

    {mapping_attrs, mapping_errors} = validate_mapping(normalized, event_id, source_system_id)
    {Map.merge(normalized, mapping_attrs), errors ++ mapping_errors}
  end

  defp put_integer({normalized, errors}, raw, field, opts) do
    value = blank_to_nil(raw[field])

    cond do
      value == nil and Keyword.get(opts, :required?, false) ->
        {normalized, errors ++ ["#{field} is required"]}

      value == nil ->
        {normalized, errors}

      true ->
        case Integer.parse(value) do
          {integer, ""} -> {Map.put(normalized, field, integer), errors}
          _ -> {normalized, errors ++ ["#{field} must be an integer"]}
        end
    end
  end

  defp put_variation({normalized, errors}, raw) do
    case blank_to_nil(raw["woo_variation_id"]) do
      nil ->
        {Map.put(normalized, "woo_variation_id", nil), errors}

      "0" ->
        {Map.put(normalized, "woo_variation_id", nil), errors}

      value ->
        case Integer.parse(value) do
          {integer, ""} -> {Map.put(normalized, "woo_variation_id", integer), errors}
          _ -> {normalized, errors ++ ["woo_variation_id must be an integer"]}
        end
    end
  end

  defp put_quantity({normalized, errors}, raw) do
    case Integer.parse(raw["quantity"] || "") do
      {quantity, ""} when quantity > 0 ->
        {Map.put(normalized, "quantity", quantity), errors}

      _ ->
        {normalized, errors ++ ["quantity must be a positive integer"]}
    end
  end

  defp put_money_fields(acc, raw) do
    Enum.reduce(@money_fields, acc, &put_money_field(&2, raw, &1))
  end

  defp put_money_field({normalized, errors}, raw, field) do
    value = blank_to_nil(raw[field])

    cond do
      value == nil and field in @required_money_fields ->
        {normalized, errors ++ ["#{field} is required"]}

      value == nil and field in @optional_money_fields ->
        {Map.put(normalized, field, Decimal.new("0")), errors}

      true ->
        put_parsed_money(normalized, errors, field, value)
    end
  end

  defp put_parsed_money(normalized, errors, field, value) do
    case parse_non_negative_decimal(value) do
      {:ok, decimal} -> {Map.put(normalized, field, decimal), errors}
      :error -> {normalized, errors ++ ["#{field} must be a non-negative money value"]}
    end
  end

  defp put_status({normalized, errors}, raw) do
    case raw["status"] do
      status when status in @statuses -> {Map.put(normalized, "status", status), errors}
      _ -> {normalized, errors ++ ["status is unsupported"]}
    end
  end

  defp put_datetime({normalized, errors}, raw, field, opts) do
    value = blank_to_nil(raw[field])

    cond do
      value == nil and Keyword.get(opts, :required?, false) ->
        {normalized, errors ++ ["#{field} is required"]}

      value == nil ->
        {normalized, errors}

      true ->
        case parse_datetime(value) do
          {:ok, datetime} -> {Map.put(normalized, field, DateTime.to_iso8601(datetime)), errors}
          :error -> {normalized, errors ++ ["#{field} must be a UTC datetime"]}
        end
    end
  end

  defp put_string({normalized, errors}, raw, field) do
    {Map.put(normalized, field, blank_to_nil(raw[field])), errors}
  end

  defp put_required_string({normalized, errors}, raw, field) do
    case blank_to_nil(raw[field]) do
      nil -> {normalized, errors ++ ["#{field} is required"]}
      value -> {Map.put(normalized, field, value), errors}
    end
  end

  defp put_currency({normalized, errors}, raw) do
    case blank_to_nil(raw["currency"]) do
      nil ->
        {normalized, errors ++ ["currency is required"]}

      <<_::binary-size(3)>> = currency ->
        if Regex.match?(~r/^[A-Z]{3}$/, currency) do
          {Map.put(normalized, "currency", currency), errors}
        else
          {normalized, errors ++ ["currency must be a 3-letter uppercase code"]}
        end

      _currency ->
        {normalized, errors ++ ["currency must be a 3-letter uppercase code"]}
    end
  end

  defp validate_mapping(
         %{"woo_product_id" => product_id, "woo_variation_id" => variation_id},
         event_id,
         source_system_id
       ) do
    case MappingResolver.resolve(source_system_id, product_id, variation_id) do
      {:ok, {:mapped, mapping}} ->
        if mapping.event_id == event_id do
          {%{"event_id" => mapping.event_id, "ticket_type_id" => mapping.ticket_type_id}, []}
        else
          {%{}, ["mapping belongs to a different event"]}
        end

      {:ok, :pending_mapping_resolution} ->
        variation = variation_id || "none"
        {%{}, ["unknown mapping for product #{product_id} variation #{variation}"]}

      {:error, _reason} ->
        {%{}, ["mapping lookup failed"]}
    end
  end

  defp validate_mapping(_normalized, _event_id, _source_system_id), do: {%{}, []}

  defp duplicate_key(%{"woo_order_id" => order_id, "woo_line_item_id" => line_id}, _raw),
    do: "#{order_id}:#{line_id}"

  defp duplicate_key(_normalized, _raw), do: nil

  defp durable_duplicate?(source_system_id, %{
         "woo_order_id" => woo_order_id,
         "woo_line_item_id" => woo_line_item_id
       }) do
    case find_order(source_system_id, woo_order_id) do
      {:ok, nil} -> false
      {:ok, order} -> order_item_exists?(order.id, woo_line_item_id)
      {:error, _reason} -> false
    end
  end

  defp durable_duplicate?(_source_system_id, _normalized), do: false

  defp find_order(source_system_id, woo_order_id) do
    Order
    |> Ash.Query.filter(source_system_id == ^source_system_id and woo_order_id == ^woo_order_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Sales)
  end

  defp order_item_exists?(order_id, woo_line_item_id) do
    OrderItem
    |> Ash.Query.filter(order_id == ^order_id and woo_line_item_id == ^woo_line_item_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(domain: Sales)
    |> is_struct(OrderItem)
  end

  defp parse_non_negative_decimal(value) do
    decimal = Decimal.new(value)

    if Decimal.compare(decimal, Decimal.new("0")) in [:eq, :gt] do
      {:ok, decimal}
    else
      :error
    end
  rescue
    Decimal.Error -> :error
  end

  defp parse_datetime(value) do
    if String.ends_with?(value, "Z") do
      case DateTime.from_iso8601(value) do
        {:ok, datetime, _offset} -> {:ok, datetime}
        {:error, _reason} -> :error
      end
    else
      case NaiveDateTime.from_iso8601(value) do
        {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
        {:error, _reason} -> :error
      end
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
