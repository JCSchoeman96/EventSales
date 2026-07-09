defmodule EventSales.Sales.OrderAttributionCorrectionTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.OrderAttributionCorrection
  alias EventSales.Sales.Resources.Order
  alias EventSales.TestSupport.SalesHelpers

  setup do
    admin = create_user!("order-correction-admin@example.com")
    staff = create_user!("order-correction-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()
    ctx = correction_context!(source)

    {:ok, Map.merge(ctx, %{admin: admin, staff: staff, source: source})}
  end

  test "preview requires global admin", %{staff: staff, source: source} do
    assert {:error, :forbidden} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: staff)
  end

  test "missing order returns order_not_found", %{admin: admin} do
    source = SalesHelpers.create_source_system!()

    assert {:error, :order_not_found} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: admin)
  end

  test "successful correction changes exactly one order item and writes audit", %{
    admin: admin,
    source: source,
    order: order,
    order_item: order_item,
    mp_event: mp_event,
    mp_ticket: mp_ticket,
    wr_event: wr_event,
    wr_ticket: wr_ticket,
    wr_mapping: wr_mapping
  } do
    assert {:ok, preview} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: admin)

    assert preview.woo_order_id == 113_834
    assert preview.woo_product_id == 109_132
    assert preview.woo_variation_id == 109_167
    assert preview.quantity == 5
    assert preview.current_event_external_id == 108_658
    assert preview.target_event_external_id == 109_120
    assert preview.current_ticket_type_name == mp_ticket.name
    assert preview.target_ticket_type_name == wr_ticket.name
    assert preview.order_item_id == order_item.id

    assert {:error, :confirmation_required} =
             OrderAttributionCorrection.correct_confirmed_order_113834(
               source.id,
               "wrong",
               actor: admin
             )

    assert {:ok, result} =
             OrderAttributionCorrection.correct_confirmed_order_113834(
               source.id,
               "CORRECT ORDER 113834 109132/109167 FROM 108658 TO 109120",
               actor: admin
             )

    assert result.order_item.id == order_item.id
    assert result.order_item.event_id == wr_event.id
    assert result.order_item.ticket_type_id == wr_ticket.id
    assert result.order_item.source_tickera_event_id == 109_120
    assert result.order_item.attribution_status_reason == nil
    assert result.order_item.mapping_status == :mapped
    assert result.order_item.item_kind == :ticket
    assert result.order_item.quantity == 5

    reloaded_order = Ash.get!(Order, order.id, domain: Sales)
    assert reloaded_order.woo_order_id == 113_834

    assert_event_unchanged(mp_event)
    assert_ticket_type_unchanged(mp_ticket)
    assert_event_unchanged(wr_event)
    assert_ticket_type_unchanged(wr_ticket)
    assert Ash.get!(ProductMapping, wr_mapping.id, domain: Catalog).active

    assert [audit] =
             AuditLog
             |> Ash.Query.filter(event_type == :order_attribution_corrected)
             |> Ash.read!(domain: Audit)

    assert audit.subject_type == "order_item"
    assert audit.subject_id == order_item.id
    assert audit.metadata["woo_order_id"] == 113_834
    assert audit.metadata["woo_product_id"] == 109_132
    assert audit.metadata["woo_variation_id"] == 109_167
    assert audit.metadata["quantity"] == 5
    assert audit.metadata["from_event_external_id"] == 108_658
    assert audit.metadata["to_event_external_id"] == 109_120
    refute Map.has_key?(audit.metadata, "confirmation")
  end

  test "blocks when current event no longer matches confirmed tuple", %{
    admin: admin,
    source: source,
    order_item: order_item,
    wr_event: wr_event,
    wr_ticket: wr_ticket
  } do
    Ash.update!(
      order_item,
      %{event_id: wr_event.id, ticket_type_id: wr_ticket.id, source_tickera_event_id: 109_120},
      action: :correct_event_attribution,
      domain: Sales,
      actor: admin
    )

    assert {:error, :current_event_mismatch} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: admin)
  end

  test "blocks when target mapping is missing", %{
    admin: admin,
    source: source,
    wr_mapping: wr_mapping
  } do
    Ash.update!(wr_mapping, %{}, action: :deactivate, domain: Catalog, actor: admin)

    assert {:error, :target_mapping_missing} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: admin)
  end

  test "blocks multiple matching order items", %{
    admin: admin,
    source: source,
    order: order,
    mp_event: mp_event,
    mp_ticket: mp_ticket
  } do
    create_confirmed_order_item!(order, mp_event, mp_ticket)

    assert {:error, :multiple_order_items_found} =
             OrderAttributionCorrection.preview_confirmed_order_113834(source.id, actor: admin)
  end

  defp correction_context!(source) do
    mp_event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - MP",
        external_event_id: 108_658,
        external_event_kind: :tickera_event
      })

    mp_ticket = SalesHelpers.create_ticket_type!(mp_event, %{name: "MP General"})

    wr_event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - WR",
        external_event_id: 109_120,
        external_event_kind: :tickera_event
      })

    wr_ticket =
      SalesHelpers.create_ticket_type!(wr_event, %{
        name: "WR General",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 109_167,
        external_product_id: 109_132,
        external_variation_id: 109_167
      })

    wr_mapping =
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: wr_event.id,
          ticket_type_id: wr_ticket.id,
          woo_product_id: 109_132,
          woo_variation_id: 109_167,
          original_label: "WR General",
          current_label: "WR General",
          active: true
        },
        action: :create,
        domain: Catalog
      )

    order =
      :order_completed
      |> SalesHelpers.normalized_order_attrs_from_fixture!(source)
      |> Map.merge(%{woo_order_id: 113_834, order_number: "113834"})
      |> then(&Ash.create!(Order, &1, action: :create_normalized, domain: Sales))

    order_item = create_confirmed_order_item!(order, mp_event, mp_ticket)

    %{
      order: order,
      order_item: order_item,
      mp_event: mp_event,
      mp_ticket: mp_ticket,
      wr_event: wr_event,
      wr_ticket: wr_ticket,
      wr_mapping: wr_mapping
    }
  end

  defp create_confirmed_order_item!(order, event, ticket) do
    line = %{
      "id" => System.unique_integer([:positive]),
      "product_id" => 109_132,
      "variation_id" => 109_167,
      "name" => "WR General",
      "quantity" => 5,
      "subtotal" => "500.00",
      "total" => "500.00",
      "discount_total" => "0.00"
    }

    SalesHelpers.create_order_item_from_line!(order, line, %{
      event_id: event.id,
      ticket_type_id: ticket.id,
      mapping_status: :mapped,
      item_kind: :ticket
    })
  end

  defp assert_event_unchanged(event) do
    reloaded = Ash.get!(Event, event.id, domain: Catalog)
    assert reloaded.name == event.name
    assert reloaded.external_event_id == event.external_event_id
    assert reloaded.external_event_kind == event.external_event_kind
    assert reloaded.updated_at == event.updated_at
  end

  defp assert_ticket_type_unchanged(ticket) do
    reloaded = Ash.get!(TicketType, ticket.id, domain: Catalog)
    assert reloaded.name == ticket.name
    assert reloaded.event_id == ticket.event_id
    assert reloaded.external_ticket_type_id == ticket.external_ticket_type_id
    assert reloaded.external_ticket_type_kind == ticket.external_ticket_type_kind
    assert reloaded.updated_at == ticket.updated_at
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
end
