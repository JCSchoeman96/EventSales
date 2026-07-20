defmodule EventSales.Ingestion.CatalogChangeIntake do
  @moduledoc "Transactional durable intake for authenticated catalogue-change signals."

  alias EventSales.Ingestion.CatalogChangeContract
  alias EventSales.Ingestion.Workers.CatalogChangeDispatchWorker
  alias EventSales.Repo
  alias EventSales.Telemetry

  def persist(source_system_id, raw_body, payload) do
    hash = :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower)

    with {:ok, signal} <- CatalogChangeContract.parse(payload) do
      case existing(source_system_id, signal.signal_id) do
        {:ok, ^hash} -> report(:duplicate, signal)
        {:ok, _other} -> reject(:signal_id_payload_mismatch, signal)
        :missing -> insert_new(source_system_id, signal, hash)
      end
    end
  end

  defp insert_new(source_id, signal, hash) do
    case Repo.transaction(fn -> do_insert(source_id, signal, hash) end) do
      {:ok, :accepted} ->
        report(:accepted, signal)

      {:ok, :stale} ->
        Telemetry.emit(Telemetry.catalog_change_intake_stale(), %{count: 1}, %{
          target_type: signal.target_type,
          contract_version: signal.version
        })

        {:ok, :accepted}

      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
        classify_race(source_id, signal.signal_id, hash)

      {:error, _} ->
        reject(:temporarily_unavailable, signal)
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres.code == :unique_violation,
        do: classify_race(source_id, signal.signal_id, hash),
        else: reject(:temporarily_unavailable, signal)
  end

  defp do_insert(source_id, signal, hash) do
    now = DateTime.utc_now()
    quiet_until = DateTime.add(now, quiet_window(), :second)

    sql = """
    INSERT INTO ingestion_catalog_change_pending_targets
      (id, source_system_id, target_type, target_id, state, generation, dispatched_generation,
       latest_source_updated_at, latest_reason, first_received_at, last_received_at, quiet_until,
       dispatch_attempts, inserted_at, updated_at)
    VALUES ($1,$2,$3,$4,'pending',1,0,$5,$6,$7,$7,$8,0,$7,$7)
    ON CONFLICT (source_system_id,target_type,target_id) DO UPDATE SET
      generation = CASE WHEN EXCLUDED.latest_source_updated_at >= ingestion_catalog_change_pending_targets.latest_source_updated_at THEN ingestion_catalog_change_pending_targets.generation + 1 ELSE ingestion_catalog_change_pending_targets.generation END,
      latest_source_updated_at = GREATEST(ingestion_catalog_change_pending_targets.latest_source_updated_at, EXCLUDED.latest_source_updated_at),
      latest_reason = CASE WHEN EXCLUDED.latest_source_updated_at >= ingestion_catalog_change_pending_targets.latest_source_updated_at THEN EXCLUDED.latest_reason ELSE ingestion_catalog_change_pending_targets.latest_reason END,
      last_received_at = CASE WHEN EXCLUDED.latest_source_updated_at >= ingestion_catalog_change_pending_targets.latest_source_updated_at THEN EXCLUDED.last_received_at ELSE ingestion_catalog_change_pending_targets.last_received_at END,
      quiet_until = CASE WHEN EXCLUDED.latest_source_updated_at >= ingestion_catalog_change_pending_targets.latest_source_updated_at THEN EXCLUDED.quiet_until ELSE ingestion_catalog_change_pending_targets.quiet_until END,
      state = CASE WHEN EXCLUDED.latest_source_updated_at < ingestion_catalog_change_pending_targets.latest_source_updated_at THEN ingestion_catalog_change_pending_targets.state WHEN ingestion_catalog_change_pending_targets.catalog_sync_run_id IS NULL THEN 'pending' ELSE 'deferred' END,
      updated_at = CASE WHEN EXCLUDED.latest_source_updated_at >= ingestion_catalog_change_pending_targets.latest_source_updated_at THEN EXCLUDED.updated_at ELSE ingestion_catalog_change_pending_targets.updated_at END
    RETURNING id, generation, dispatched_generation, state, latest_source_updated_at
    """

    id = Ecto.UUID.generate()

    {:ok, %{rows: [[target_id, generation, dispatched_generation, state, latest_at]]}} =
      Repo.query(sql, [
        uuid(id),
        uuid(source_id),
        Atom.to_string(signal.target_type),
        signal.target_id,
        signal.source_updated_at,
        Atom.to_string(signal.reason),
        now,
        quiet_until
      ])

    disposition =
      if NaiveDateTime.compare(DateTime.to_naive(signal.source_updated_at), latest_at) == :lt,
        do: "stale",
        else: "accepted"

    Repo.query!(
      """
      INSERT INTO ingestion_catalog_change_signals
        (id,source_system_id,signal_id,contract_version,payload_hash,target_type,target_id,
         source_updated_at,reason,disposition,pending_target_id,received_at,inserted_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$12)
      """,
      [
        uuid(Ecto.UUID.generate()),
        uuid(source_id),
        uuid(signal.signal_id),
        signal.version,
        hash,
        Atom.to_string(signal.target_type),
        signal.target_id,
        signal.source_updated_at,
        Atom.to_string(signal.reason),
        disposition,
        target_id,
        now
      ]
    )

    if generation > dispatched_generation and state not in ["preview_ready", "settled", "failed"] do
      case Oban.insert(CatalogChangeDispatchWorker.new(%{"source_system_id" => source_id})) do
        {:ok, _job} -> String.to_existing_atom(disposition)
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      String.to_existing_atom(disposition)
    end
  end

  defp existing(source_id, signal_id) do
    case Repo.query!(
           "SELECT payload_hash FROM ingestion_catalog_change_signals WHERE source_system_id=$1 AND signal_id=$2 LIMIT 1",
           [uuid(source_id), uuid(signal_id)]
         ).rows do
      [[hash]] -> {:ok, hash}
      [] -> :missing
    end
  end

  defp classify_race(source_id, signal_id, hash) do
    case existing(source_id, signal_id) do
      {:ok, ^hash} -> {:ok, :duplicate}
      {:ok, _} -> {:error, :signal_id_payload_mismatch}
      :missing -> {:error, :temporarily_unavailable}
    end
  end

  defp report(disposition, signal) do
    event =
      if disposition == :duplicate,
        do: Telemetry.catalog_change_intake_duplicate(),
        else: Telemetry.catalog_change_intake_accepted()

    Telemetry.emit(event, %{count: 1}, %{
      target_type: signal.target_type,
      contract_version: signal.version
    })

    {:ok, disposition}
  end

  defp reject(reason, signal) do
    Telemetry.emit(Telemetry.catalog_change_intake_rejected(), %{count: 1}, %{
      target_type: signal.target_type,
      contract_version: signal.version,
      reason: reason
    })

    {:error, reason}
  end

  defp quiet_window,
    do:
      Application.get_env(:event_sales, :catalog_change_trigger, [])
      |> Keyword.get(:quiet_window_seconds, 5)

  defp uuid(value), do: Ecto.UUID.dump!(value)
end
