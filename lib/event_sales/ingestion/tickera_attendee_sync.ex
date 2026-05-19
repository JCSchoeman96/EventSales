defmodule EventSales.Ingestion.TickeraAttendeeSync do
  @moduledoc """
  Executes one Tickera attendee sync page for a `TickeraAttendeeSyncRun`.
  """

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Clients.{TickeraAttendeeClient, TickeraError}
  alias EventSales.Ingestion.Resources.{TickeraAttendeeSyncRun, TickeraEventSource}
  alias EventSales.Ingestion.TickeraAttendeeSnapshotHash
  alias EventSales.Ingestion.TickeraAttendeeSnapshots
  alias EventSales.Ingestion.TickeraAttendeeSyncRuns
  alias EventSales.Telemetry

  @hash_drop_keys [
    :transaction_id,
    "transaction_id",
    :api_key,
    "api_key",
    :tickera_api_key,
    "tickera_api_key"
  ]

  @pause_seconds %{
    rate_limited: 60,
    server_error: 30,
    timeout: 30,
    transport_error: 30,
    duplicate_page: 300
  }

  @duplicate_pause_seconds 300

  @type step_result ::
          {:continue, TickeraAttendeeSyncRun.t()}
          | {:complete, TickeraAttendeeSyncRun.t()}
          | {:pause, TickeraAttendeeSyncRun.t(), atom(), pos_integer()}
          | {:error, term()}

  @doc """
  Fetches and processes exactly one Tickera page for the given sync run.
  """
  @spec run_step(TickeraAttendeeSyncRun.t(), keyword()) :: step_result()
  def run_step(%TickeraAttendeeSyncRun{} = run, opts \\ []) do
    emit_tickera_sync_start()

    result =
      try do
        do_run_step(run, opts)
      rescue
        exception ->
          emit_tickera_sync_exception(%{error_reason: :internal})
          reraise exception, __STACKTRACE__
      end

    case result do
      {:error, {:failed, _, _}} = failed ->
        emit_tickera_sync_stop_for_result(failed, opts)
        failed

      {:error, _} = unexpected ->
        emit_tickera_sync_exception(%{error_reason: :internal})
        unexpected

      ok ->
        emit_tickera_sync_stop_for_result(ok, opts)
        ok
    end
  end

  defp do_run_step(run, opts) do
    with {:ok, source} <- load_source(run),
         :ok <- validate_source_active(source, run),
         :ok <- validate_run_source_match(source, run),
         {:ok, api_key} <- resolve_api_key(source, run),
         {:ok, page_result} <- fetch_page(source, api_key, run, opts) do
      process_page(run, source, page_result, opts)
    end
  end

  defp load_source(run) do
    case Ash.get(TickeraEventSource, run.tickera_event_source_id, domain: Ingestion) do
      {:ok, source} ->
        {:ok, source}

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        fail_run(run, "tickera_source_missing", :source_missing)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_source_active(%{active: false}, run),
    do: fail_run(run, "tickera_source_inactive", :inactive_source)

  defp validate_source_active(_source, _run), do: :ok

  defp validate_run_source_match(source, run) do
    if run.event_id == source.event_id and run.source_system_id == source.source_system_id do
      :ok
    else
      fail_run(run, "tickera_source_mismatch", :source_mismatch)
    end
  end

  defp resolve_api_key(source, run) do
    case System.get_env(source.api_key_env_var) do
      api_key when is_binary(api_key) and api_key != "" ->
        {:ok, api_key}

      _other ->
        fail_run(run, "tickera_api_key_missing", :missing_api_key)
    end
  end

  defp fetch_page(source, api_key, run, opts) do
    page = run.current_page || 1
    per_page = per_page(opts)
    client = tickera_client(opts)

    client_opts =
      opts
      |> Keyword.take([:transport])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case client.fetch_attendees_page(
           source.tickera_site_url,
           api_key,
           page,
           per_page,
           client_opts
         ) do
      {:ok, page_result} ->
        {:ok, page_result}

      {:error, %TickeraError{} = error} ->
        handle_fetch_error(run, error)
    end
  end

  defp process_page(run, source, page_result, opts) do
    page = page_result.page
    per_page = page_result.per_page
    count = page_result.count
    attendees = page_result.attendees
    signature = page_signature(attendees)

    if count == per_page and signature == run.last_page_signature do
      handle_duplicate_page(run, page, signature, count)
    else
      {upserted, failed} = upsert_attendees(run, source, attendees, opts)

      with {:ok, run} <-
             record_page_and_counts(run, page, signature, count, per_page, upserted, failed) do
        finalize_after_page(run, page, count, per_page)
      end
    end
  end

  defp handle_duplicate_page(run, page, signature, count) do
    paused_until = DateTime.add(DateTime.utc_now(), @duplicate_pause_seconds, :second)

    page_attrs = %{
      current_page: page,
      last_successful_page: page,
      last_page_count: count,
      last_page_signature: signature
    }

    count_attrs = %{
      attendees_seen_count: run.attendees_seen_count + count,
      attendees_upserted_count: run.attendees_upserted_count,
      attendees_failed_count: run.attendees_failed_count,
      duplicate_page_count: run.duplicate_page_count + 1,
      errors_count: run.errors_count + 1
    }

    pause_attrs = %{
      paused_until: paused_until,
      pause_reason: :duplicate_page,
      last_error: "tickera_duplicate_page"
    }

    with {:ok, run} <- TickeraAttendeeSyncRuns.record_page(run, page_attrs, internal?: true),
         {:ok, run} <- TickeraAttendeeSyncRuns.record_counts(run, count_attrs, internal?: true),
         {:ok, paused} <- TickeraAttendeeSyncRuns.mark_paused(run, pause_attrs, internal?: true) do
      {:pause, paused, :duplicate_page, @duplicate_pause_seconds}
    end
  end

  defp upsert_attendees(run, source, attendees, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    Enum.reduce(attendees, {0, 0}, fn attendee, {upserted, failed} ->
      case upsert_attendee(run, source, attendee, now) do
        :ok -> {upserted + 1, failed}
        :error -> {upserted, failed + 1}
      end
    end)
  end

  defp upsert_attendee(run, source, attendee, now) do
    case ticket_code_for(attendee) do
      nil ->
        :error

      ticket_code ->
        attrs = build_snapshot_attrs(run, source, attendee, ticket_code, now)

        case TickeraAttendeeSnapshots.upsert_from_tickera(attrs, internal?: true) do
          {:ok, _snapshot} -> :ok
          {:error, _reason} -> :error
        end
    end
  end

  defp build_snapshot_attrs(run, source, attendee, ticket_code, now) do
    %{
      tickera_event_source_id: source.id,
      tickera_attendee_sync_run_id: run.id,
      ticket_code: ticket_code,
      checksum: map_value(attendee, :checksum),
      ticket_type_id: map_value(attendee, :ticket_type_id),
      ticket_type: map_value(attendee, :ticket_type),
      first_name: map_value(attendee, :first_name),
      last_name: map_value(attendee, :last_name),
      email: map_value(attendee, :email),
      buyer_first: map_value(attendee, :buyer_first),
      buyer_last: map_value(attendee, :buyer_last),
      buyer_email: map_value(attendee, :buyer_email),
      allowed_checkins: map_value(attendee, :allowed_checkins),
      used_checkins: map_value(attendee, :used_checkins),
      remaining_checkins: map_value(attendee, :remaining_checkins),
      checked_in?: map_value(attendee, :checked_in),
      payment_status: map_value(attendee, :payment_status),
      payment_date_raw: map_value(attendee, :payment_date),
      custom_fields: map_value(attendee, :custom_fields) || %{},
      raw_source_hash: raw_source_hash(attendee),
      source_updated_at: nil,
      last_seen_at: now
    }
  end

  defp record_page_and_counts(run, page, signature, count, per_page, upserted, failed) do
    next_page = if count == per_page, do: page + 1, else: page

    page_attrs = %{
      current_page: next_page,
      last_successful_page: page,
      last_page_count: count,
      last_page_signature: signature
    }

    count_attrs = %{
      attendees_seen_count: run.attendees_seen_count + count,
      attendees_upserted_count: run.attendees_upserted_count + upserted,
      attendees_failed_count: run.attendees_failed_count + failed,
      duplicate_page_count: run.duplicate_page_count,
      errors_count: run.errors_count + failed
    }

    with {:ok, run} <- TickeraAttendeeSyncRuns.record_page(run, page_attrs, internal?: true),
         {:ok, run} <- TickeraAttendeeSyncRuns.record_counts(run, count_attrs, internal?: true) do
      {:ok, run}
    end
  end

  defp finalize_after_page(run, _page, count, per_page) do
    if count < per_page do
      case TickeraAttendeeSyncRuns.mark_completed(run, internal?: true) do
        {:ok, completed} -> {:complete, completed}
        {:error, reason} -> {:error, reason}
      end
    else
      {:continue, run}
    end
  end

  defp handle_fetch_error(run, %TickeraError{reason: reason}) do
    if TickeraError.retryable?(reason) do
      pause_reason = reason
      seconds = Map.fetch!(@pause_seconds, pause_reason)
      paused_until = DateTime.add(DateTime.utc_now(), seconds, :second)

      pause_attrs = %{
        paused_until: paused_until,
        pause_reason: pause_reason,
        last_error: "tickera_#{reason}"
      }

      case TickeraAttendeeSyncRuns.mark_paused(run, pause_attrs, internal?: true) do
        {:ok, paused} -> {:pause, paused, pause_reason, seconds}
        {:error, error} -> {:error, error}
      end
    else
      fail_run(run, "tickera_#{reason}", reason)
    end
  end

  defp fail_run(run, last_error, reason) do
    case TickeraAttendeeSyncRuns.mark_failed(run, %{last_error: last_error}, internal?: true) do
      {:ok, failed} -> {:error, {:failed, failed, reason}}
      {:error, error} -> {:error, error}
    end
  end

  defp ticket_code_for(attendee) do
    code = map_value(attendee, :ticket_code)
    checksum = map_value(attendee, :checksum)

    cond do
      is_binary(code) and String.trim(code) != "" ->
        String.trim(code)

      is_binary(checksum) and String.trim(checksum) != "" ->
        String.trim(checksum)

      true ->
        nil
    end
  end

  defp raw_source_hash(attendee) when is_map(attendee) do
    attendee
    |> Map.drop(@hash_drop_keys)
    |> TickeraAttendeeSnapshotHash.hash()
  end

  defp page_signature(attendees) do
    attendees
    |> Enum.map(fn attendee ->
      map_value(attendee, :ticket_code) || map_value(attendee, :checksum) || ""
    end)
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp map_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp per_page(opts) do
    Keyword.get(opts, :per_page) ||
      Application.get_env(:event_sales, :tickera_api, [])
      |> Keyword.get(:per_page, 50)
  end

  defp tickera_client(opts) do
    Keyword.get(opts, :tickera_client) ||
      Application.get_env(
        :event_sales,
        :tickera_attendee_client,
        TickeraAttendeeClient
      )
  end

  defp emit_tickera_sync_start do
    Telemetry.emit(Telemetry.tickera_sync_start(), %{count: 1}, %{source: :tickera})
  end

  defp emit_tickera_sync_stop_for_result(result, opts) do
    metadata =
      result
      |> stop_metadata(opts)
      |> Map.put(:source, :tickera)

    Telemetry.emit(Telemetry.tickera_sync_stop(), %{count: 1}, metadata)
  end

  defp emit_tickera_sync_exception(metadata) do
    metadata = Map.put(metadata, :source, :tickera)
    Telemetry.emit(Telemetry.tickera_sync_exception(), %{count: 1}, metadata)
  end

  defp stop_metadata({:continue, run}, opts), do: page_stop_metadata(run, :continue, opts)
  defp stop_metadata({:complete, run}, opts), do: page_stop_metadata(run, :completed, opts)

  defp stop_metadata({:pause, _run, pause_reason, _seconds}, _opts) do
    %{result: :paused, pause_reason: pause_reason, error_reason: nil}
  end

  defp stop_metadata({:error, {:failed, _run, reason}}, _opts) do
    %{result: :failed, pause_reason: nil, error_reason: reason}
  end

  defp stop_metadata({:error, _reason}, _opts) do
    %{result: :failed, pause_reason: nil, error_reason: :internal}
  end

  defp page_stop_metadata(run, result, opts) do
    per_page = per_page(opts)

    %{
      result: result,
      pause_reason: nil,
      error_reason: nil,
      page: run.last_successful_page,
      per_page: per_page,
      returned_count: run.last_page_count || 0,
      upserted_count: run.attendees_upserted_count,
      failed_count: run.attendees_failed_count
    }
  end
end
