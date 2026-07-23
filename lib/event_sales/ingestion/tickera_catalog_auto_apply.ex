defmodule EventSales.Ingestion.TickeraCatalogAutoApply do
  @moduledoc "Durable orchestration for pure catalog auto-Apply evaluation."

  require Ash.Query

  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Catalog.TickeraCatalog.{AutoApplyPolicy, SnapshotCanonicalizer}

  alias EventSales.Ingestion.Resources.{
    TickeraCatalogAutoApplyConfig,
    TickeraCatalogAutoApplyDecision,
    TickeraCatalogSyncRun
  }

  alias EventSales.Ingestion.TickeraCatalogAutoApplyConfig, as: Configuration

  @policy_version "conservative_auto_apply.v1"

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
end
