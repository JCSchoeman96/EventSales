defmodule EventSales.Ingestion.CsvImports do
  @moduledoc """
  Admin facade for CSV import dry-runs.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Audit.Logger, as: AuditLogger
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Csv.DryRunValidator
  alias EventSales.Ingestion.Resources.{CsvImportBatch, CsvImportRow}
  alias EventSales.Ingestion.Workers.ProcessCsvImportWorker
  alias EventSales.Telemetry

  @default_limit 50
  @max_limit 200

  @doc "Runs an event-scoped CSV dry-run and persists batch/row results."
  @spec dry_run_file(Path.t(), map(), keyword()) ::
          {:ok, CsvImportBatch.t()} | {:error, term()}
  def dry_run_file(path, attrs, opts \\ []) do
    with :ok <- authorize_admin(opts),
         {:ok, event_id} <- fetch_event_id(attrs),
         {:ok, %Event{} = event} <- Ash.get(Event, event_id, domain: Catalog),
         {:ok, batch} <- create_batch(event, attrs, opts) do
      Telemetry.emit(
        Telemetry.csv_import_dry_run_start(),
        %{system_time: System.system_time()},
        %{
          event_id: event.id,
          batch_id: batch.id
        }
      )

      run_validation(path, batch, event)
    else
      {:ok, nil} -> {:error, :invalid_event}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_batches(opts \\ []) do
    with :ok <- authorize_admin(opts) do
      CsvImportBatch
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(limit(opts))
      |> Ash.read(domain: Ingestion)
    end
  end

  def get_batch(id, opts \\ []) do
    with :ok <- authorize_admin(opts) do
      Ash.get(CsvImportBatch, id, domain: Ingestion)
    end
  end

  @doc "Queues a validated CSV dry-run for asynchronous apply."
  @spec queue_apply(Ecto.UUID.t(), keyword()) ::
          {:ok, %{batch: CsvImportBatch.t(), job: Oban.Job.t()}}
          | {:error,
             :forbidden | :not_found | :invalid_status | :empty_batch | :enqueue_failed | term()}
  def queue_apply(batch_id, opts \\ []) when is_binary(batch_id) do
    with :ok <- authorize_admin(opts),
         {:ok, %CsvImportBatch{} = batch} <- Ash.get(CsvImportBatch, batch_id, domain: Ingestion),
         :ok <- validate_applyable(batch),
         {:ok, job} <- enqueue_apply(batch, opts),
         {:ok, _audit} <- audit_apply_requested(batch, opts) do
      {:ok, %{batch: batch, job: job}}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_rows(batch_id, opts \\ []) do
    with :ok <- authorize_admin(opts) do
      CsvImportRow
      |> Ash.Query.filter(csv_import_batch_id == ^batch_id)
      |> Ash.Query.sort(row_number: :asc)
      |> Ash.Query.limit(limit(opts))
      |> Ash.read(domain: Ingestion)
    end
  end

  defp run_validation(path, batch, event) do
    with {:ok, validating} <- update_batch(batch, :mark_validating, %{}),
         {:ok, result} <-
           validate_file(path, %{
             event_id: event.id,
             source_system_id: event.source_system_id
           }),
         :ok <- store_rows(validating, result.rows),
         {:ok, final_batch} <- finalize_batch(validating, result) do
      Telemetry.emit(Telemetry.csv_import_dry_run_stop(), stop_measurements(result), %{
        event_id: event.id,
        batch_id: final_batch.id,
        status: final_batch.status
      })

      {:ok, final_batch}
    else
      {:error, reason} ->
        {:ok, failed} = update_batch(batch, :mark_failed, %{last_error: inspect(reason)})

        Telemetry.emit(Telemetry.csv_import_dry_run_exception(), %{count: 1}, %{
          event_id: event.id,
          batch_id: failed.id,
          reason: inspect(reason)
        })

        {:ok, failed}
    end
  end

  defp validate_file(path, attrs) do
    DryRunValidator.validate_file(path, attrs)
  rescue
    error in NimbleCSV.ParseError -> {:error, {:invalid_csv, Exception.message(error)}}
    error in File.Error -> {:error, {:file_error, Exception.message(error)}}
  end

  defp finalize_batch(batch, result) do
    attrs = Map.take(result, [:row_count, :valid_count, :error_count, :duplicate_count])

    action =
      if result.error_count == 0 do
        :mark_dry_run_passed
      else
        :mark_dry_run_failed
      end

    update_batch(batch, action, attrs)
  end

  defp create_batch(event, attrs, opts) do
    CsvImportBatch
    |> Ash.Changeset.for_create(:create_dry_run, %{
      event_id: event.id,
      uploaded_by_user_id: Keyword.fetch!(opts, :actor).id,
      source_filename:
        sanitize_filename(Map.get(attrs, :source_filename) || Map.get(attrs, "source_filename"))
    })
    |> Ash.create(domain: Ingestion)
  end

  defp store_rows(batch, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      attrs = %{
        csv_import_batch_id: batch.id,
        row_number: row.row_number,
        raw_data: row.raw_data,
        normalized_data: json_safe(row.normalized_data),
        status: row.status,
        error_messages: row.error_messages,
        external_order_number: row.external_order_number,
        external_line_key: row.external_line_key
      }

      case Ash.create(CsvImportRow, attrs, action: :store_validation_result, domain: Ingestion) do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_batch(batch, action, attrs) do
    batch
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update(domain: Ingestion)
  end

  defp fetch_event_id(attrs) do
    case Map.get(attrs, :event_id) || Map.get(attrs, "event_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :event_required}
    end
  end

  defp authorize_admin(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp validate_applyable(%CsvImportBatch{status: status}) when status != :dry_run_passed,
    do: {:error, :invalid_status}

  defp validate_applyable(%CsvImportBatch{valid_count: 0}), do: {:error, :empty_batch}

  defp validate_applyable(%CsvImportBatch{}), do: :ok

  defp audit_apply_requested(batch, opts) do
    actor = Keyword.get(opts, :actor)

    %{
      actor_type: :user,
      actor_user_id: actor && actor.id,
      actor_role: :admin,
      subject_type: "csv_import_batch",
      subject_id: batch.id,
      event_id: batch.event_id,
      source: :csv,
      metadata: %{
        "result" => "queued",
        "row_count" => batch.row_count,
        "valid_count" => batch.valid_count,
        "error_count" => batch.error_count,
        "duplicate_count" => batch.duplicate_count,
        "source_filename" => batch.source_filename
      }
    }
    |> AuditLogger.csv_apply_requested()
  end

  defp enqueue_apply(%CsvImportBatch{id: batch_id}, opts) do
    oban_insert = Keyword.get(opts, :oban_insert, &Oban.insert/1)

    case batch_id
         |> then(&%{"csv_import_batch_id" => &1})
         |> ProcessCsvImportWorker.new()
         |> oban_insert.() do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp sanitize_filename(nil), do: "import.csv"
  defp sanitize_filename(filename), do: filename |> Path.basename() |> String.slice(0, 255)

  defp stop_measurements(result) do
    Map.take(result, [:row_count, :valid_count, :error_count, :duplicate_count])
  end

  defp json_safe(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp json_safe(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe(value), do: value

  defp limit(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> normalize_limit()
    |> min(@max_limit)
  end

  defp normalize_limit(value) when is_integer(value) and value > 0, do: value

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> @default_limit
    end
  end

  defp normalize_limit(_value), do: @default_limit
end
