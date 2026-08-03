defmodule EventSales.Catalog.ManualMappingCreator do
  @moduledoc """
  Workflow boundary for production-safe manual product mapping creation.

  This module owns the admin-only write path for exceptional WooCommerce
  products. LiveViews call this boundary instead of writing Catalog resources
  directly.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Audit.Logger, as: AuditLogger
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, SourceSystem, TicketType}
  alias EventSales.Repo

  @source_statuses ~w(manual publish private legacy pre_sale)

  @type result ::
          {:ok,
           %{
             mapping: ProductMapping.t(),
             ticket_type: TicketType.t(),
             created_ticket_type?: boolean()
           }}
          | {:error, atom()}

  @spec create(map(), keyword()) :: result()
  def create(params, opts) when is_map(params) and is_list(opts) do
    actor = Keyword.get(opts, :actor)

    with :ok <- authorize(actor),
         {:ok, normalized} <- normalize(params),
         {:ok, provenance} <- normalize_provenance(Keyword.get(opts, :provenance, %{})),
         {:ok, source} <- fetch_source_system(normalized.source_system_id),
         {:ok, event} <- fetch_event(normalized.event_id, source),
         :ok <- reject_duplicate(normalized) do
      create_transaction(normalized, event, actor, provenance)
    end
  end

  def create(_params, _opts), do: {:error, :invalid_params}

  @spec source_statuses() :: [String.t()]
  def source_statuses, do: @source_statuses

  defp authorize(actor) do
    if Policies.global_admin?(actor), do: :ok, else: {:error, :forbidden}
  end

  defp create_transaction(normalized, event, actor, provenance) do
    Repo.transaction(fn ->
      case create_in_transaction(normalized, event, actor, provenance) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp normalize(params) do
    params = trim_strings(params)

    with {:ok, source_system_id} <- required_string(params, "source_system_id", :source_required),
         {:ok, event_id} <- required_string(params, "event_id", :event_required),
         {:ok, mode} <- ticket_type_mode(Map.get(params, "ticket_type_mode")),
         {:ok, woo_product_id} <-
           positive_integer(params, "woo_product_id", :invalid_woo_product_id),
         {:ok, woo_variation_id} <-
           optional_positive_integer(params, "woo_variation_id", :invalid_woo_variation_id),
         {:ok, label} <- required_string(params, "label", :label_required),
         {:ok, reason} <- required_string(params, "reason", :reason_required),
         {:ok, source_status} <- source_status(Map.get(params, "source_status")),
         {:ok, ticket_type_id, ticket_type_name} <- ticket_type_fields(params, mode) do
      {:ok,
       %{
         source_system_id: source_system_id,
         event_id: event_id,
         ticket_type_mode: mode,
         ticket_type_id: ticket_type_id,
         ticket_type_name: ticket_type_name,
         woo_product_id: woo_product_id,
         woo_variation_id: woo_variation_id,
         label: label,
         source_status: source_status,
         reason: reason
       }}
    end
  end

  defp trim_strings(params) do
    Map.new(params, fn
      {key, value} when is_binary(value) -> {key, String.trim(value)}
      other -> other
    end)
  end

  defp required_string(params, key, error) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, error}
    end
  end

  defp ticket_type_mode("existing"), do: {:ok, :existing}
  defp ticket_type_mode("new"), do: {:ok, :new}
  defp ticket_type_mode(_other), do: {:error, :invalid_ticket_type_mode}

  defp ticket_type_fields(params, :existing) do
    with {:ok, ticket_type_id} <- required_string(params, "ticket_type_id", :ticket_type_required) do
      {:ok, ticket_type_id, nil}
    end
  end

  defp ticket_type_fields(params, :new) do
    with {:ok, ticket_type_name} <-
           required_string(params, "ticket_type_name", :ticket_type_name_required) do
      {:ok, nil, ticket_type_name}
    end
  end

  defp positive_integer(params, key, error) do
    case Map.get(params, key) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> {:ok, integer}
          _other -> {:error, error}
        end

      _other ->
        {:error, error}
    end
  end

  defp optional_positive_integer(params, key, error) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      _value -> positive_integer(params, key, error)
    end
  end

  defp source_status(nil), do: {:error, :source_status_required}
  defp source_status(""), do: {:error, :source_status_required}
  defp source_status(status) when status in @source_statuses, do: {:ok, status}
  defp source_status(_status), do: {:error, :invalid_source_status}

  defp normalize_provenance(nil), do: {:ok, %{}}

  defp normalize_provenance(provenance) when is_map(provenance) do
    allowed =
      provenance
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.take(~w(
        catalog_sync_run_id
        dry_run_hash
        tickera_event_id
        woo_product_id
        woo_variation_id
        resolution_source
      ))

    if Enum.all?(allowed, fn
         {key, value} when key in ~w(tickera_event_id woo_product_id woo_variation_id) ->
           is_integer(value) and value > 0

         {_key, value} ->
           is_binary(value) and value != ""
       end) do
      {:ok, allowed}
    else
      {:error, :invalid_provenance}
    end
  end

  defp normalize_provenance(_provenance), do: {:error, :invalid_provenance}

  defp fetch_source_system(source_system_id) do
    case Ash.get(SourceSystem, source_system_id, domain: Catalog) do
      {:ok, %SourceSystem{kind: :woocommerce, active: true} = source} -> {:ok, source}
      {:ok, %SourceSystem{}} -> {:error, :invalid_source_system}
      {:ok, nil} -> {:error, :source_not_found}
      {:error, _reason} -> {:error, :source_not_found}
    end
  end

  defp fetch_event(event_id, %SourceSystem{id: source_system_id}) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %Event{source_system_id: ^source_system_id} = event} -> {:ok, event}
      {:ok, %Event{}} -> {:error, :event_source_mismatch}
      {:ok, nil} -> {:error, :event_not_found}
      {:error, _reason} -> {:error, :event_not_found}
    end
  end

  defp fetch_ticket_type(ticket_type_id, %Event{id: event_id}) do
    case Ash.get(TicketType, ticket_type_id, domain: Catalog) do
      {:ok, %TicketType{event_id: ^event_id} = ticket_type} -> {:ok, ticket_type}
      {:ok, %TicketType{}} -> {:error, :ticket_type_event_mismatch}
      {:ok, nil} -> {:error, :ticket_type_not_found}
      {:error, _reason} -> {:error, :ticket_type_not_found}
    end
  end

  defp reject_duplicate(%{
         source_system_id: source_system_id,
         woo_product_id: woo_product_id,
         woo_variation_id: nil
       }) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and woo_product_id == ^woo_product_id and
        is_nil(woo_variation_id) and active == true
    )
    |> Ash.read_one(domain: Catalog)
    |> duplicate_result()
  end

  defp reject_duplicate(%{
         source_system_id: source_system_id,
         woo_product_id: woo_product_id,
         woo_variation_id: woo_variation_id
       }) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and woo_product_id == ^woo_product_id and
        woo_variation_id == ^woo_variation_id and active == true
    )
    |> Ash.read_one(domain: Catalog)
    |> duplicate_result()
  end

  defp duplicate_result({:ok, nil}), do: :ok
  defp duplicate_result({:ok, %ProductMapping{}}), do: {:error, :duplicate_mapping}
  defp duplicate_result({:error, _reason}), do: {:error, :duplicate_check_failed}

  defp create_in_transaction(
         %{ticket_type_mode: :existing} = normalized,
         event,
         actor,
         provenance
       ) do
    with {:ok, ticket_type} <- fetch_ticket_type(normalized.ticket_type_id, event),
         {:ok, mapping} <- create_mapping(normalized, ticket_type),
         :ok <- audit_created(normalized, mapping, ticket_type, false, actor, provenance) do
      {:ok, %{mapping: mapping, ticket_type: ticket_type, created_ticket_type?: false}}
    end
  end

  defp create_in_transaction(
         %{ticket_type_mode: :new} = normalized,
         _event,
         actor,
         provenance
       ) do
    with {:ok, ticket_type} <- create_ticket_type(normalized),
         {:ok, mapping} <- create_mapping(normalized, ticket_type),
         :ok <- audit_created(normalized, mapping, ticket_type, true, actor, provenance) do
      {:ok, %{mapping: mapping, ticket_type: ticket_type, created_ticket_type?: true}}
    end
  end

  defp create_ticket_type(normalized) do
    with :ok <- reject_duplicate_ticket_name(normalized) do
      attrs = %{
        event_id: normalized.event_id,
        name: normalized.ticket_type_name,
        active: true,
        external_ticket_type_id: normalized.woo_variation_id || normalized.woo_product_id,
        external_ticket_type_kind: ticket_type_kind(normalized.woo_variation_id),
        external_product_id: normalized.woo_product_id,
        external_variation_id: normalized.woo_variation_id,
        source_status: normalized.source_status,
        last_synced_at: DateTime.utc_now()
      }

      case Ash.create(TicketType, attrs,
             action: :create,
             domain: Catalog,
             context: %{warn_on_transaction_hooks?: false},
             return_notifications?: true
           ) do
        {:ok, %TicketType{} = ticket_type} -> {:ok, ticket_type}
        {:ok, %TicketType{} = ticket_type, _notifications} -> {:ok, ticket_type}
        {:error, _reason} -> {:error, :ticket_type_create_failed}
      end
    end
  end

  defp reject_duplicate_ticket_name(%{event_id: event_id, ticket_type_name: name}) do
    TicketType
    |> Ash.Query.filter(event_id == ^event_id and name == ^name)
    |> Ash.read_one(domain: Catalog)
    |> case do
      {:ok, nil} -> :ok
      {:ok, %TicketType{}} -> {:error, :ticket_type_create_failed}
      {:error, _reason} -> {:error, :ticket_type_create_failed}
    end
  end

  defp create_mapping(normalized, %TicketType{id: ticket_type_id}) do
    attrs = %{
      source_system_id: normalized.source_system_id,
      event_id: normalized.event_id,
      ticket_type_id: ticket_type_id,
      woo_product_id: normalized.woo_product_id,
      woo_variation_id: normalized.woo_variation_id,
      original_label: normalized.label,
      current_label: normalized.label,
      active: true
    }

    case Ash.create(ProductMapping, attrs,
           action: :create,
           domain: Catalog,
           context: %{warn_on_transaction_hooks?: false},
           return_notifications?: true
         ) do
      {:ok, %ProductMapping{} = mapping} -> {:ok, mapping}
      {:ok, %ProductMapping{} = mapping, _notifications} -> {:ok, mapping}
      {:error, reason} -> {:error, mapping_create_error(reason)}
    end
  end

  defp mapping_create_error(reason) do
    if duplicate_mapping_error?(reason), do: :duplicate_mapping, else: :mapping_create_failed
  end

  defp duplicate_mapping_error?(reason) do
    reason
    |> inspect()
    |> String.contains?("catalog_mappings_unique_active_")
  end

  defp ticket_type_kind(nil), do: :woo_product
  defp ticket_type_kind(_variation_id), do: :woo_variation

  defp audit_created(
         normalized,
         %ProductMapping{} = mapping,
         %TicketType{} = ticket_type,
         created?,
         actor,
         provenance
       ) do
    metadata =
      Map.merge(provenance, %{
        source_system_id: normalized.source_system_id,
        event_id: normalized.event_id,
        ticket_type_id: ticket_type.id,
        created_ticket_type: created?,
        woo_product_id: normalized.woo_product_id,
        woo_variation_id: normalized.woo_variation_id,
        label: normalized.label,
        source_status: normalized.source_status,
        reason: normalized.reason
      })

    attrs = %{
      actor_type: :user,
      actor_user_id: actor.id,
      actor_role: :admin,
      source: :admin,
      subject_type: "product_mapping",
      subject_id: mapping.id,
      event_id: normalized.event_id,
      metadata: metadata,
      ash_opts: [return_notifications?: true]
    }

    case audit_logger().manual_mapping_created(attrs) do
      {:ok, _audit_log} -> :ok
      {:error, _reason} -> {:error, :audit_failed}
    end
  end

  defp audit_logger do
    Application.get_env(:event_sales, :manual_mapping_audit_logger, AuditLogger)
  end
end
