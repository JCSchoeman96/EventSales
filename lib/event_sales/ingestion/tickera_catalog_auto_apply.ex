defmodule EventSales.Ingestion.TickeraCatalogAutoApply do
  @moduledoc "Durable orchestration for pure catalog auto-Apply evaluation."

  require Ash.Query
  import Ecto.Query

  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Catalog.TickeraCatalog.{AutoApplyPolicy, PubSub, SnapshotCanonicalizer}

  alias EventSales.Ingestion.Resources.{
    TickeraCatalogAutoApplyConfig,
    TickeraCatalogAutoApplyDecision,
    TickeraCatalogSyncRun
  }

  alias EventSales.Ingestion.TickeraCatalogAutoApplyConfig, as: Configuration
  alias EventSales.Ingestion.Workers.ApplyTickeraCatalogWorker
  alias EventSales.Repo

  @policy_version "conservative_auto_apply.v1"
  # Dialyzer on OTP 28 expands Ecto.Multi's opaque MapSet internals when this
  # pipeline starts from Ecto.Multi.new/0. The transaction is covered by the
  # atomic enqueue and concurrent-worker tests.
  @dialyzer {:nowarn_function, enqueue_multi: 1}

  def evaluate_run(run_id) when is_binary(run_id) do
    with {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: EventSales.Ingestion),
         true <- run.status == :dry_run_ready,
         :ok <- verify_snapshot_hash(run),
         {:ok, %SourceSystem{} = source} <-
           Ash.get(SourceSystem, run.source_system_id, domain: EventSales.Catalog),
         {:ok, config} <- load_or_bootstrap_config(),
         projection <- configuration_projection(config, source),
         policy_result <- evaluate_policy(run),
         attrs <- decision_attrs(run, projection, policy_result),
         {:ok, decision} <- create_or_reload_decision(attrs) do
      {:ok, decision}
    else
      false -> {:error, :run_not_ready}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def evaluate_run(_run_id), do: {:error, :invalid_run_id}

  def enqueue_decision(decision_id) when is_binary(decision_id) do
    case Ash.get(TickeraCatalogAutoApplyDecision, decision_id, domain: EventSales.Ingestion) do
      {:ok, %{enqueue_state: :enqueued} = decision} ->
        {:ok, decision}

      {:ok, %TickeraCatalogAutoApplyDecision{}} ->
        decision_id
        |> enqueue_multi()
        |> Repo.transaction()
        |> finalize_enqueue(decision_id)

      {:ok, nil} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def enqueue_decision(_decision_id), do: {:error, :invalid_decision_id}

  def latest_decision_for_run(run_id) when is_binary(run_id) do
    TickeraCatalogAutoApplyDecision
    |> Ash.Query.filter(catalog_sync_run_id == ^run_id)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: EventSales.Ingestion)
  end

  def latest_decision_for_run(_run_id), do: {:error, :invalid_run_id}

  def decisions_for_source(source_system_id, opts \\ [])

  def decisions_for_source(source_system_id, opts) when is_binary(source_system_id) do
    limit = opts |> Keyword.get(:limit, 25) |> min(100) |> max(1)

    with {:ok, cursor} <- decode_decision_cursor(Keyword.get(opts, :cursor)) do
      query =
        from decision in TickeraCatalogAutoApplyDecision,
          where: decision.source_system_id == ^source_system_id,
          order_by: [desc: decision.inserted_at, desc: decision.id],
          limit: ^(limit + 1)

      query =
        case cursor do
          nil ->
            query

          {inserted_at, id} ->
            from decision in query,
              where:
                decision.inserted_at < ^inserted_at or
                  (decision.inserted_at == ^inserted_at and decision.id < ^id)
        end

      rows = Repo.all(query)
      items = Enum.take(rows, limit)

      next_cursor =
        if length(rows) > limit do
          items |> List.last() |> encode_decision_cursor()
        end

      {:ok, %{items: items, next_cursor: next_cursor}}
    end
  end

  def decisions_for_source(_source_system_id, _opts), do: {:error, :invalid_source_system_id}

  def validate_automatic_claim(decision_id, job_id, run_id, dry_run_hash)
      when is_binary(decision_id) and is_integer(job_id) do
    with {:ok, %TickeraCatalogAutoApplyDecision{} = decision} <-
           Ash.get(TickeraCatalogAutoApplyDecision, decision_id, domain: EventSales.Ingestion),
         true <- decision.catalog_sync_run_id == run_id,
         true <- decision.dry_run_hash == dry_run_hash,
         true <- decision.apply_job_id == job_id,
         true <- decision.decision_result == :eligible,
         true <- decision.enqueue_state == :enqueued,
         true <- decision.apply_audit_state == :not_started,
         true <- decision.origin == :targeted_catalog_change,
         {:ok, projection} <- current_configuration(decision.source_system_id),
         true <- projection.effective_mode == :enabled,
         true <- projection.configuration_revision == decision.configuration_revision,
         true <- projection.fingerprint == decision.configuration_fingerprint,
         true <- decision.policy_version in projection.enabled_policy_versions,
         true <- decision.snapshot_schema_version in projection.supported_snapshot_versions do
      {:ok, decision}
    else
      {:ok, nil} -> {:error, :missing_auto_apply_decision}
      false -> {:error, :automatic_claim_rejected}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_automatic_claim(_decision_id, _job_id, _run_id, _dry_run_hash),
    do: {:error, :invalid_automatic_claim}

  def current_configuration(source_system_id) do
    with {:ok, %SourceSystem{} = source} <-
           Ash.get(SourceSystem, source_system_id, domain: EventSales.Catalog),
         {:ok, config} <- load_or_bootstrap_config() do
      {:ok, configuration_projection(config, source)}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_configuration(expected_revision, attrs)
      when is_integer(expected_revision) and expected_revision >= 1 and is_map(attrs) do
    normalized = normalize_configuration_attrs(attrs)

    Repo.transaction(fn -> update_locked_configuration(expected_revision, normalized) end)
    |> case do
      {:ok, id} -> Ash.get(TickeraCatalogAutoApplyConfig, id, domain: EventSales.Ingestion)
      {:error, reason} -> {:error, reason}
    end
  end

  def update_configuration(_expected_revision, _attrs), do: {:error, :invalid_configuration}

  defp update_locked_configuration(expected_revision, normalized) do
    current = locked_configuration()

    cond do
      is_nil(current) -> Repo.rollback(:configuration_missing)
      current.revision != expected_revision -> Repo.rollback(:configuration_revision_conflict)
      true -> persist_configuration_updates(current, normalized)
    end
  end

  defp locked_configuration do
    Repo.one(
      from config in "ingestion_tickera_catalog_auto_apply_configs",
        where: config.singleton_key == "global",
        lock: "FOR UPDATE",
        select: %{
          id: fragment("?::text", config.id),
          revision: config.revision,
          global_mode: config.global_mode,
          enabled_policy_versions: config.enabled_policy_versions,
          supported_snapshot_versions: config.supported_snapshot_versions
        }
    )
  end

  defp persist_configuration_updates(current, normalized) do
    case material_configuration_updates(current, normalized) do
      [] ->
        current.id

      updates ->
        {1, _} =
          Repo.update_all(
            from(config in "ingestion_tickera_catalog_auto_apply_configs",
              where:
                config.id == type(^current.id, :binary_id) and
                  config.revision == ^current.revision
            ),
            set: updates ++ [revision: current.revision + 1, updated_at: DateTime.utc_now()]
          )

        current.id
    end
  end

  def record_apply_audit(decision_id, state)
      when state in [:claim_rejected, :claimed, :completed, :failed] do
    allowed_from = %{
      claim_rejected: [:not_started],
      claimed: [:not_started],
      completed: [:claimed],
      failed: [:claimed]
    }

    updates =
      [apply_audit_state: state, updated_at: DateTime.utc_now()]
      |> maybe_completion_time(state)

    {count, _rows} =
      Repo.update_all(
        from(decision in TickeraCatalogAutoApplyDecision,
          where:
            decision.id == ^decision_id and
              decision.apply_audit_state in ^Map.fetch!(allowed_from, state)
        ),
        set: updates
      )

    if count == 1 do
      broadcast_decision(decision_id)
      :ok
    else
      {:error, :invalid_apply_audit_transition}
    end
  end

  defp maybe_completion_time(updates, :completed),
    do: Keyword.put(updates, :completed_at, DateTime.utc_now())

  defp maybe_completion_time(updates, _state), do: updates

  defp enqueue_multi(decision_id) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:locked_decision, fn repo, changes ->
      lock_enqueue_decision(repo, changes, decision_id)
    end)
    |> Ecto.Multi.run(:revalidated, fn repo, changes -> revalidate_enqueue(repo, changes) end)
    |> Ecto.Multi.update_all(
      :claimed_decision,
      fn %{locked_decision: decision} ->
        from row in "ingestion_tickera_catalog_auto_apply_decisions",
          where: row.id == type(^decision.id, :binary_id) and row.enqueue_state == "pending",
          update: [
            set: [enqueue_state: "claimed", enqueue_attempts: 1, updated_at: fragment("now()")]
          ]
      end,
      []
    )
    |> Oban.insert(:apply_job, fn %{locked_decision: decision} ->
      ApplyTickeraCatalogWorker.new(%{
        "run_id" => decision.catalog_sync_run_id,
        "dry_run_hash" => decision.dry_run_hash,
        "decision_id" => decision.id
      })
    end)
    |> Ecto.Multi.run(:linked_decision, fn repo, %{locked_decision: decision, apply_job: job} ->
      {count, _rows} =
        repo.update_all(
          from(row in "ingestion_tickera_catalog_auto_apply_decisions",
            where: row.id == type(^decision.id, :binary_id) and row.enqueue_state == "claimed"
          ),
          set: [
            enqueue_state: "enqueued",
            apply_job_id: job.id,
            next_attempt_at: DateTime.add(DateTime.utc_now(), 300, :second),
            updated_at: DateTime.utc_now()
          ]
        )

      if count == 1, do: {:ok, job.id}, else: {:error, :linkage_failed}
    end)
  end

  defp lock_enqueue_decision(repo, _changes, decision_id) do
    decision =
      repo.one(
        from decision in "ingestion_tickera_catalog_auto_apply_decisions",
          where: decision.id == type(^decision_id, :binary_id),
          lock: "FOR UPDATE",
          select: %{
            id: fragment("?::text", decision.id),
            catalog_sync_run_id: fragment("?::text", decision.catalog_sync_run_id),
            dry_run_hash: decision.dry_run_hash,
            policy_version: decision.policy_version,
            snapshot_schema_version: decision.snapshot_schema_version,
            source_system_id: fragment("?::text", decision.source_system_id),
            origin: decision.origin,
            configuration_revision: decision.configuration_revision,
            configuration_fingerprint: decision.configuration_fingerprint,
            enqueue_state: decision.enqueue_state,
            decision_result: decision.decision_result,
            effective_mode: decision.effective_mode,
            apply_job_id: decision.apply_job_id
          }
      )

    classify_enqueue_decision(decision)
  end

  defp classify_enqueue_decision(
         %{
           enqueue_state: "pending",
           decision_result: "eligible",
           effective_mode: "enabled",
           apply_job_id: nil
         } = decision
       ),
       do: {:ok, decision}

  defp classify_enqueue_decision(%{enqueue_state: "enqueued"}), do: {:error, :already_enqueued}
  defp classify_enqueue_decision(nil), do: {:error, :not_found}
  defp classify_enqueue_decision(_decision), do: {:error, :not_enqueueable}

  defp revalidate_enqueue(repo, %{locked_decision: decision}) do
    run =
      repo.one(
        from run in "ingestion_tickera_catalog_sync_runs",
          where: run.id == type(^decision.catalog_sync_run_id, :binary_id),
          lock: "FOR UPDATE",
          select: %{
            id: fragment("?::text", run.id),
            status: run.status,
            dry_run_hash: run.dry_run_hash,
            origin: run.origin,
            source_system_id: fragment("?::text", run.source_system_id)
          }
      )

    config =
      repo.one(
        from config in "ingestion_tickera_catalog_auto_apply_configs",
          where: config.singleton_key == "global",
          lock: "FOR UPDATE",
          select: %{
            global_mode: config.global_mode,
            enabled_policy_versions: config.enabled_policy_versions,
            supported_snapshot_versions: config.supported_snapshot_versions,
            revision: config.revision
          }
      )

    source =
      repo.one(
        from source in "catalog_source_systems",
          where: source.id == type(^decision.source_system_id, :binary_id),
          select: %{
            catalog_auto_apply_mode: source.catalog_auto_apply_mode,
            catalog_auto_apply_allowlisted: source.catalog_auto_apply_allowlisted
          }
      )

    with true <- not is_nil(run) and not is_nil(config) and not is_nil(source),
         projection <- locked_configuration_projection(config, source),
         true <- Configuration.hard_kill().enabled,
         true <- run.status == "dry_run_ready",
         true <- run.dry_run_hash == decision.dry_run_hash,
         true <-
           run.origin == "targeted_catalog_change" and
             decision.origin == "targeted_catalog_change",
         true <- run.source_system_id == decision.source_system_id,
         true <- projection.effective_mode == :enabled,
         true <- projection.configuration_revision == decision.configuration_revision,
         true <- projection.fingerprint == decision.configuration_fingerprint,
         true <- decision.policy_version in projection.enabled_policy_versions,
         true <- decision.snapshot_schema_version in projection.supported_snapshot_versions do
      {:ok, decision}
    else
      false -> {:error, :enqueue_revalidation_failed}
    end
  end

  defp locked_configuration_projection(config, source) do
    projection = %{
      hard_kill_enabled: Configuration.hard_kill().enabled,
      global_mode: existing_atom(config.global_mode),
      source_mode: existing_atom(source.catalog_auto_apply_mode),
      source_allowlisted: source.catalog_auto_apply_allowlisted,
      enabled_policy_versions: config.enabled_policy_versions,
      supported_snapshot_versions: config.supported_snapshot_versions,
      configuration_revision: config.revision
    }

    Map.merge(projection, %{
      effective_mode: Configuration.effective_mode(projection),
      fingerprint: Configuration.fingerprint(projection)
    })
  end

  defp existing_atom(value) when is_atom(value), do: value
  defp existing_atom("disabled"), do: :disabled
  defp existing_atom("observe"), do: :observe
  defp existing_atom("enabled"), do: :enabled
  defp existing_atom("inherit"), do: :inherit

  defp encode_decision_cursor(decision) do
    [DateTime.to_iso8601(decision.inserted_at), decision.id]
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_decision_cursor(nil), do: {:ok, nil}

  defp decode_decision_cursor(cursor) when is_binary(cursor) do
    with {:ok, bytes} <- Base.url_decode64(cursor, padding: false),
         {:ok, [timestamp, id]} <- Jason.decode(bytes),
         {:ok, inserted_at, 0} <- DateTime.from_iso8601(timestamp),
         {:ok, _uuid} <- Ecto.UUID.cast(id) do
      {:ok, {inserted_at, id}}
    else
      _error -> {:error, :invalid_cursor}
    end
  end

  defp decode_decision_cursor(_cursor), do: {:error, :invalid_cursor}

  defp finalize_enqueue({:ok, _changes}, decision_id),
    do: reload_and_broadcast(decision_id)

  defp finalize_enqueue({:error, _step, :already_enqueued, _changes}, decision_id),
    do: reload_and_broadcast(decision_id)

  defp finalize_enqueue({:error, _step, reason, _changes}, _decision_id), do: {:error, reason}

  defp verify_snapshot_hash(
         %{plan_snapshot: %{"snapshot_schema_version" => "tickera_catalog_plan.v2"}} = run
       ) do
    case SnapshotCanonicalizer.canonicalize(run.plan_snapshot) do
      {:ok, _bytes, hash} when hash == run.dry_run_hash -> :ok
      _other -> {:error, :stale_dry_run_hash}
    end
  end

  defp verify_snapshot_hash(_run), do: :ok

  defp load_or_bootstrap_config do
    case first_config() do
      {:ok, nil} ->
        case Ash.create(TickeraCatalogAutoApplyConfig, %{},
               action: :bootstrap,
               domain: EventSales.Ingestion
             ) do
          {:ok, config} -> {:ok, config}
          {:error, _conflict} -> first_config()
        end

      result ->
        result
    end
  end

  defp first_config do
    TickeraCatalogAutoApplyConfig
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: EventSales.Ingestion)
  end

  defp configuration_projection(config, source) do
    hard_kill = Configuration.hard_kill()

    projection = %{
      hard_kill_enabled: hard_kill.enabled,
      global_mode: config.global_mode,
      source_mode: source.catalog_auto_apply_mode,
      source_allowlisted: source.catalog_auto_apply_allowlisted,
      enabled_policy_versions: config.enabled_policy_versions,
      supported_snapshot_versions: config.supported_snapshot_versions,
      configuration_revision: config.revision
    }

    Map.merge(projection, %{
      effective_mode: Configuration.effective_mode(projection),
      fingerprint: Configuration.fingerprint(projection)
    })
  end

  defp normalize_configuration_attrs(attrs) do
    attrs
    |> Map.take([:global_mode, :enabled_policy_versions, :supported_snapshot_versions])
    |> normalize_version_list(:enabled_policy_versions)
    |> normalize_version_list(:supported_snapshot_versions)
  end

  defp normalize_version_list(attrs, key) do
    if Map.has_key?(attrs, key) do
      Map.update!(attrs, key, &(&1 |> Enum.uniq() |> Enum.sort()))
    else
      attrs
    end
  end

  defp material_configuration_updates(current, attrs) do
    Enum.flat_map(attrs, fn
      {:global_mode, value} when value in [:disabled, :observe, :enabled] ->
        if value == current.global_mode or to_string(value) == current.global_mode,
          do: [],
          else: [global_mode: to_string(value)]

      {:enabled_policy_versions, value} when is_list(value) ->
        if value == current.enabled_policy_versions,
          do: [],
          else: [enabled_policy_versions: value]

      {:supported_snapshot_versions, value} when is_list(value) ->
        if value == current.supported_snapshot_versions,
          do: [],
          else: [supported_snapshot_versions: value]

      _other ->
        Repo.rollback(:invalid_configuration)
    end)
  end

  defp evaluate_policy(run) do
    AutoApplyPolicy.evaluate(%{
      run_id: run.id,
      dry_run_hash: run.dry_run_hash,
      origin: run.origin,
      snapshot: run.plan_snapshot,
      findings: run.plan_snapshot["findings"] || [],
      policy_version: @policy_version
    })
  end

  defp decision_attrs(run, config, {:ok, policy}) do
    result =
      if config.effective_mode == :observe and policy.result == :eligible,
        do: :observe,
        else: policy.result

    %{
      catalog_sync_run_id: run.id,
      dry_run_hash: run.dry_run_hash,
      snapshot_schema_version:
        run.plan_snapshot["snapshot_schema_version"] || "legacy_unversioned",
      policy_version: @policy_version,
      decision_result: result,
      reason_codes: Enum.map(policy.reason_codes, &Atom.to_string/1),
      finding_summary: policy.summaries.finding_summary,
      action_summary: policy.summaries.action_summary,
      historical_summary: policy.summaries.historical_summary,
      origin: run.origin,
      evaluated_global_mode: config.global_mode,
      evaluated_source_mode: config.source_mode,
      effective_mode: config.effective_mode,
      configuration_revision: config.configuration_revision,
      configuration_fingerprint: config.fingerprint,
      enqueue_state:
        if(result == :eligible and config.effective_mode == :enabled,
          do: :pending,
          else: :not_applicable
        ),
      apply_audit_state: :not_started,
      enqueue_key:
        if(result == :eligible and config.effective_mode == :enabled,
          do: "#{run.id}:#{run.dry_run_hash}:#{@policy_version}",
          else: nil
        )
    }
  end

  defp decision_attrs(run, config, {:error, policy}) do
    decision_attrs(run, config, {:ok, %{policy | result: :ineligible}})
  end

  defp create_or_reload_decision(attrs) do
    case Ash.create(TickeraCatalogAutoApplyDecision, attrs,
           action: :create_for_run,
           domain: EventSales.Ingestion
         ) do
      {:ok, decision} ->
        notify_decision(decision)
        {:ok, decision}

      {:error, _conflict} ->
        TickeraCatalogAutoApplyDecision
        |> Ash.Query.filter(
          catalog_sync_run_id == ^attrs.catalog_sync_run_id and
            dry_run_hash == ^attrs.dry_run_hash and policy_version == ^attrs.policy_version
        )
        |> Ash.read_one(domain: EventSales.Ingestion)
    end
  end

  defp reload_and_broadcast(decision_id) do
    case Ash.get(TickeraCatalogAutoApplyDecision, decision_id, domain: EventSales.Ingestion) do
      {:ok, %TickeraCatalogAutoApplyDecision{} = decision} = result ->
        notify_decision(decision)
        result

      result ->
        result
    end
  end

  defp broadcast_decision(decision_id) do
    case Ash.get(TickeraCatalogAutoApplyDecision, decision_id, domain: EventSales.Ingestion) do
      {:ok, %TickeraCatalogAutoApplyDecision{} = decision} -> notify_decision(decision)
      _other -> :ok
    end
  end

  defp notify_decision(decision) do
    metadata = %{
      policy_version: decision.policy_version,
      snapshot_version: decision.snapshot_schema_version,
      decision_result: decision.decision_result,
      effective_mode: decision.effective_mode,
      enqueue_outcome: decision.enqueue_state
    }

    :telemetry.execute([:event_sales, :catalog_auto_apply, :decision], %{count: 1}, metadata)

    PubSub.broadcast(
      decision.catalog_sync_run_id,
      :catalog_auto_apply_decision_changed,
      %{run_id: decision.catalog_sync_run_id}
    )
  end
end
