defmodule EventSales.Catalog.ManualMappingCreatorTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Catalog
  alias EventSales.Catalog.ManualMappingCreator
  alias EventSales.Catalog.Resources.{ProductMapping, TicketType}
  alias EventSales.Catalog.Workers.MappingChangedWorker
  alias EventSales.TestSupport.SalesHelpers

  setup do
    original_logger = Application.get_env(:event_sales, :manual_mapping_audit_logger)

    on_exit(fn ->
      restore_env(:manual_mapping_audit_logger, original_logger)
    end)

    admin = create_user!("manual-mapping-admin@example.com")
    staff = create_user!("manual-mapping-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Manual Mapping Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    {:ok, admin: admin, staff: staff, source: source, event: event, ticket: ticket}
  end

  test "admin creates mapping with an existing ticket type", %{
    admin: admin,
    source: source,
    event: event,
    ticket: ticket
  } do
    assert {:ok, %{mapping: mapping, ticket_type: returned_ticket, created_ticket_type?: false}} =
             ManualMappingCreator.create(existing_ticket_params(source, event, ticket),
               actor: admin
             )

    assert returned_ticket.id == ticket.id
    assert mapping.source_system_id == source.id
    assert mapping.event_id == event.id
    assert mapping.ticket_type_id == ticket.id
    assert mapping.woo_product_id == 104_324
    assert mapping.woo_variation_id == nil
    assert mapping.original_label == "VIP Comp"
    assert mapping.current_label == "VIP Comp"

    assert_enqueued(worker: MappingChangedWorker, args: %{"event_id" => event.id})
    assert [audit] = audit_logs(:manual_mapping_created)
    assert audit.subject_type == "product_mapping"
    assert audit.subject_id == mapping.id
    assert audit.event_id == event.id
    assert audit.metadata["reason"] == "Private VIP exception"
    assert audit.metadata["created_ticket_type"] == false
  end

  test "admin creates new ticket type and mapping in one transaction", %{
    admin: admin,
    source: source,
    event: event
  } do
    assert {:ok, %{mapping: mapping, ticket_type: ticket, created_ticket_type?: true}} =
             ManualMappingCreator.create(
               %{
                 "source_system_id" => source.id,
                 "event_id" => event.id,
                 "ticket_type_mode" => "new",
                 "ticket_type_name" => "Pre-sale",
                 "woo_product_id" => " 104325 ",
                 "woo_variation_id" => "501",
                 "label" => " Pre-sale Batch A ",
                 "source_status" => " pre_sale ",
                 "reason" => " Pre-sale launch "
               },
               actor: admin
             )

    assert ticket.name == "Pre-sale"
    assert ticket.event_id == event.id
    assert ticket.external_ticket_type_id == 501
    assert ticket.external_ticket_type_kind == :woo_variation
    assert ticket.external_product_id == 104_325
    assert ticket.external_variation_id == 501
    assert ticket.source_status == "pre_sale"
    assert %DateTime{} = ticket.last_synced_at

    assert mapping.ticket_type_id == ticket.id
    assert mapping.woo_product_id == 104_325
    assert mapping.woo_variation_id == 501
    assert mapping.current_label == "Pre-sale Batch A"

    assert [audit] = audit_logs(:manual_mapping_created)
    assert audit.metadata["created_ticket_type"] == true
    assert audit.metadata["source_status"] == "pre_sale"
  end

  test "optional review provenance is allowlisted and existing callers remain unchanged", %{
    admin: admin,
    source: source,
    event: event
  } do
    ticket =
      SalesHelpers.create_ticket_type!(event, %{
        name: "Variation GA",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 501,
        external_product_id: 104_324,
        external_variation_id: 501
      })

    params =
      source
      |> existing_ticket_params(event, ticket)
      |> Map.put("woo_variation_id", "501")

    assert {:ok, _result} =
             ManualMappingCreator.create(params,
               actor: admin,
               provenance: %{
                 catalog_sync_run_id: Ecto.UUID.generate(),
                 dry_run_hash: String.duplicate("a", 64),
                 tickera_event_id: 109_120,
                 woo_product_id: 104_324,
                 woo_variation_id: 501,
                 resolution_source: "variation_mapping_review",
                 payload: %{"secret" => true},
                 secret: "hidden"
               }
             )

    assert [audit] = audit_logs(:manual_mapping_created)
    assert audit.metadata["resolution_source"] == "variation_mapping_review"
    assert audit.metadata["tickera_event_id"] == 109_120
    refute Map.has_key?(audit.metadata, "payload")
    refute Map.has_key?(audit.metadata, "secret")
  end

  test "rejects non-admin and nil actors", %{
    staff: staff,
    source: source,
    event: event,
    ticket: ticket
  } do
    params = existing_ticket_params(source, event, ticket)

    assert {:error, :forbidden} = ManualMappingCreator.create(params, actor: staff)
    assert {:error, :forbidden} = ManualMappingCreator.create(params, actor: nil)
    assert mapping_count() == 0
  end

  test "rejects duplicate active product-level mapping", %{
    admin: admin,
    source: source,
    event: event,
    ticket: ticket
  } do
    create_mapping!(source, event, ticket, %{woo_product_id: 104_324, woo_variation_id: nil})

    assert {:error, :duplicate_mapping} =
             ManualMappingCreator.create(existing_ticket_params(source, event, ticket),
               actor: admin
             )
  end

  test "rejects duplicate active variation mapping", %{
    admin: admin,
    source: source,
    event: event
  } do
    ticket =
      SalesHelpers.create_ticket_type!(event, %{
        name: "Duplicate Variation",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 9,
        external_product_id: 104_324,
        external_variation_id: 9
      })

    create_mapping!(source, event, ticket, %{woo_product_id: 104_324, woo_variation_id: 9})

    params =
      source
      |> existing_ticket_params(event, ticket)
      |> Map.put("woo_variation_id", "9")

    assert {:error, :duplicate_mapping} = ManualMappingCreator.create(params, actor: admin)
  end

  test "inactive mapping does not block create", %{
    admin: admin,
    source: source,
    event: event,
    ticket: ticket
  } do
    mapping = create_mapping!(source, event, ticket, %{woo_product_id: 104_324, active: true})
    Ash.update!(mapping, %{}, action: :deactivate, domain: Catalog)

    assert {:ok, %{mapping: new_mapping}} =
             ManualMappingCreator.create(existing_ticket_params(source, event, ticket),
               actor: admin
             )

    assert new_mapping.active
    assert new_mapping.id != mapping.id
  end

  test "rejects mismatched ticket type and event", %{admin: admin, source: source, event: event} do
    other_event = SalesHelpers.create_event!(source, %{name: "Other Event"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other"})

    assert {:error, :ticket_type_event_mismatch} =
             ManualMappingCreator.create(existing_ticket_params(source, event, other_ticket),
               actor: admin
             )
  end

  test "rejects event/source mismatch", %{
    admin: admin,
    source: source,
    event: event,
    ticket: ticket
  } do
    other_source = SalesHelpers.create_source_system!()

    params =
      source
      |> existing_ticket_params(event, ticket)
      |> Map.put("source_system_id", other_source.id)

    assert {:error, :event_source_mismatch} = ManualMappingCreator.create(params, actor: admin)
  end

  test "rejects invalid IDs and required strings", %{
    admin: admin,
    source: source,
    event: event,
    ticket: ticket
  } do
    base = existing_ticket_params(source, event, ticket)

    for {field, value, reason} <- [
          {"woo_product_id", "0", :invalid_woo_product_id},
          {"woo_product_id", "abc", :invalid_woo_product_id},
          {"woo_variation_id", "0", :invalid_woo_variation_id},
          {"woo_variation_id", "-1", :invalid_woo_variation_id},
          {"label", " ", :label_required},
          {"reason", " ", :reason_required},
          {"source_status", "", :source_status_required},
          {"source_status", "subscription", :invalid_source_status}
        ] do
      assert {:error, ^reason} =
               base
               |> Map.put(field, value)
               |> ManualMappingCreator.create(actor: admin)
    end
  end

  test "audit failure rolls back ticket type and mapping creation", %{
    admin: admin,
    source: source,
    event: event
  } do
    Application.put_env(
      :event_sales,
      :manual_mapping_audit_logger,
      __MODULE__.FailingManualMappingAuditLogger
    )

    before_tickets = ticket_count()

    assert {:error, :audit_failed} =
             ManualMappingCreator.create(
               %{
                 "source_system_id" => source.id,
                 "event_id" => event.id,
                 "ticket_type_mode" => "new",
                 "ticket_type_name" => "Rollback Ticket",
                 "woo_product_id" => "104326",
                 "woo_variation_id" => "",
                 "label" => "Rollback",
                 "source_status" => "manual",
                 "reason" => "Audit failure test"
               },
               actor: admin
             )

    assert mapping_count() == 0
    assert ticket_count() == before_tickets
  end

  test "duplicate new ticket type name rolls back mapping creation", %{
    admin: admin,
    source: source,
    event: event
  } do
    SalesHelpers.create_ticket_type!(event, %{name: "Duplicate"})

    assert {:error, :ticket_type_create_failed} =
             ManualMappingCreator.create(
               %{
                 "source_system_id" => source.id,
                 "event_id" => event.id,
                 "ticket_type_mode" => "new",
                 "ticket_type_name" => "Duplicate",
                 "woo_product_id" => "104327",
                 "woo_variation_id" => "",
                 "label" => "Duplicate",
                 "source_status" => "manual",
                 "reason" => "Duplicate name"
               },
               actor: admin
             )

    assert mapping_count() == 0
  end

  defmodule FailingManualMappingAuditLogger do
    def manual_mapping_created(_attrs), do: {:error, :forced_failure}
  end

  defp existing_ticket_params(source, event, ticket) do
    %{
      "source_system_id" => source.id,
      "event_id" => event.id,
      "ticket_type_mode" => "existing",
      "ticket_type_id" => ticket.id,
      "ticket_type_name" => "",
      "woo_product_id" => "104324",
      "woo_variation_id" => "",
      "label" => "VIP Comp",
      "source_status" => "private",
      "reason" => "Private VIP exception"
    }
  end

  defp create_mapping!(source, event, ticket, attrs) do
    defaults = %{
      source_system_id: source.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_product_id: 1,
      woo_variation_id: nil,
      original_label: "Ticket",
      current_label: "Ticket",
      active: true
    }

    Ash.create!(ProductMapping, Map.merge(defaults, Map.new(attrs)),
      action: :create,
      domain: Catalog
    )
  end

  defp create_user!(email, password \\ "valid-pass-123") do
    Ash.create!(
      User,
      %{email: email, name: "Test User", password: password, password_confirmation: password},
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    role =
      Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end

  defp audit_logs(event_type) do
    AuditLog
    |> Ash.Query.filter(event_type == ^event_type)
    |> Ash.read!(domain: Audit)
  end

  defp mapping_count, do: Ash.count!(ProductMapping, domain: Catalog)
  defp ticket_count, do: Ash.count!(TicketType, domain: Catalog)

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
