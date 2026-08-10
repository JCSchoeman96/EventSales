defmodule EventSales.Ingestion.TickeraCatalogSync do
  @moduledoc """
  Admin facade for Tickera catalog sync dry-run and apply.

  Path 1 M2-03 adds an Event-owned queue boundary and a pure parent-product
  membership projection over normalized `CatalogRow` evidence. Path 1 M2-05
  adds the adjacent pure variation membership projection over the same rows.
  Discovery still runs through existing dry-run / Oban machinery; no Apply or
  mapping mutation.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, SourceSystem}
  alias EventSales.Catalog.TickeraCatalog.CatalogRow
  alias EventSales.Catalog.TickeraCatalog.PubSub
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{CatalogChangePendingTarget, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.Workers.{ApplyTickeraCatalogWorker, DiscoverTickeraCatalogWorker}
  alias EventSales.Repo

  @default_limit 50
  @active_constraint "ingestion_tickera_catalog_sync_runs_one_active_per_source_idx"
  @review_only_snapshot_version "tickera_catalog_plan.v3"
  @run_summary_fields [
    :id,
    :source_system_id,
    :origin,
    :scope,
    :status,
    :dry_run_hash,
    :summary,
    :started_at,
    :finished_at,
    :last_error,
    :retry_attempt,
    :retry_max_attempts,
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
         {:ok, %{run: run, job: job}} <- queue_run_and_job(source_system_id, scope, opts) do
      {:ok, %{run: run, job: job}}
    end
  end

  @doc """
  Queues bounded event-scoped Tickera catalog dry-run discovery for one exact local Event.

  Loads the Event by UUID, requires authoritative Tickera external identity, and derives
  both `source_system_id` and `%{"kind" => "wordpress_feed", "event_id" => ...}` from that
  Event. Callers cannot supply an unrelated source/event pair.
  """
  @spec queue_event_product_discovery(Ecto.UUID.t(), keyword()) ::
          {:ok, %{run: TickeraCatalogSyncRun.t(), job: Oban.Job.t(), event: Event.t()}}
          | {:error, atom()}
  def queue_event_product_discovery(local_event_id, opts \\ [])

  def queue_event_product_discovery(local_event_id, opts) when is_binary(local_event_id) do
    with :ok <- authorize_admin(opts),
         {:ok, event} <- load_authoritative_tickera_event(local_event_id),
         scope <- event_product_discovery_scope(event),
         {:ok, %{run: run, job: job}} <-
           queue_run_and_job(event.source_system_id, scope, opts) do
      {:ok, %{run: run, job: job, event: event}}
    end
  end

  def queue_event_product_discovery(_local_event_id, _opts), do: {:error, :invalid_event_id}

  @doc """
  Projects unique parent Woo product identities for one exact local Tickera Event.

  Loads the Event by UUID and derives both `source_system_id` and the selected Tickera
  external event id from that Event. Product identity remains
  `(source_system_id, woo_product_id)` and cannot be caller-relabelled under another
  SourceSystem. Variation-bearing rows contribute only their parent product.
  Foreign-event rows and invalid product IDs fail closed. Does not read or mutate
  ProductMapping / TicketType.
  """
  @spec project_event_parent_products(Ecto.UUID.t(), [CatalogRow.t()]) ::
          {:ok, %{products: [map()], product_count: non_neg_integer()}} | {:error, atom()}
  def project_event_parent_products(local_event_id, rows)
      when is_binary(local_event_id) and is_list(rows) do
    with {:ok, event} <- load_authoritative_tickera_event(local_event_id) do
      project_parent_products(event.source_system_id, event.external_event_id, rows)
    end
  end

  def project_event_parent_products(_local_event_id, _rows), do: {:error, :invalid_input}

  @doc """
  Projects unique Woo variation identities for one exact local Tickera Event.

  Loads the Event by UUID and derives both `source_system_id` and the selected
  Tickera external event id from that Event. Variation identity remains
  `(source_system_id, woo_product_id, woo_variation_id)` and cannot be
  caller-relabelled under another SourceSystem. Simple-product rows (nil
  variation) are ignored. Foreign-event rows and invalid product/variation IDs
  fail closed. Does not read or mutate ProductMapping / TicketType.
  """
  @spec project_event_variations(Ecto.UUID.t(), [CatalogRow.t()]) ::
          {:ok, %{variations: [map()], variation_count: non_neg_integer()}} | {:error, atom()}
  def project_event_variations(local_event_id, rows)
      when is_binary(local_event_id) and is_list(rows) do
    with {:ok, event} <- load_authoritative_tickera_event(local_event_id) do
      project_variations(event.source_system_id, event.external_event_id, rows)
    end
  end

  def project_event_variations(_local_event_id, _rows), do: {:error, :invalid_input}

  defp project_parent_products(source_system_id, selected_tickera_event_id, rows)
       when is_binary(source_system_id) and is_integer(selected_tickera_event_id) and
              selected_tickera_event_id > 0 and is_list(rows) do
    with :ok <- validate_selected_event_membership(selected_tickera_event_id, rows),
         {:ok, product_ids} <- collect_parent_product_ids(rows) do
      products =
        product_ids
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(fn woo_product_id ->
          %{source_system_id: source_system_id, woo_product_id: woo_product_id}
        end)

      {:ok, %{products: products, product_count: length(products)}}
    end
  end

  defp project_variations(source_system_id, selected_tickera_event_id, rows)
       when is_binary(source_system_id) and is_integer(selected_tickera_event_id) and
              selected_tickera_event_id > 0 and is_list(rows) do
    with :ok <- validate_selected_event_membership(selected_tickera_event_id, rows),
         {:ok, variation_tuples} <- collect_variation_identities(rows) do
      variations =
        variation_tuples
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(fn {woo_product_id, woo_variation_id} ->
          %{
            source_system_id: source_system_id,
            woo_product_id: woo_product_id,
            woo_variation_id: woo_variation_id
          }
        end)

      {:ok, %{variations: variations, variation_count: length(variations)}}
    end
  end

  def queue_triggered_dry_run(pending_target_id, expected_generation, opts \\ []) do
    result =
      with :ok <-
             run_before_job_insert_hook(
               opts,
               :before_trigger_lock,
               :invalid_before_trigger_lock_hook,
               :invalid_before_trigger_lock_result
             ) do
        queue_triggered_transaction(pending_target_id, expected_generation, opts)
      end

    case result do
      {:ok, %{notifications: notifications} = value} ->
        Ash.Notifier.notify(notifications)
        {:ok, Map.delete(value, :notifications)}

      {:error, reason} ->
        {:error, triggered_queue_error(reason)}
    end
  end

  defp queue_triggered_transaction(pending_target_id, expected_generation, opts) do
    Repo.transaction(fn ->
      with :ok <- lock_pending_target(pending_target_id),
           {:ok, %CatalogChangePendingTarget{} = target} <-
             Ash.get(CatalogChangePendingTarget, pending_target_id, domain: Ingestion),
           true <- target.generation == expected_generation,
           :ok <- validate_trigger_source(target.source_system_id),
           {:ok, scope} <- triggered_scope(target),
           {:ok, run, run_notifications} <-
             create_run(
               target.source_system_id,
               scope,
               Keyword.put(opts, :origin, :targeted_catalog_change)
             ),
           {:ok, job} <- enqueue_discovery(run, opts),
           {:ok, linked, target_notifications} <- link_triggered_target(target, run.id) do
        %{
          run: run,
          job: job,
          target: linked,
          notifications: run_notifications ++ target_notifications
        }
      else
        false -> Repo.rollback(:stale_generation)
        {:ok, nil} -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp triggered_queue_error(:stale_generation), do: :stale_generation
  defp triggered_queue_error(:not_found), do: :not_found
  defp triggered_queue_error(:invalid_scope), do: :invalid_scope
  defp triggered_queue_error(:source_not_eligible), do: :source_not_eligible
  defp triggered_queue_error(reason), do: queue_error(reason)

  defp triggered_scope(%{target_type: :event, target_id: id}),
    do: {:ok, %{"kind" => "wordpress_feed", "event_id" => id}}

  defp triggered_scope(%{target_type: :product, target_id: id}),
    do: {:ok, %{"kind" => "wordpress_feed", "product_id" => id}}

  defp triggered_scope(%{target_type: :variation, target_id: id}),
    do: {:ok, %{"kind" => "wordpress_feed", "variation_id" => id}}

  defp triggered_scope(_), do: {:error, :invalid_scope}

  defp lock_pending_target(id) do
    case Repo.query(
           "SELECT id FROM ingestion_catalog_change_pending_targets WHERE id = $1 FOR UPDATE",
           [Ecto.UUID.dump!(id)]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_trigger_source(source_system_id) do
    case Ash.get(SourceSystem, source_system_id, domain: Catalog) do
      {:ok, %{active: true, kind: :woocommerce}} -> :ok
      {:ok, nil} -> {:error, :not_found}
      {:ok, _source} -> {:error, :source_not_eligible}
      {:error, reason} -> {:error, reason}
    end
  end

  defp link_triggered_target(target, run_id) do
    target
    |> Ash.Changeset.for_update(:transition, %{
      state: :queued,
      dispatched_generation: target.generation,
      catalog_sync_run_id: run_id,
      dispatch_attempts: target.dispatch_attempts + 1,
      recheck_at: DateTime.add(DateTime.utc_now(), 60, :second),
      last_error: nil
    })
    |> Ash.update(domain: Ingestion, return_notifications?: true)
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

  def active_run_for_source(source_system_id, opts \\ []) when is_binary(source_system_id) do
    with :ok <- authorize_admin(opts) do
      TickeraCatalogSyncRun
      |> Ash.Query.filter(
        source_system_id == ^source_system_id and
          status in [:queued, :discovering, :retry_scheduled, :dry_run_ready, :applying]
      )
      |> Ash.Query.select([:id, :status])
      |> Ash.read_one(domain: Ingestion)
    end
  end

  defp maybe_select_run_summaries(query, opts) do
    if Keyword.get(opts, :summary_only?, false) do
      Ash.Query.select(query, @run_summary_fields)
    else
      query
    end
  end

  defp queue_run_and_job(source_system_id, scope, opts) do
    source_system_id
    |> queue_transaction(scope, opts)
    |> finalize_queue_transaction()
  end

  defp queue_transaction(source_system_id, scope, opts) do
    Repo.transaction(fn ->
      with {:ok, run, notifications} <- create_run(source_system_id, scope, opts),
           {:ok, job} <- enqueue_discovery(run, opts) do
        %{run: run, job: job, notifications: notifications}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp finalize_queue_transaction(transaction_result) do
    case transaction_result do
      {:ok, %{notifications: notifications} = result} ->
        Ash.Notifier.notify(notifications)
        {:ok, Map.delete(result, :notifications)}

      {:error, reason} ->
        {:error, queue_error(reason)}
    end
  end

  defp create_run(source_system_id, scope, opts) do
    actor = Keyword.get(opts, :actor)
    origin = Keyword.get(opts, :origin, if(actor, do: :human_admin, else: :legacy_unknown))

    Ash.create(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source_system_id,
        requested_by_user_id: actor && actor.id,
        scope: json_safe(scope),
        origin: origin
      },
      action: :create_dry_run,
      domain: Ingestion,
      context: %{warn_on_transaction_hooks?: false},
      return_notifications?: true
    )
  end

  defp enqueue_discovery(run, opts) do
    job = DiscoverTickeraCatalogWorker.new(%{"run_id" => run.id})

    with :ok <-
           run_before_job_insert_hook(
             opts,
             :before_discovery_job_insert,
             :invalid_before_discovery_job_insert_hook,
             :invalid_before_discovery_job_insert_result
           ),
         {:ok, persisted_job} <- Oban.insert(job) do
      {:ok, persisted_job}
    else
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp enqueue_apply(run, dry_run_hash, opts) do
    job = ApplyTickeraCatalogWorker.new(%{"run_id" => run.id, "dry_run_hash" => dry_run_hash})

    with :ok <-
           run_before_job_insert_hook(
             opts,
             :before_apply_job_insert,
             :invalid_before_apply_job_insert_hook,
             :invalid_before_apply_job_insert_result
           ),
         {:ok, persisted_job} <- Oban.insert(job) do
      {:ok, persisted_job}
    else
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp run_before_job_insert_hook(opts, hook_key, invalid_hook, invalid_result) do
    case Keyword.fetch(opts, hook_key) do
      :error ->
        :ok

      {:ok, hook} when is_function(hook, 0) ->
        case hook.() do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
          _other -> {:error, invalid_result}
        end

      {:ok, _hook} ->
        {:error, invalid_hook}
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
        :mapping_resolution_started,
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
  defp cancellation_reason_code("mapping_resolution_started"), do: :mapping_resolution_started
  defp cancellation_reason_code("other"), do: :other
  defp cancellation_reason_code(_code), do: nil

  defp validate_apply_ready(run, dry_run_hash) do
    with :ok <- validate_apply_status(run),
         :ok <- validate_apply_hash(run, dry_run_hash),
         {:ok, snapshot} <- fetch_plan_snapshot(run),
         :ok <- validate_supported_snapshot_version(snapshot) do
      validate_no_blocking_findings(snapshot)
    end
  end

  # Review-only `tickera_catalog_plan.v3` can never be queued for Apply.
  defp validate_supported_snapshot_version(snapshot) do
    if value(snapshot, "snapshot_schema_version") == @review_only_snapshot_version do
      {:error, :unsupported_snapshot_version}
    else
      :ok
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

  defp load_authoritative_tickera_event(local_event_id) do
    case Ash.get(Event, local_event_id, domain: Catalog) do
      {:ok, %Event{} = event} ->
        validate_tickera_external_identity(event)

      {:ok, nil} ->
        {:error, :event_not_found}

      {:error, reason} ->
        classify_event_lookup_error(reason)
    end
  end

  # Ash.get expresses authoritative absence as Query.NotFound.
  defp classify_event_lookup_error(%Ash.Error.Invalid{
         errors: [%Ash.Error.Query.NotFound{} | _]
       }),
       do: {:error, :event_not_found}

  defp classify_event_lookup_error(_reason), do: {:error, :event_lookup_failed}

  defp validate_tickera_external_identity(
         %Event{external_event_kind: :tickera_event, external_event_id: id} = event
       )
       when is_integer(id) and id > 0 do
    {:ok, event}
  end

  defp validate_tickera_external_identity(%Event{}),
    do: {:error, :missing_external_event_identity}

  defp event_product_discovery_scope(%Event{external_event_id: event_id}) do
    %{"kind" => "wordpress_feed", "event_id" => event_id}
  end

  defp validate_selected_event_membership(selected_tickera_event_id, rows) do
    if Enum.any?(rows, &(&1.tickera_event_id != selected_tickera_event_id)) do
      {:error, :foreign_event_row}
    else
      :ok
    end
  end

  defp collect_parent_product_ids(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, ids} ->
      case row.woo_product_id do
        id when is_integer(id) and id > 0 ->
          {:cont, {:ok, [id | ids]}}

        _invalid ->
          {:halt, {:error, :invalid_product_identity}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      other -> other
    end
  end

  # Simple/nil variation rows are ignored. Variation-bearing rows require both
  # positive parent and variation IDs; identity remains parent+variation.
  defp collect_variation_identities(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, tuples} ->
      case variation_identity_from_row(row) do
        :ignore -> {:cont, {:ok, tuples}}
        {:ok, tuple} -> {:cont, {:ok, [tuple | tuples]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tuples} -> {:ok, Enum.reverse(tuples)}
      other -> other
    end
  end

  defp variation_identity_from_row(%CatalogRow{woo_variation_id: nil}), do: :ignore

  defp variation_identity_from_row(%CatalogRow{
         woo_product_id: product_id,
         woo_variation_id: variation_id
       })
       when is_integer(product_id) and product_id > 0 and is_integer(variation_id) and
              variation_id > 0 do
    {:ok, {product_id, variation_id}}
  end

  defp variation_identity_from_row(%CatalogRow{woo_product_id: product_id, woo_variation_id: id})
       when not is_nil(id) and (not is_integer(product_id) or product_id <= 0) do
    {:error, :invalid_product_identity}
  end

  defp variation_identity_from_row(%CatalogRow{}), do: {:error, :invalid_variation_identity}

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
  defp sanitize_error(:catalog_sync_already_active), do: :catalog_sync_already_active
  defp sanitize_error(:run_not_ready), do: :run_not_ready
  defp sanitize_error(:stale_dry_run_hash), do: :stale_dry_run_hash
  defp sanitize_error(:missing_plan_snapshot), do: :missing_plan_snapshot
  defp sanitize_error(:blocking_findings), do: :blocking_findings
  defp sanitize_error(:unsupported_snapshot_version), do: :unsupported_snapshot_version
  defp sanitize_error(:invalid_reason_code), do: :invalid_reason_code
  defp sanitize_error(:reason_details_required), do: :reason_details_required
  defp sanitize_error(:reason_details_too_long), do: :reason_details_too_long
  defp sanitize_error({:enqueue_failed, _reason}), do: :enqueue_failed
  defp sanitize_error(_reason), do: :failed

  defp queue_error(reason) do
    if active_run_constraint?(reason),
      do: :catalog_sync_already_active,
      else: sanitize_error(reason)
  end

  defp active_run_constraint?(%{constraint: @active_constraint}), do: true

  defp active_run_constraint?(%{private_vars: private_vars}) when is_list(private_vars),
    do: Keyword.get(private_vars, :constraint) == @active_constraint

  defp active_run_constraint?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &active_run_constraint?/1)

  defp active_run_constraint?(errors) when is_list(errors),
    do: Enum.any?(errors, &active_run_constraint?/1)

  defp active_run_constraint?(_reason), do: false

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
