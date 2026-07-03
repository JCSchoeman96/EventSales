defmodule EventSales.Catalog.TickeraCatalog.Applier do
  @moduledoc """
  Applies durable Tickera catalog dry-run snapshots.
  """

  alias EventSales.Analytics.{DashboardCache, DashboardPubSub}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.Workers.MissingCatalogResolutionWorker

  @spec apply(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, TickeraCatalogSyncRun.t()} | {:error, term()}
  def apply(run_id, expected_dry_run_hash, _opts \\ [])
      when is_binary(run_id) and is_binary(expected_dry_run_hash) do
    with {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion),
         :ok <- validate_hash(run, expected_dry_run_hash),
         {:ok, snapshot} <- fetch_snapshot(run),
         :ok <- validate_no_blocking(snapshot),
         {:ok, touched} <- apply_snapshot(run, snapshot),
         {:ok, applied} <- mark_applied(run) do
      after_apply(run.source_system_id, touched)
      {:ok, applied}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp apply_snapshot(_run, snapshot) do
    refs =
      %{}
      |> apply_events(list(snapshot, "event_changes"))
      |> apply_ticket_types(list(snapshot, "ticket_type_changes"))
      |> apply_mappings(list(snapshot, "product_mapping_changes"))

    {:ok,
     %{
       event_ids:
         Enum.uniq(list(snapshot, "touched_event_ids") ++ Map.get(refs, :created_event_ids, [])),
       product_keys: list(snapshot, "touched_product_keys")
     }}
  rescue
    error -> {:error, error}
  end

  defp apply_events(refs, changes) do
    Enum.reduce(changes, refs, fn change, refs ->
      case value(change, "action") do
        action when action in [:adopt_existing, "adopt_existing"] ->
          event = Ash.get!(Event, value(change, "event_id"), domain: Catalog)

          Ash.update!(
            event,
            %{
              external_event_id: value(change, "external_event_id"),
              external_event_kind: atom(value(change, "external_event_kind")),
              source_status: value(change, "source_status"),
              source_updated_at: parse_datetime(value(change, "source_updated_at")),
              last_synced_at: DateTime.utc_now()
            },
            action: :update,
            domain: Catalog
          )

          refs

        action when action in [:create, "create"] ->
          event =
            Ash.create!(
              Event,
              %{
                source_system_id: value(change, "source_system_id"),
                name: value(change, "name"),
                slug: value(change, "slug"),
                status: :active,
                external_event_id: value(change, "external_event_id"),
                external_event_kind: :tickera_event,
                source_status: value(change, "source_status"),
                source_updated_at: parse_datetime(value(change, "source_updated_at")),
                last_synced_at: DateTime.utc_now()
              },
              action: :create,
              domain: Catalog
            )

          refs
          |> Map.put({:event_ref, value(change, "ref")}, event.id)
          |> Map.update(:created_event_ids, [event.id], &[event.id | &1])
      end
    end)
  end

  defp apply_ticket_types(refs, changes) do
    Enum.reduce(changes, refs, fn change, refs ->
      case value(change, "action") do
        action when action in [:adopt_existing, "adopt_existing"] ->
          ticket = Ash.get!(TicketType, value(change, "ticket_type_id"), domain: Catalog)

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
            domain: Catalog
          )

          refs

        action when action in [:create, "create"] ->
          event_id = Map.fetch!(refs, {:event_ref, value(change, "event_ref")})

          ticket =
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
              domain: Catalog
            )

          Map.put(refs, {:ticket_ref, value(change, "ref")}, ticket.id)
      end
    end)
  end

  defp apply_mappings(refs, changes) do
    Enum.reduce(changes, refs, fn change, refs ->
      event_id = Map.fetch!(refs, {:event_ref, value(change, "event_ref")})
      ticket_type_id = Map.fetch!(refs, {:ticket_ref, value(change, "ticket_type_ref")})

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
        domain: Catalog
      )

      refs
    end)
  end

  defp mark_applied(run) do
    run
    |> Ash.Changeset.for_update(:mark_applied, %{})
    |> Ash.update(domain: Ingestion)
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
end
