defmodule EventSalesWeb.Live.Admin.UnmappedAlertResolveLiveTest do
  use EventSalesWeb.ConnCase, async: false

  import EventSales.TestSupport.AuthHelpers
  import Phoenix.LiveViewTest

  alias EventSales.Sales
  alias EventSales.Sales.Resources.OrderItem
  alias EventSales.TestSupport.{FixtureHelpers, SalesHelpers}

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})
    original_recovery = Application.get_env(:event_sales, :unmapped_alert_recovery_module)

    on_exit(fn ->
      if original_recovery do
        Application.put_env(:event_sales, :unmapped_alert_recovery_module, original_recovery)
      else
        Application.delete_env(:event_sales, :unmapped_alert_recovery_module)
      end
    end)

    admin = create_user!("unmapped-live-admin@example.com")
    staff = create_user!("unmapped-live-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)
    source = SalesHelpers.create_source_system!(%{name: "Woo Store"})
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event = SalesHelpers.create_event!(source, %{name: "Resolve Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    item =
      create_pending_item!(order, %{
        woo_product_id: 701,
        woo_variation_id: 702,
        name: "Safe Ticket"
      })

    {:ok,
     admin: admin,
     staff: staff,
     source: source,
     order: order,
     event: event,
     ticket: ticket,
     item: item}
  end

  test "protects the resolve route", %{conn: conn, staff: staff, item: item} do
    path = "/admin/unmapped-alerts/#{item.id}/resolve"
    assert conn |> get(path) |> html_response(401) =~ "Admin access required"
    assert conn |> sign_in_as(staff) |> get(path) |> html_response(403) =~ "Admin role required"
  end

  test "renders safe immutable context and filtered catalog choices", ctx do
    other_source = SalesHelpers.create_source_system!(%{name: "Hidden Store"})
    other_event = SalesHelpers.create_event!(other_source, %{name: "Hidden Event"})
    SalesHelpers.create_ticket_type!(other_event, %{name: "Hidden Ticket"})

    {:ok, view, html} = ctx.conn |> sign_in_as(ctx.admin) |> live(path(ctx.item))

    assert html =~ "Resolve Unmapped Alert"
    assert html =~ ctx.order.order_number
    assert html =~ "Safe Ticket"
    assert html =~ "701"
    assert html =~ "702"
    assert html =~ "pending_mapping_resolution"
    assert html =~ "Woo Store"
    assert html =~ "Resolve Event"
    refute html =~ "Hidden Event"
    refute html =~ "Hidden Ticket"
    refute html =~ "customer_email"
    refute html =~ "payment_gateway_transaction_id"
    refute html =~ "raw_payload"
    assert html =~ ~s(href="/admin/dashboard")
    assert html =~ ~s(href="/admin/mappings")

    changed =
      render_change(view, "update_form", %{
        "manual_mapping" => Map.put(base_form(ctx), "event_id", ctx.event.id)
      })

    assert changed =~ "GA"
    refute changed =~ "Hidden Ticket"
  end

  test "creates an existing-ticket mapping and shows recovery counts", ctx do
    ticket =
      SalesHelpers.create_variation_ticket_type!(ctx.event, 701, 702, %{name: "Variation GA"})

    {:ok, view, _html} = ctx.conn |> sign_in_as(ctx.admin) |> live(path(ctx.item))

    html =
      render_submit(view, "resolve", %{
        "manual_mapping" => %{
          "event_id" => ctx.event.id,
          "ticket_type_mode" => "existing",
          "ticket_type_id" => ticket.id,
          "ticket_type_name" => "",
          "source_status" => "manual",
          "reason" => "Resolve live alert"
        }
      })

    assert html =~ "Unmapped alert resolved"
    assert html =~ "Mapped"
    assert html =~ "1"
    assert Ash.get!(OrderItem, ctx.item.id, domain: Sales).mapping_status == :mapped
  end

  test "creates a new ticket and shows bounded duplicate and stale errors", ctx do
    {:ok, view, _html} = ctx.conn |> sign_in_as(ctx.admin) |> live(path(ctx.item))

    html =
      render_submit(view, "resolve", %{
        "manual_mapping" => %{
          "event_id" => ctx.event.id,
          "ticket_type_mode" => "new",
          "ticket_type_id" => "",
          "ticket_type_name" => "Balcony",
          "source_status" => "manual",
          "reason" => "Create reviewed tier"
        }
      })

    assert html =~ "Unmapped alert resolved"

    duplicate =
      create_pending_item!(ctx.order, %{
        woo_line_item_id: 99_100,
        woo_product_id: 701,
        woo_variation_id: 702
      })

    {:ok, duplicate_view, _html} = ctx.conn |> sign_in_as(ctx.admin) |> live(path(duplicate))

    assert render_submit(duplicate_view, "resolve", %{"manual_mapping" => base_form(ctx)}) =~
             "active mapping already exists"

    stale = create_pending_item!(ctx.order, %{woo_line_item_id: 99_101, woo_product_id: 801})
    Ash.update!(stale, %{}, action: :mark_unmapped, domain: Sales)
    {:ok, _stale_view, stale_html} = ctx.conn |> sign_in_as(ctx.admin) |> live(path(stale))
    assert stale_html =~ "no longer pending"
  end

  test "keeps direct writes and external clients out of the LiveView" do
    source = File.read!("lib/event_sales_web/live/admin/unmapped_alert_resolve_live.ex")
    refute source =~ "Repo.insert"
    refute source =~ "Repo.update"
    refute source =~ "Repo.delete"
    refute source =~ "WooCommerceClient"
    refute source =~ "WordPressFeedClient"
    refute source =~ "/internal/mappings"
  end

  test "offers retry after recovery fails without creating a second mapping", ctx do
    ticket =
      SalesHelpers.create_variation_ticket_type!(ctx.event, 701, 702, %{name: "Retry Variation"})

    Application.put_env(
      :event_sales,
      :unmapped_alert_recovery_module,
      EventSalesWeb.Live.Admin.UnmappedAlertResolveLiveTest.FailingRecovery
    )

    {:ok, view, _html} = ctx.conn |> sign_in_as(ctx.admin) |> live(path(ctx.item))

    html =
      render_submit(view, "resolve", %{
        "manual_mapping" => Map.put(base_form(ctx), "ticket_type_id", ticket.id)
      })

    assert html =~ "mapping was saved"
    assert html =~ "Retry recovery"
    Application.delete_env(:event_sales, :unmapped_alert_recovery_module)

    retried = render_click(view, "retry_recovery")
    assert retried =~ "Mapping recovery completed"
    assert retried =~ "Mapped"
  end

  defmodule FailingRecovery do
    def recover_product(_source_id, _product_id, _variation_id, _opts),
      do: {:error, "sensitive recovery failure"}
  end

  defp path(item), do: "/admin/unmapped-alerts/#{item.id}/resolve"

  defp base_form(ctx) do
    %{
      "event_id" => ctx.event.id,
      "ticket_type_mode" => "existing",
      "ticket_type_id" => ctx.ticket.id,
      "ticket_type_name" => "",
      "source_status" => "manual",
      "reason" => "Resolve duplicate"
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
