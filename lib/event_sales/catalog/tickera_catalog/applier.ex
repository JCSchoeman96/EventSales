defmodule EventSales.Catalog.TickeraCatalog.Applier do
  @moduledoc """
  Applies durable Tickera catalog dry-run snapshots.
  """

  alias EventSales.Analytics.{DashboardCache, DashboardPubSub}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.TickeraCatalogSync
  alias EventSales.Ingestion.TickeraCatalogAutoApply
  alias EventSales.Ingestion.Workers.MissingCatalogResolutionWorker
  alias EventSales.Repo

  @spec apply(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, TickeraCatalogSyncRun.t()} | {:error, term()}
  def apply(run_id, expected_dry_run_hash, opts \\ [])
      when is_binary(run_id) and is_binary(expected_dry_run_hash) do
    with {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion),
         :ok <- validate_status(run),
         :ok <- validate_hash(run, expected_dry_run_hash),
         {:ok, snapshot} <- fetch_snapshot(run),
         :ok <- validate_no_blocking(snapshot),
         {:ok, {applied, touched, notifications}} <-
           apply_transaction(run.id, expected_dry_run_hash, snapshot, opts) do
      Ash.Notifier.notify(notifications)
      after_apply(run.source_system_id, touched)
      {:ok, applied}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_status(%{status: :dry_run_ready}), do: :ok
  defp validate_status(_run), do: {:error, :run_not_ready}

  defp validate_hash(%{dry_run_hash: hash}, expected) when hash == expected, do: :ok
  defp validate_hash(_run, _expected), do: {:error, :stale_dry_run_hash}

  defp fetch_snapshot(%{plan_snapshot: snapshot}) when is_map(snapshot), do: {:ok, snapshot}
  defp fetch_snapshot(_run), do: {:error, :missing_plan_snapshot}

  defp validate_no_blocking(snapshot) do
    if Enum.any?(list(snapshot, "findings"), &(value(&1, "severity") in [:blocking, "blocking"])) do
      {:error, :blocking_findings}
    else
      :ok
    end
  end

  defp apply_transaction(run_id, expected_dry_run_hash, snapshot, opts) do
    Repo.transaction(fn ->
      case do_apply_transaction(run_id, expected_dry_run_hash, snapshot, opts) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    error -> {:error, error}
  end

  defp do_apply_transaction(run_id, expected_dry_run_hash, snapshot, opts) do
    with {:ok, applying, applying_notifications} <-
           TickeraCatalogSync.claim_for_apply(run_id, expected_dry_run_hash,
             return_notifications?: true
           ),
         :ok <- mark_automatic_audit(opts, :claimed),
         {:ok, touched, snapshot_notifications} <- apply_snapshot(snapshot),
         {:ok, applied, applied_notifications} <- mark_applied(applying),
         :ok <- mark_automatic_audit(opts, :completed) do
      {:ok,
       {applied, touched,
        applying_notifications ++ snapshot_notifications ++ applied_notifications}}
    end
  end

  defp apply_snapshot(snapshot) do
    v2? = value(snapshot, "snapshot_schema_version") == "tickera_catalog_plan.v2"

    event_changes = list(snapshot, if(v2?, do: "event_actions", else: "event_changes"))

    ticket_changes =
      list(snapshot, if(v2?, do: "ticket_type_actions", else: "ticket_type_changes"))

    mapping_changes =
      list(snapshot, if(v2?, do: "product_mapping_actions", else: "product_mapping_changes"))

    refs =
      %{}
      |> apply_events(event_changes)
      |> apply_ticket_types(ticket_changes)
      |> apply_mappings(mapping_changes)

    touched =
      if v2?,
        do: value(snapshot, "touched_identifiers") || %{},
        else: snapshot

    {:ok,
     %{
       event_ids:
         Enum.uniq(
           list(touched, if(v2?, do: "event_ids", else: "touched_event_ids")) ++
             Map.get(refs, :created_event_ids, [])
         ),
       product_keys: list(touched, if(v2?, do: "product_keys", else: "touched_product_keys"))
     }, Map.get(refs, :notifications, [])}
  rescue
    error -> {:error, error}
  end

  defp mark_automatic_audit(opts, state) do
    case Keyword.get(opts, :automatic_decision_id) do
      nil -> :ok
      decision_id -> TickeraCatalogAutoApply.record_apply_audit(decision_id, state)
    end
  end

  defp apply_events(refs, changes) do
    Enum.reduce(changes, refs, fn change, refs ->
      case value(change, "action") do
        action when action in [:reuse, "reuse"] ->
          Map.put(refs, {:event_ref, value(change, "ref")}, value(change, "event_id"))

        action when action in [:update_metadata, "update_metadata"] ->
          event = Ash.get!(Event, value(change, "event_id"), domain: Catalog)

          {_event, notifications} =
            Ash.update!(
              event,
              event_update_attrs(change),
              action: :update,
              domain: Catalog,
              context: %{warn_on_transaction_hooks?: false},
              return_notifications?: true
            )

          refs
          |> maybe_put_event_ref(change)
          |> append_notifications(notifications)

        action when action in [:adopt_existing, "adopt_existing"] ->
          event = Ash.get!(Event, value(change, "event_id"), domain: Catalog)

          {_event, notifications} =
            Ash.update!(
              event,
              event_update_attrs(change)
              |> Map.merge(%{
                external_event_id: value(change, "external_event_id"),
                external_event_kind: atom(value(change, "external_event_kind"))
              }),
              action: :update,
              domain: Catalog,
              context: %{warn_on_transaction_hooks?: false},
              return_notifications?: true
            )

          append_notifications(refs, notifications)

        action when action in [:create, "create"] ->
          {event, notifications} =
            Ash.create!(
              Event,
              %{
                source_system_id: value(change, "source_system_id"),
                name: value(change, "name"),
                slug: value(change, "slug"),
                status: :active,
                external_event_id: value(change, "external_event_id"),
                external_event_kind: :tickera_event
              }
              |> Map.merge(event_update_attrs(change)),
              action: :create,
              domain: Catalog,
              context: %{warn_on_transaction_hooks?: false},
              return_notifications?: true
            )

          refs
          |> Map.put({:event_ref, value(change, "ref")}, event.id)
          |> Map.update(:created_event_ids, [event.id], &[event.id | &1])
          |> append_notifications(notifications)
      end
    end)
  end

  defp apply_ticket_types(refs, changes) do
    Enum.reduce(changes, refs, fn change, refs ->
      case value(change, "action") do
        action when action in [:reuse, "reuse"] ->
          Map.put(refs, {:ticket_ref, value(change, "ref")}, value(change, "ticket_type_id"))

        action when action in [:adopt_existing, "adopt_existing"] ->
          ticket = Ash.get!(TicketType, value(change, "ticket_type_id"), domain: Catalog)

          {_ticket, notifications} =
            Ash.update!(
              ticket,
              %{
                external_ticket_type_id: value(change, "external_ticket_type_id"),
                external_ticket_type_kind: atom(value(change, "external_ticket_type_kind")),
                external_product_id: value(change, "external_product_id"),
                external_variation_id: value(change, "external_variation_id"),
                source_status: value(change, "source_status"),
                source_updated_at: parse_datetime(value(change, "source_updated_at")),
                last_synced_at: DateTime.utc_now()
              },
              action: :update,
              domain: Catalog,
              context: %{warn_on_transaction_hooks?: false},
              return_notifications?: true
            )

          append_notifications(refs, notifications)

        action when action in [:create, "create"] ->
          event_id = Map.fetch!(refs, {:event_ref, value(change, "event_ref")})

          {ticket, notifications} =
            Ash.create!(
              TicketType,
              %{
                event_id: event_id,
                name: value(change, "name"),
                active: true,
                external_ticket_type_id: value(change, "external_ticket_type_id"),
                external_ticket_type_kind: atom(value(change, "external_ticket_type_kind")),
                external_product_id: value(change, "external_product_id"),
                external_variation_id: value(change, "external_variation_id"),
                source_status: value(change, "source_status"),
                source_updated_at: parse_datetime(value(change, "source_updated_at")),
                last_synced_at: DateTime.utc_now()
              },
              action: :create,
              domain: Catalog,
              context: %{warn_on_transaction_hooks?: false},
              return_notifications?: true
            )

          refs
          |> Map.put({:ticket_ref, value(change, "ref")}, ticket.id)
          |> append_notifications(notifications)
      end
    end)
  end

  defp apply_mappings(refs, changes) do
    Enum.reduce(changes, refs, fn change, refs ->
      event_id = Map.fetch!(refs, {:event_ref, value(change, "event_ref")})
      ticket_type_id = Map.fetch!(refs, {:ticket_ref, value(change, "ticket_type_ref")})

      {_mapping, notifications} =
        Ash.create!(
          ProductMapping,
          %{
            source_system_id: value(change, "source_system_id"),
            event_id: event_id,
            ticket_type_id: ticket_type_id,
            woo_product_id: value(change, "woo_product_id"),
            woo_variation_id: value(change, "woo_variation_id"),
            original_label: value(change, "original_label"),
            current_label: value(change, "current_label"),
            active: true
          },
          action: :create,
          domain: Catalog,
          context: %{warn_on_transaction_hooks?: false},
          return_notifications?: true
        )

      append_notifications(refs, notifications)
    end)
  end

  defp mark_applied(run) do
    case run
         |> Ash.Changeset.for_update(:mark_applied, %{})
         |> Ash.update(
           domain: Ingestion,
           context: %{warn_on_transaction_hooks?: false},
           return_notifications?: true
         ) do
      {:ok, applied, notifications} -> {:ok, applied, notifications}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_notifications(refs, notifications) do
    Map.update(refs, :notifications, notifications, &(&1 ++ notifications))
  end

  defp maybe_put_event_ref(refs, change) do
    case value(change, "ref") do
      nil -> refs
      ref -> Map.put(refs, {:event_ref, ref}, value(change, "event_id"))
    end
  end

  defp event_update_attrs(change) do
    %{
      source_status: value(change, "source_status"),
      source_updated_at: parse_datetime(value(change, "source_updated_at")),
      starts_at: parse_datetime(value(change, "starts_at")),
      ends_at: parse_datetime(value(change, "ends_at")),
      venue_name: value(change, "venue_name"),
      booking_fee_type: atom(value(change, "booking_fee_type")),
      booking_fee_value: decimal(value(change, "booking_fee_value")),
      last_synced_at: DateTime.utc_now()
    }
  end

  defp after_apply(source_system_id, touched) do
    Enum.each(touched.event_ids, fn event_id ->
      DashboardCache.invalidate_event(event_id, :tickera_catalog_sync_applied)
      DashboardPubSub.broadcast_hot_state_updated(event_id, DateTime.utc_now())
    end)

    Enum.each(touched.product_keys, fn product_key ->
      [product_id, variation_id] = product_key

      %{
        "source_system_id" => source_system_id,
        "woo_product_id" => product_id,
        "woo_variation_id" => variation_id
      }
      |> MissingCatalogResolutionWorker.new()
      |> Oban.insert!()
    end)

    :ok
  end

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

  defp atom(value) when is_atom(value), do: value
  defp atom(value) when is_binary(value), do: String.to_existing_atom(value)
  defp atom(value), do: value

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(value), do: value

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {%Decimal{} = parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp decimal(value), do: value
end
