defmodule EventSales.Ingestion.Csv.ApplyImport do
  @moduledoc """
  Applies validated CSV import rows to durable sales truth.
  """

  require Ash.Query

  alias EventSales.Analytics.OrderProcessedNotifier
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{CsvImportBatch, CsvImportRow}
  alias EventSales.Repo
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Telemetry

  @status_map %{
    "pending" => :pending,
    "processing" => :processing,
    "on-hold" => :on_hold,
    "on_hold" => :on_hold,
    "completed" => :completed,
    "cancelled" => :cancelled,
    "refunded" => :refunded,
    "failed" => :failed
  }
  @statuses Map.values(@status_map)

  @doc "Applies a validated CSV import batch."
  @spec apply(Ecto.UUID.t(), keyword()) :: {:ok, CsvImportBatch.t()} | {:error, term()}
  def apply(batch_id, opts \\ []) when is_binary(batch_id) do
    case Ash.get(CsvImportBatch, batch_id, domain: Ingestion) do
      {:ok, %CsvImportBatch{} = batch} -> apply_batch(batch, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_batch(%CsvImportBatch{status: :applied} = batch, _opts), do: {:ok, batch}

  defp apply_batch(%CsvImportBatch{status: status}, _opts)
       when status not in [:dry_run_passed, :applying],
       do: {:error, :invalid_status}

  defp apply_batch(%CsvImportBatch{} = batch, opts) do
    Telemetry.emit(Telemetry.csv_import_apply_start(), %{system_time: System.system_time()}, %{
      batch_id: batch.id,
      event_id: batch.event_id,
      source: :csv
    })

    with {:ok, applying} <- ensure_applying(batch),
         {:ok, event} <- Ash.get(Event, applying.event_id, domain: Catalog),
         {:ok, rows} <- rows_for_apply(applying.id),
         {:ok, applied} <- apply_rows(applying, event, rows, opts) do
      Telemetry.emit(Telemetry.csv_import_apply_stop(), stop_measurements(applied, rows), %{
        batch_id: applied.id,
        event_id: applied.event_id,
        status: applied.status,
        source: :csv
      })

      {:ok, applied}
    else
      {:error, reason} = error ->
        Telemetry.emit(Telemetry.csv_import_apply_exception(), %{count: 1}, %{
          batch_id: batch.id,
          event_id: batch.event_id,
          reason: sanitize_reason(reason),
          source: :csv
        })

        error
    end
  end

  defp ensure_applying(%CsvImportBatch{status: :applying} = batch), do: {:ok, batch}

  defp ensure_applying(%CsvImportBatch{status: :dry_run_passed} = batch) do
    Ash.update(batch, %{}, action: :mark_applying, domain: Ingestion)
  end

  defp rows_for_apply(batch_id) do
    CsvImportRow
    |> Ash.Query.filter(csv_import_batch_id == ^batch_id and status in [:valid, :applied])
    |> Ash.Query.sort(row_number: :asc)
    |> Ash.read(domain: Ingestion)
  end

  defp apply_rows(batch, _event, rows, _opts) when rows == [] do
    mark_batch_applied(batch)
  end

  defp apply_rows(batch, event, rows, opts) do
    valid_rows = Enum.filter(rows, &(&1.status == :valid))

    if valid_rows == [] do
      mark_batch_applied(batch)
    else
      valid_rows |> grouped_rows() |> apply_groups(batch, event, opts)
    end
  end

  defp grouped_rows(valid_rows) do
    valid_rows
    |> Enum.group_by(&group_key/1)
    |> Enum.sort_by(fn {key, _rows} -> key end)
  end

  defp apply_groups(groups, batch, event, opts) do
    groups
    |> Enum.reduce_while({:ok, batch}, fn {_key, group_rows}, {:ok, current_batch} ->
      case apply_group(current_batch, event, group_rows, opts) do
        {:ok, _order} -> {:cont, {:ok, current_batch}}
        {:error, reason} -> {:halt, fail_group(current_batch, group_rows, reason)}
      end
    end)
    |> finalize_groups()
  end

  defp finalize_groups({:ok, batch}), do: mark_batch_applied(batch)
  defp finalize_groups({:error, reason}), do: {:error, reason}

  defp apply_group(batch, event, rows, opts) do
    with {:ok, normalized_order} <- build_order(rows),
         {:ok, order} <- upsert_group(event.source_system_id, normalized_order, opts) do
      notifier(opts).notify_order_imported(order, batch, event.id, opts)

      case mark_rows_applied(rows) do
        :ok -> {:ok, order}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp upsert_group(source_system_id, normalized_order, opts) do
    upserter = Keyword.get(opts, :order_upserter, OrderUpserter)

    Repo.transaction(fn ->
      case upserter.upsert_normalized_order(source_system_id, normalized_order) do
        {:ok, :stale_noop} -> Repo.rollback(:stale_noop)
        {:ok, order} -> order
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, order} -> {:ok, order}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_order(rows) do
    with {:ok, line_items} <- convert_lines(rows),
         first <- hd(line_items) do
      {:ok,
       %{
         woo_order_id: first.woo_order_id,
         order_number: first.order_number,
         status: first.status,
         currency: first.currency,
         completed_at: first.completed_at,
         created_at_source: first.created_at_source,
         updated_at_source: first.updated_at_source,
         customer_name: first.customer_name,
         customer_email: first.customer_email,
         raw_total: first.raw_total,
         raw_discount_total: first.raw_discount_total,
         raw_tax_total: first.raw_tax_total,
         payment_method: first.payment_method,
         payment_method_title: first.payment_method_title,
         payment_gateway_transaction_id: first.payment_gateway_transaction_id,
         coupons: [],
         line_items: Enum.map(line_items, & &1.line_item)
       }}
    end
  end

  defp convert_lines(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case convert_row(row) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp convert_row(%CsvImportRow{normalized_data: data}) when is_map(data) do
    with {:ok, woo_order_id} <- integer(data, "woo_order_id"),
         {:ok, woo_line_item_id} <- integer(data, "woo_line_item_id"),
         {:ok, woo_product_id} <- integer(data, "woo_product_id"),
         {:ok, woo_variation_id} <- optional_integer(data, "woo_variation_id"),
         {:ok, quantity} <- integer(data, "quantity"),
         {:ok, status} <- status(data),
         {:ok, created_at_source} <- datetime(data, "created_at_source"),
         {:ok, updated_at_source} <- datetime(data, "updated_at_source"),
         {:ok, completed_at} <- optional_datetime(data, "completed_at"),
         {:ok, line_subtotal} <- decimal(data, "line_subtotal"),
         {:ok, line_total} <- decimal(data, "line_total"),
         {:ok, discount_total} <- decimal(data, "line_discount_total"),
         {:ok, raw_total} <- decimal(data, "order_raw_total"),
         {:ok, raw_discount_total} <- decimal(data, "order_raw_discount_total"),
         {:ok, raw_tax_total} <- decimal(data, "order_raw_tax_total"),
         {:ok, event_id} <- uuid(data, "event_id"),
         {:ok, ticket_type_id} <- uuid(data, "ticket_type_id") do
      {:ok,
       %{
         woo_order_id: woo_order_id,
         order_number: string(data, "order_number"),
         status: status,
         currency: string(data, "currency"),
         completed_at: completed_at,
         created_at_source: created_at_source,
         updated_at_source: updated_at_source,
         customer_name: string(data, "customer_name"),
         customer_email: string(data, "customer_email"),
         raw_total: raw_total,
         raw_discount_total: raw_discount_total,
         raw_tax_total: raw_tax_total,
         payment_method: string(data, "payment_method"),
         payment_method_title: string(data, "payment_method_title"),
         payment_gateway_transaction_id: string(data, "payment_gateway_transaction_id"),
         line_item: %{
           woo_line_item_id: woo_line_item_id,
           woo_product_id: woo_product_id,
           woo_variation_id: woo_variation_id,
           name: string(data, "name"),
           quantity: quantity,
           line_subtotal: line_subtotal,
           line_total: line_total,
           discount_total: discount_total,
           event_id: event_id,
           ticket_type_id: ticket_type_id,
           item_kind: :ticket,
           mapping_status: :mapped
         }
       }}
    end
  end

  defp convert_row(_row), do: {:error, :invalid_normalized_data}

  defp group_key(%CsvImportRow{normalized_data: %{"woo_order_id" => value}}), do: to_string(value)
  defp group_key(%CsvImportRow{id: id}), do: "invalid:#{id}"

  defp mark_rows_applied(rows) do
    applied_at = DateTime.utc_now()

    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case Ash.update(row, %{applied_at: applied_at}, action: :mark_applied, domain: Ingestion) do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fail_group(batch, rows, reason) do
    message = sanitize_reason(reason)

    Enum.each(rows, fn row ->
      _ =
        Ash.update(row, %{error_messages: [message]}, action: :mark_failed, domain: Ingestion)
    end)

    _ = Ash.update(batch, %{last_error: message}, action: :mark_failed, domain: Ingestion)
    {:error, reason}
  end

  defp mark_batch_applied(batch) do
    Ash.update(batch, %{applied_at: DateTime.utc_now()}, action: :mark_applied, domain: Ingestion)
  end

  defp integer(data, key) do
    case Map.get(data, key) do
      value when is_integer(value) -> {:ok, value}
      value when is_binary(value) -> parse_integer(value, key)
      _value -> {:error, {:invalid_integer, key}}
    end
  end

  defp optional_integer(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      0 -> {:ok, nil}
      "0" -> {:ok, nil}
      value -> integer(%{key => value}, key)
    end
  end

  defp parse_integer(value, key) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> {:error, {:invalid_integer, key}}
    end
  end

  defp decimal(data, key) do
    case Map.get(data, key) do
      %Decimal{} = decimal ->
        {:ok, decimal}

      value when is_integer(value) or is_float(value) or is_binary(value) ->
        {:ok, Decimal.new(to_string(value))}

      _value ->
        {:error, {:invalid_decimal, key}}
    end
  rescue
    Decimal.Error -> {:error, {:invalid_decimal, key}}
  end

  defp datetime(data, key) do
    case parse_datetime(Map.get(data, key)) do
      {:ok, datetime} -> {:ok, datetime}
      :error -> {:error, {:invalid_datetime, key}}
    end
  end

  defp optional_datetime(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value -> datetime(%{key => value}, key)
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: {:ok, datetime}

  defp parse_datetime(value) when is_binary(value) do
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

  defp parse_datetime(_value), do: :error

  defp status(data) do
    case Map.get(data, "status") do
      status when is_atom(status) and status in @statuses -> {:ok, status}
      status when is_binary(status) -> fetch_status(status)
      _value -> {:error, :invalid_status}
    end
  end

  defp fetch_status(status) do
    case Map.fetch(@status_map, status) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_status}
    end
  end

  defp uuid(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, {:invalid_uuid, key}}
        end

      _value ->
        {:error, {:invalid_uuid, key}}
    end
  end

  defp string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp notifier(opts), do: Keyword.get(opts, :order_processed_notifier, OrderProcessedNotifier)

  defp stop_measurements(_batch, rows) do
    %{
      row_count: length(rows),
      applied_count: Enum.count(rows, &(&1.status == :applied)),
      valid_count: Enum.count(rows, &(&1.status == :valid))
    }
  end

  defp sanitize_reason(:stale_noop), do: "stale source update"
  defp sanitize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sanitize_reason({reason, key}) when is_atom(reason), do: "#{reason}:#{key}"
  defp sanitize_reason(reason), do: reason |> inspect() |> String.slice(0, 255)
end
