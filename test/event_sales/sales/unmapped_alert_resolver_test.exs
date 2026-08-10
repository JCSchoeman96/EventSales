defmodule EventSales.Sales.UnmappedAlertResolverTest do
  use EventSales.DataCase, async: false

  import EventSales.TestSupport.AuthHelpers

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Sales
  alias EventSales.Sales.Resources.OrderItem
  alias EventSales.Sales.UnmappedAlertResolver
  alias EventSales.TestSupport.{FixtureHelpers, SalesHelpers}

  setup do
    original_recovery = Application.get_env(:event_sales, :unmapped_alert_recovery_module)

    on_exit(fn ->
      if original_recovery do
        Application.put_env(:event_sales, :unmapped_alert_recovery_module, original_recovery)
      else
        Application.delete_env(:event_sales, :unmapped_alert_recovery_module)
      end
    end)

    admin = create_user!("unmapped-resolver-admin@example.com")
    staff = create_user!("unmapped-resolver-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event = SalesHelpers.create_event!(source, %{name: "Resolution Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Resolution Ticket"})
    item = create_pending_item!(order, %{woo_product_id: 501, woo_variation_id: 601})

    {:ok,
     admin: admin,
     staff: staff,
     source: source,
     order: order,
     event: event,
     ticket: ticket,
     item: item}
  end

  test "loads only safe durable context for an admin", ctx do
    assert {:ok, alert} = UnmappedAlertResolver.load(ctx.item.id, actor: ctx.admin)
    assert alert.order_item_id == ctx.item.id
    assert alert.source_system_id == ctx.source.id
    assert alert.order_number == ctx.order.order_number
    assert alert.name == ctx.item.name
    assert alert.woo_product_id == 501
    assert alert.woo_variation_id == 601
    assert alert.mapping_status == :pending_mapping_resolution
    refute Map.has_key?(alert, :customer_email)
    refute Map.has_key?(alert, :payload)
  end

  test "rejects unauthorized, missing, and non-pending alerts", ctx do
    assert {:error, :forbidden} = UnmappedAlertResolver.load(ctx.item.id, actor: ctx.staff)
    assert {:error, :forbidden} = UnmappedAlertResolver.load(ctx.item.id, actor: nil)

    assert {:error, :not_found} =
             UnmappedAlertResolver.load(Ecto.UUID.generate(), actor: ctx.admin)

    mapped = Ash.update!(ctx.item, %{}, action: :mark_unmapped, domain: Sales)
    assert {:error, :not_pending} = UnmappedAlertResolver.load(mapped.id, actor: ctx.admin)
  end

  test "creates an existing-ticket mapping from durable identifiers and recovers exact matches",
       ctx do
    ticket =
      SalesHelpers.create_variation_ticket_type!(ctx.event, 501, 601, %{
        name: "Resolution Variation"
      })

    matching =
      create_pending_item!(ctx.order, %{
        woo_line_item_id: 99_001,
        woo_product_id: 501,
        woo_variation_id: 601
      })

    other =
      create_pending_item!(ctx.order, %{
        woo_line_item_id: 99_002,
        woo_product_id: 501,
        woo_variation_id: 602
      })

    params = %{
      "source_system_id" => Ecto.UUID.generate(),
      "event_id" => ctx.event.id,
      "ticket_type_mode" => "existing",
      "ticket_type_id" => ticket.id,
      "woo_product_id" => "999999",
      "woo_variation_id" => "999998",
      "label" => "Forged label",
      "source_status" => "manual",
      "reason" => "Resolve dashboard alert"
    }

    assert {:ok, %{mapping: mapping, recovery: %{mapped: 2}}} =
             UnmappedAlertResolver.resolve(ctx.item.id, params, actor: ctx.admin)

    assert mapping.source_system_id == ctx.source.id
    assert mapping.woo_product_id == 501
    assert mapping.woo_variation_id == 601
    assert mapping.current_label == ctx.item.name
    assert Ash.get!(OrderItem, ctx.item.id, domain: Sales).mapping_status == :mapped
    assert Ash.get!(OrderItem, matching.id, domain: Sales).mapping_status == :mapped

    assert Ash.get!(OrderItem, other.id, domain: Sales).mapping_status ==
             :pending_mapping_resolution
  end

  test "creates a new ticket type and returns duplicate and mismatch errors", ctx do
    params =
      base_params(ctx)
      |> Map.merge(%{"ticket_type_mode" => "new", "ticket_type_name" => "New Tier"})

    assert {:ok, %{created_ticket_type?: true, ticket_type: ticket}} =
             UnmappedAlertResolver.resolve(ctx.item.id, params, actor: ctx.admin)

    assert ticket.name == "New Tier"

    second =
      create_pending_item!(ctx.order, %{
        woo_line_item_id: 99_010,
        woo_product_id: 501,
        woo_variation_id: 601
      })

    assert {:error, :duplicate_mapping} =
             UnmappedAlertResolver.resolve(second.id, base_params(ctx), actor: ctx.admin)

    other_source = SalesHelpers.create_source_system!(%{name: "Other source"})
    other_event = SalesHelpers.create_event!(other_source, %{name: "Other event"})

    assert {:error, :event_source_mismatch} =
             UnmappedAlertResolver.resolve(
               second.id,
               Map.put(base_params(ctx), "event_id", other_event.id),
               actor: ctx.admin
             )
  end

  test "keeps a committed mapping when recovery fails and retries recovery without another mapping",
       ctx do
    ticket =
      SalesHelpers.create_variation_ticket_type!(ctx.event, 501, 601, %{
        name: "Recovery Ticket"
      })

    Application.put_env(
      :event_sales,
      :unmapped_alert_recovery_module,
      EventSales.Sales.UnmappedAlertResolverTest.FailingRecovery
    )

    assert {:error, {:recovery_failed, :recovery_failed}} =
             UnmappedAlertResolver.resolve(
               ctx.item.id,
               Map.put(base_params(ctx), "ticket_type_id", ticket.id),
               actor: ctx.admin
             )

    assert Ash.count!(ProductMapping, domain: Catalog) == 1
    Application.delete_env(:event_sales, :unmapped_alert_recovery_module)

    assert {:ok, %{mapped: 1}} =
             UnmappedAlertResolver.retry_recovery(ctx.item.id, actor: ctx.admin)

    assert Ash.count!(ProductMapping, domain: Catalog) == 1
  end

  defmodule FailingRecovery do
    def recover_product(_source_id, _product_id, _variation_id, _opts),
      do: {:error, "sensitive failure"}
  end

  defp base_params(ctx) do
    %{
      "event_id" => ctx.event.id,
      "ticket_type_mode" => "existing",
      "ticket_type_id" => ctx.ticket.id,
      "ticket_type_name" => "",
      "source_status" => "manual",
      "reason" => "Resolve dashboard alert"
    }
  end

  defp create_pending_item!(order, attrs) do
    line =
      :woocommerce
      |> FixtureHelpers.decode_json_fixture!(:order_completed)
      |> Map.fetch!("line_items")
      |> hd()

    defaults = %{
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: line["product_id"],
      woo_variation_id: line["variation_id"],
      name: line["name"],
      quantity: line["quantity"],
      line_subtotal: Decimal.new(line["subtotal"]),
      line_total: Decimal.new(line["total"]),
      discount_total: Decimal.new("0"),
      item_kind: :unknown,
      mapping_status: :pending_mapping_resolution
    }

    SalesHelpers.create_order_item_from_line!(order, line, Map.merge(defaults, attrs))
  end
end
