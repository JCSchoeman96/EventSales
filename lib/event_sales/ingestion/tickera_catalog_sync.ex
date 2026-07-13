defmodule EventSales.Ingestion.TickeraCatalogSync do
  @moduledoc """
  Admin facade for Tickera catalog sync dry-run and apply.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Catalog.TickeraCatalog.PubSub
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.Workers.{ApplyTickeraCatalogWorker, DiscoverTickeraCatalogWorker}

  @default_limit 50
  @run_summary_fields [
    :id,
    :source_system_id,
    :scope,
    :status,
    :dry_run_hash,
    :summary,
    :started_at,
    :finished_at,
    :last_error,
    :cancelled_at,
    :cancelled_by_user_id,
    :cancellation_reason_code,
    :cancellation_reason_details,
    :inserted_at,
    :updated_at
  ]

  def queue_dry_run(attrs, opts \\ []) do
    with :ok <- authorize_admin(opts),
         {:ok, source_system_id} <- fetch_required(attrs, :source_system_id),
         {:ok, scope} <- fetch_scope(attrs),
         {:ok, run} <- create_run(source_system_id, scope, opts),
         {:ok, job} <- enqueue_discovery(run, opts) do
      {:ok, %{run: run, job: job}}
    end
  end

  def queue_apply(run_id, dry_run_hash, opts \\ []) do
    with :ok <- authorize_admin(opts),
         {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion),
         :ok <- validate_apply_ready(run, dry_run_hash),
         {:ok, job} <- enqueue_apply(run, dry_run_hash, opts) do
      {:ok, %{run: run, job: job}}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, sanitize_error(reason)}
    end
  end

  def revoke_ready_dry_run(run_id, attrs, opts \\ []) do
    with :ok <- authorize_admin(opts),
         {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion),
         {:ok, reason_code, details} <- normalize_cancellation_reason(attrs) do
      case revoke_run(run, reason_code, details, opts) do
        {:ok, revoked} ->
          :ok = PubSub.broadcast(run.id, :catalog_sync_cancelled, %{run_id: run.id})
          {:ok, revoked}

        {:error, _reason} ->
          classify_revoke_failure(run.id)
      end
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, sanitize_error(reason)}
    end
  end

  def claim_for_apply(run_id, expected_dry_run_hash, opts \\ [])
      when is_binary(run_id) and is_binary(expected_dry_run_hash) do
    with {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion),
         :ok <- validate_apply_hash(run, expected_dry_run_hash) do
      run
      |> Ash.Changeset.for_update(:claim_for_apply, %{})
      |> Ash.Changeset.filter(
        status: :dry_run_ready,
        dry_run_hash: expected_dry_run_hash
      )
      |> Ash.update(claim_update_opts(opts))
      |> normalize_claim_result(run.id, expected_dry_run_hash)
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, sanitize_error(reason)}
    end
  end

  defp claim_update_opts(opts) do
    if Keyword.get(opts, :return_notifications?, false) do
      [
        domain: Ingestion,
        context: %{warn_on_transaction_hooks?: false},
        return_notifications?: true
      ]
    else
      [domain: Ingestion]
    end
  end

  def list_runs(opts \\ []) do
    with :ok <- authorize_admin(opts) do
      TickeraCatalogSyncRun
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(Keyword.get(opts, :limit, @default_limit))
      |> maybe_select_run_summaries(opts)
      |> Ash.read(domain: Ingestion)
    end
  end

  def get_run_preview(run_id, opts \\ []) do
    with :ok <- authorize_admin(opts),
         {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id,
             domain: Ingestion,
             load: [:cancelled_by_user]
           ) do
      {:ok, %{run: run, preview: run.plan_snapshot || %{}}}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, sanitize_error(reason)}
    end
  end

  def list_source_systems(opts \\ []) do
    with :ok <- authorize_admin(opts) do
      SourceSystem
      |> Ash.Query.filter(kind == :woocommerce and active == true)
      |> Ash.Query.sort(name: :asc)
      |> Ash.read(domain: Catalog)
    end
  end

  defp maybe_select_run_summaries(query, opts) do
    if Keyword.get(opts, :summary_only?, false) do
      Ash.Query.select(query, @run_summary_fields)
    else
      query
    end
  end

  defp create_run(source_system_id, scope, opts) do
    actor = Keyword.get(opts, :actor)

    Ash.create(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source_system_id,
        requested_by_user_id: actor && actor.id,
        scope: json_safe(scope),
        status: :queued
      },
      action: :create_dry_run,
      domain: Ingestion
    )
  end

  defp enqueue_discovery(run, opts) do
    oban_insert = Keyword.get(opts, :oban_insert, &Oban.insert/1)

    case %{"run_id" => run.id}
         |> DiscoverTickeraCatalogWorker.new()
         |> oban_insert.() do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp enqueue_apply(run, dry_run_hash, opts) do
    oban_insert = Keyword.get(opts, :oban_insert, &Oban.insert/1)

    case %{"run_id" => run.id, "dry_run_hash" => dry_run_hash}
         |> ApplyTickeraCatalogWorker.new()
         |> oban_insert.() do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp revoke_run(run, reason_code, details, opts) do
    actor = Keyword.fetch!(opts, :actor)

    run
    |> Ash.Changeset.for_update(:revoke_ready_dry_run, %{
      cancelled_by_user_id: actor.id,
      cancelled_at: DateTime.utc_now(),
      cancellation_reason_code: reason_code,
      cancellation_reason_details: details
    })
    |> Ash.Changeset.filter(status: :dry_run_ready)
    |> Ash.update(domain: Ingestion)
  end

  defp normalize_cancellation_reason(attrs) do
    code =
      attrs
      |> Map.get(:cancellation_reason_code, Map.get(attrs, "cancellation_reason_code"))
      |> cancellation_reason_code()

    details =
      attrs
      |> Map.get(:cancellation_reason_details, Map.get(attrs, "cancellation_reason_details"))
      |> normalize_details()

    cond do
      code not in [
        :source_changed,
        :incorrect_scope,
        :unexpected_changes,
        :superseded,
        :operator_error,
        :other
      ] ->
        {:error, :invalid_reason_code}

      code == :other and is_nil(details) ->
        {:error, :reason_details_required}

      is_binary(details) and String.length(details) > 500 ->
        {:error, :reason_details_too_long}

      true ->
        {:ok, code, details}
    end
  end

  defp classify_revoke_failure(run_id) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %{status: :cancelled}} ->
        {:error, :already_cancelled}

      {:ok, %{status: status}} when status in [:applying, :applied] ->
        {:error, :run_already_claimed}

      {:ok, %TickeraCatalogSyncRun{}} ->
        {:error, :run_not_revokeable}

      {:ok, nil} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :failed}
    end
  end

  defp normalize_claim_result({:ok, claimed}, _run_id, _expected_hash), do: {:ok, claimed}

  defp normalize_claim_result(
         {:ok, claimed, notifications},
         _run_id,
         _expected_hash
       ),
       do: {:ok, claimed, notifications}

  defp normalize_claim_result({:error, _reason}, run_id, expected_hash) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %{status: :dry_run_ready, dry_run_hash: hash}} when hash != expected_hash ->
        {:error, :stale_dry_run_hash}

      {:ok, %TickeraCatalogSyncRun{}} ->
        {:error, :run_not_ready}

      {:ok, nil} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :failed}
    end
  end

  defp normalize_details(nil), do: nil

  defp normalize_details(details) when is_binary(details) do
    case String.trim(details) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_details(_details), do: nil

  defp cancellation_reason_code(code) when is_atom(code), do: code
  defp cancellation_reason_code("source_changed"), do: :source_changed
  defp cancellation_reason_code("incorrect_scope"), do: :incorrect_scope
  defp cancellation_reason_code("unexpected_changes"), do: :unexpected_changes
  defp cancellation_reason_code("superseded"), do: :superseded
  defp cancellation_reason_code("operator_error"), do: :operator_error
  defp cancellation_reason_code("other"), do: :other
  defp cancellation_reason_code(_code), do: nil

  defp validate_apply_ready(run, dry_run_hash) do
    with :ok <- validate_apply_status(run),
         :ok <- validate_apply_hash(run, dry_run_hash),
         {:ok, snapshot} <- fetch_plan_snapshot(run) do
      validate_no_blocking_findings(snapshot)
    end
  end

  defp validate_apply_status(%{status: :dry_run_ready}), do: :ok
  defp validate_apply_status(_run), do: {:error, :run_not_ready}

  defp validate_apply_hash(%{dry_run_hash: hash}, expected)
       when is_binary(hash) and hash == expected,
       do: :ok

  defp validate_apply_hash(_run, _expected), do: {:error, :stale_dry_run_hash}

  defp fetch_plan_snapshot(%{plan_snapshot: snapshot}) when is_map(snapshot), do: {:ok, snapshot}
  defp fetch_plan_snapshot(_run), do: {:error, :missing_plan_snapshot}

  defp validate_no_blocking_findings(snapshot) do
    if Enum.any?(list(snapshot, "findings"), &(value(&1, "severity") in [:blocking, "blocking"])) do
      {:error, :blocking_findings}
    else
      :ok
    end
  end

  defp authorize_admin(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp fetch_required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, key}
    end
  end

  defp fetch_scope(attrs) do
    case Map.get(attrs, :scope) || Map.get(attrs, "scope") do
      %{} = scope -> {:ok, scope}
      _value -> {:error, :invalid_scope}
    end
  end

  defp sanitize_error(:forbidden), do: :forbidden
  defp sanitize_error(:run_not_ready), do: :run_not_ready
  defp sanitize_error(:stale_dry_run_hash), do: :stale_dry_run_hash
  defp sanitize_error(:missing_plan_snapshot), do: :missing_plan_snapshot
  defp sanitize_error(:blocking_findings), do: :blocking_findings
  defp sanitize_error(:invalid_reason_code), do: :invalid_reason_code
  defp sanitize_error(:reason_details_required), do: :reason_details_required
  defp sanitize_error(:reason_details_too_long), do: :reason_details_too_long
  defp sanitize_error({:enqueue_failed, _reason}), do: :enqueue_failed
  defp sanitize_error(_reason), do: :failed

  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp json_safe(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe(value), do: value

  defp list(map, key) do
    case value(map, key) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end
end
