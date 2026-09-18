defmodule EventSales.Sales.OrderAttributionCorrection do
  @moduledoc """
  Admin-reviewed correction for the confirmed Woo order 113834 attribution issue.

  This is intentionally not a general historical remap API. It validates the
  exact confirmed tuple and changes one `OrderItem` through Ash only.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Analytics.DashboardCache
  alias EventSales.Audit.Logger, as: AuditLogger
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping}
  alias EventSales.Ingestion.HistoricalCoverageInvalidator
  alias EventSales.Ingestion.HistoricalOrderMutationDetector
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}

  @woo_order_id 113_834
  @woo_product_id 109_132
  @woo_variation_id 109_167
  @quantity 5
  @current_event_external_id 108_658
  @target_event_external_id 109_120
  @confirmation "CORRECT ORDER 113834 109132/109167 FROM 108658 TO 109120"

  @type error_reason ::
          :forbidden
          | :confirmation_required
          | :order_not_found
          | :order_item_not_found
          | :multiple_order_items_found
          | :current_event_mismatch
          | :target_event_missing
          | :target_mapping_missing
          | :manual_review_required
          | :audit_failed
          | :historical_order_before_capture_failed
          | :historical_order_after_capture_failed
          | :historical_order_truth_unchanged
          | :invalid_order
          | :invalid_event_id
          | :historical_coverage_lookup_failed
          | :coverage_source_mismatch
          | :order_coverage_invalidation_failed

  @spec preview_confirmed_order_113834(Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, error_reason()}
  def preview_confirmed_order_113834(source_system_id, opts \\ []) do
    with :ok <- authorize_admin(opts),
         {:ok, context} <- preview_context(source_system_id, lock?: false) do
      {:ok, public_preview(context)}
    end
  end

  @spec correct_confirmed_order_113834(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, %{order_item: OrderItem.t(), preview: map()}} | {:error, error_reason()}
  def correct_confirmed_order_113834(source_system_id, confirmation, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    with :ok <- authorize_admin(opts),
         :ok <- validate_confirmation(confirmation) do
      source_system_id
      |> correction_transaction(actor)
      |> handle_correction_transaction()
    end
  end

  defp correction_transaction(source_system_id, actor) do
    Repo.transaction(fn -> correction_transaction_body(source_system_id, actor) end)
  end

  defp correction_transaction_body(source_system_id, actor) do
    with {:ok, context} <- preview_context(source_system_id, lock?: true),
         {:ok, before_snapshot} <- capture_before(context.order),
         {:ok, corrected, notifications} <- correct_order_item(context, actor),
         {:ok, _audit_log} <- audit_correction(context, corrected, actor),
         {:ok, after_snapshot} <- capture_after(context.order),
         {:ok, comparison} <- compare_correction_truth(before_snapshot, after_snapshot),
         :ok <- invalidate_correction_coverage(context.order, comparison) do
      {corrected, public_preview(%{context | order_item: corrected}), notifications, context}
    else
      {:error, :audit_failed} -> Repo.rollback(:audit_failed)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp handle_correction_transaction({:ok, {corrected, preview, notifications, context}}) do
    Ash.Notifier.notify(notifications)
    DashboardCache.invalidate_event(context.current_event.id, :order_attribution_corrected)
    DashboardCache.invalidate_event(context.target_event.id, :order_attribution_corrected)
    {:ok, %{order_item: corrected, preview: preview}}
  end

  defp handle_correction_transaction({:error, reason}), do: {:error, reason}

  defp authorize_admin(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp validate_confirmation(@confirmation), do: :ok
  defp validate_confirmation(_confirmation), do: {:error, :confirmation_required}

  defp preview_context(source_system_id, opts) do
    with {:ok, %Order{} = order} <- load_order(source_system_id, opts),
         {:ok, %OrderItem{} = item} <- load_confirmed_item(order, opts),
         {:ok, loaded_item} <- load_item_catalog(item),
         :ok <- validate_current_event(loaded_item),
         {:ok, %Event{} = target_event} <- load_target_event(source_system_id),
         {:ok, %ProductMapping{} = target_mapping} <- load_target_mapping(source_system_id),
         :ok <- validate_target_mapping(target_mapping, target_event) do
      {:ok,
       %{
         order: order,
         order_item: loaded_item,
         current_event: loaded_item.event,
         current_ticket_type: loaded_item.ticket_type,
         target_event: target_event,
         target_mapping: target_mapping,
         target_ticket_type: target_mapping.ticket_type
       }}
    end
  end

  defp load_order(source_system_id, opts) do
    query =
      Order
      |> Ash.Query.filter(source_system_id == ^source_system_id and woo_order_id == @woo_order_id)
      |> Ash.Query.limit(1)
      |> maybe_lock(opts)

    query
    |> Ash.read_one(domain: Sales)
    |> case do
      {:ok, %Order{} = order} -> {:ok, order}
      {:ok, nil} -> {:error, :order_not_found}
      {:error, _reason} -> {:error, :order_not_found}
    end
  end

  defp load_confirmed_item(%Order{id: order_id}, opts) do
    query =
      OrderItem
      |> Ash.Query.filter(
        order_id == ^order_id and
          woo_product_id == @woo_product_id and
          woo_variation_id == @woo_variation_id and
          quantity == @quantity and
          item_kind == :ticket
      )
      |> maybe_lock(opts)

    case Ash.read(query, domain: Sales) do
      {:ok, [item]} -> {:ok, item}
      {:ok, []} -> {:error, :order_item_not_found}
      {:ok, _items} -> {:error, :multiple_order_items_found}
      {:error, _reason} -> {:error, :order_item_not_found}
    end
  end

  defp maybe_lock(query, opts) do
    if Keyword.get(opts, :lock?, false) do
      Ash.Query.lock(query, :for_update)
    else
      query
    end
  end

  defp load_item_catalog(%OrderItem{} = item),
    do: Ash.load(item, [:event, :ticket_type], domain: Sales)

  defp validate_current_event(%OrderItem{
         event: %Event{external_event_id: @current_event_external_id}
       }),
       do: :ok

  defp validate_current_event(_item), do: {:error, :current_event_mismatch}

  defp load_target_event(source_system_id) do
    Event
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        external_event_kind == :tickera_event and
        external_event_id == @target_event_external_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
    |> case do
      {:ok, %Event{} = event} -> {:ok, event}
      {:ok, nil} -> {:error, :target_event_missing}
      {:error, _reason} -> {:error, :target_event_missing}
    end
  end

  defp load_target_mapping(source_system_id) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        woo_product_id == @woo_product_id and
        woo_variation_id == @woo_variation_id and
        active == true
    )
    |> Ash.Query.limit(1)
    |> Ash.Query.load(:ticket_type)
    |> Ash.read_one(domain: Catalog)
    |> case do
      {:ok, %ProductMapping{} = mapping} -> {:ok, mapping}
      {:ok, nil} -> {:error, :target_mapping_missing}
      {:error, _reason} -> {:error, :target_mapping_missing}
    end
  end

  defp validate_target_mapping(
         %ProductMapping{event_id: event_id, ticket_type: %{event_id: event_id}},
         %Event{id: event_id}
       ),
       do: :ok

  defp validate_target_mapping(_mapping, _target_event), do: {:error, :target_mapping_missing}

  defp capture_before(%Order{} = order) do
    case HistoricalOrderMutationDetector.capture(order) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, _reason} -> {:error, :historical_order_before_capture_failed}
    end
  end

  defp capture_after(%Order{} = order) do
    case HistoricalOrderMutationDetector.capture(order) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, _reason} -> {:error, :historical_order_after_capture_failed}
    end
  end

  defp compare_correction_truth(before_snapshot, after_snapshot) do
    comparison = HistoricalOrderMutationDetector.compare(before_snapshot, after_snapshot)

    if comparison.changed? do
      {:ok, comparison}
    else
      {:error, :historical_order_truth_unchanged}
    end
  end

  defp invalidate_correction_coverage(
         %Order{} = order,
         %{changed?: true, candidate_event_ids: candidate_event_ids}
       ) do
    case HistoricalCoverageInvalidator.invalidate_order_change(order, candidate_event_ids) do
      {:ok, _result} ->
        :ok

      {:error, reason}
      when reason in [
             :invalid_order,
             :invalid_event_id,
             :historical_coverage_lookup_failed,
             :coverage_source_mismatch,
             :order_coverage_invalidation_failed
           ] ->
        {:error, reason}

      _other ->
        {:error, :order_coverage_invalidation_failed}
    end
  end

  defp correct_order_item(context, actor) do
    Ash.update(
      context.order_item,
      %{
        event_id: context.target_event.id,
        ticket_type_id: context.target_mapping.ticket_type_id,
        source_tickera_event_id: @target_event_external_id,
        attribution_status_reason: nil
      },
      action: :correct_event_attribution,
      domain: Sales,
      actor: actor,
      context: %{warn_on_transaction_hooks?: false},
      return_notifications?: true
    )
  end

  defp audit_correction(context, corrected, actor) do
    actor_user_id = if actor, do: actor.id

    AuditLogger.order_attribution_corrected(%{
      actor_type: :user,
      actor_user_id: actor_user_id,
      actor_role: :admin,
      source: :admin,
      subject_type: "order_item",
      subject_id: corrected.id,
      event_id: context.target_event.id,
      ash_opts: [return_notifications?: true],
      metadata: %{
        source_system_id: context.order.source_system_id,
        woo_order_id: @woo_order_id,
        woo_product_id: @woo_product_id,
        woo_variation_id: @woo_variation_id,
        quantity: @quantity,
        order_item_id: corrected.id,
        from_event_external_id: @current_event_external_id,
        to_event_external_id: @target_event_external_id,
        from_event_id: context.current_event.id,
        to_event_id: context.target_event.id,
        from_ticket_type_id: context.current_ticket_type.id,
        to_ticket_type_id: context.target_mapping.ticket_type_id,
        reason: "confirmed_single_order_correction",
        pii_policy: "safe_ids_only"
      }
    })
    |> case do
      {:ok, audit_log} -> {:ok, audit_log}
      {:error, _reason} -> {:error, :audit_failed}
    end
  end

  defp public_preview(context) do
    %{
      woo_order_id: @woo_order_id,
      woo_product_id: @woo_product_id,
      woo_variation_id: @woo_variation_id,
      quantity: @quantity,
      current_event_external_id: context.current_event.external_event_id,
      target_event_external_id: context.target_event.external_event_id,
      current_ticket_type_name: context.current_ticket_type.name,
      target_ticket_type_name: context.target_ticket_type.name,
      order_item_id: context.order_item.id
    }
  end
end
