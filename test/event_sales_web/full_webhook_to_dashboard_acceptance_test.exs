defmodule EventSalesWeb.FullWebhookToDashboardAcceptanceTest do
  use EventSalesWeb.ConnCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Ecto.Query
  import EventSales.DataCase, only: [setup_sandbox: 1]
  import EventSales.TestSupport.AuthHelpers
  import Phoenix.LiveViewTest

  require Ash.Query

  alias EventSales.Analytics.{AdminDashboard, HotStateAggregator}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.Workers.ProcessWebhookWorker
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.Ingestion.StubWebhookEventStore
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.WooCommerceWebhookHelpers

  @path_token "test-token"
  @webhook_secret "slice_1_5_webhook_secret"
  @event_name "Slice 23 Acceptance Event"
  @ticket_name "General Admission"
  @woo_order_id 10_001
  @woo_line_item_id 70_001
  @woo_product_id 501
  @woo_variation_id 601

  setup tags do
    setup_sandbox(tags)
    HotStateAggregator.reset_for_test!()
    StubWebhookEventStore.clear!()
    delete_process_webhook_jobs!()

    on_exit(fn ->
      HotStateAggregator.reset_for_test!()
      StubWebhookEventStore.clear!()
      delete_process_webhook_jobs!()
    end)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: @event_name,
        slug: "slice-23-acceptance-#{System.unique_integer([:positive])}"
      })

    ticket = SalesHelpers.create_ticket_type!(event, %{name: @ticket_name})

    create_product_mapping!(source, event, ticket)

    {:ok, source: source, event: event, ticket: ticket}
  end

  test "completed webhook reaches normalized order, aggregate, and dashboard", %{
    conn: conn,
    source: source,
    event: event,
    ticket: ticket
  } do
    raw_body = completed_raw_body()
    assert_fixture_contract!(Jason.decode!(raw_body))

    conn = post_signed_webhook(conn, raw_body, delivery_id: "slice-23-completed")

    assert response(conn, 200) == "ok"

    assert [queued_event] = webhook_events()
    assert queued_event.status == :queued
    assert queued_event.topic == "order.updated"
    assert queued_event.resource_type == "order"
    assert queued_event.resource_id == Integer.to_string(@woo_order_id)

    assert_webhook_drain_success!()

    assert %{status: :processed} = reload_webhook_event!(queued_event.id)

    order = order_for_source!(source)
    assert order.status == :completed

    item = order_item_for_order!(order)
    assert item.woo_line_item_id == @woo_line_item_id
    assert item.event_id == event.id
    assert item.ticket_type_id == ticket.id
    assert item.mapping_status == :mapped
    assert item.item_kind == :ticket
    assert item.quantity == 2
    assert Decimal.equal?(item.line_total, Decimal.new("900.00"))

    assert_dashboard_totals!(event, 2, "900.00")
    assert_admin_dashboard_renders!(conn, event, "2", "900.00")
  end

  test "duplicate webhook delivery and duplicate processed resource do not double count", %{
    conn: conn,
    event: event
  } do
    raw_body = completed_raw_body()

    conn = post_signed_webhook(conn, raw_body, delivery_id: "slice-23-duplicate-delivery")
    assert response(conn, 200) == "ok"
    assert_webhook_drain_success!()
    assert_dashboard_totals!(event, 2, "900.00")

    duplicate_delivery =
      post_signed_webhook(build_conn(), raw_body, delivery_id: "slice-23-duplicate-delivery")

    assert response(duplicate_delivery, 200) == "ok"
    assert length(webhook_events()) == 1
    assert_dashboard_totals!(event, 2, "900.00")

    duplicate_resource =
      post_signed_webhook(build_conn(), raw_body, delivery_id: "slice-23-duplicate-resource")

    assert response(duplicate_resource, 200) == "ok"
    assert_webhook_drain_success!()

    assert ignored =
             Enum.find(webhook_events(), fn webhook ->
               webhook.delivery_id == "slice-23-duplicate-resource"
             end)

    assert ignored.status == :ignored
    assert ignored.ignore_reason == :duplicate_resource_hash
    assert_dashboard_totals!(event, 2, "900.00")
  end

  test "pending same order is normalized and mapped but excluded from sold metrics", %{
    conn: conn,
    source: source,
    event: event,
    ticket: ticket
  } do
    raw_body =
      completed_payload()
      |> pending_payload("2026-05-01T08:01:00")
      |> Jason.encode!()

    conn = post_signed_webhook(conn, raw_body, delivery_id: "slice-23-pending")
    assert response(conn, 200) == "ok"
    assert_webhook_drain_success!()

    order = order_for_source!(source)
    assert order.status == :pending

    item = order_item_for_order!(order)
    assert item.event_id == event.id
    assert item.ticket_type_id == ticket.id
    assert item.mapping_status == :mapped

    assert_dashboard_totals!(event, 0, "0")
    assert_admin_dashboard_renders_event!(conn, event)
  end

  test "pending order followed by completed update increments dashboard exactly once", %{
    conn: conn,
    source: source,
    event: event
  } do
    pending_raw_body =
      completed_payload()
      |> pending_payload("2026-05-01T08:01:00")
      |> Jason.encode!()

    conn = post_signed_webhook(conn, pending_raw_body, delivery_id: "slice-23-update-pending")
    assert response(conn, 200) == "ok"
    assert_webhook_drain_success!()
    assert_dashboard_totals!(event, 0, "0")

    completed_raw_body =
      completed_payload()
      |> Map.put("date_modified_gmt", "2026-05-01T08:05:00")
      |> Map.put("date_completed_gmt", "2026-05-01T08:05:00")
      |> Jason.encode!()

    completed =
      post_signed_webhook(build_conn(), completed_raw_body,
        delivery_id: "slice-23-update-completed"
      )

    assert response(completed, 200) == "ok"
    assert_webhook_drain_success!()

    assert %{status: :completed} = order_for_source!(source)
    assert Ash.count!(OrderItem, domain: Sales) == 1
    assert_dashboard_totals!(event, 2, "900.00")

    duplicate_completed =
      post_signed_webhook(build_conn(), completed_raw_body,
        delivery_id: "slice-23-update-completed-duplicate"
      )

    assert response(duplicate_completed, 200) == "ok"
    assert_webhook_drain_success!()
    assert_dashboard_totals!(event, 2, "900.00")
  end

  defp completed_payload do
    FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)
  end

  defp completed_raw_body do
    FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
  end

  defp pending_payload(payload, source_updated_at) do
    payload
    |> Map.put("status", "pending")
    |> Map.put("date_modified_gmt", source_updated_at)
    |> Map.put("date_completed_gmt", nil)
  end

  defp assert_fixture_contract!(payload) do
    assert payload["id"] == @woo_order_id
    assert [line_item] = payload["line_items"]
    assert line_item["id"] == @woo_line_item_id
    assert line_item["product_id"] == @woo_product_id
    assert line_item["variation_id"] == @woo_variation_id
    assert line_item["quantity"] == 2
    assert line_item["total"] == "900.00"
  end

  defp create_product_mapping!(source, event, ticket) do
    Ash.create!(
      ProductMapping,
      %{
        source_system_id: source.id,
        event_id: event.id,
        ticket_type_id: ticket.id,
        woo_product_id: @woo_product_id,
        woo_variation_id: @woo_variation_id,
        original_label: @ticket_name,
        current_label: @ticket_name,
        active: true
      },
      action: :create,
      domain: Catalog
    )
  end

  defp post_signed_webhook(conn, raw_body, opts) do
    headers =
      WooCommerceWebhookHelpers.signed_headers(raw_body,
        secret: @webhook_secret,
        delivery_id: Keyword.fetch!(opts, :delivery_id)
      )

    conn
    |> put_req_headers(headers)
    |> put_req_header("content-type", "application/json")
    |> post(~p"/webhooks/woocommerce/#{@path_token}", raw_body)
  end

  defp put_req_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      put_req_header(acc, name, value)
    end)
  end

  defp assert_webhook_drain_success! do
    result = Oban.drain_queue(queue: :webhooks, with_recursion: true, with_scheduled: true)
    assert %{failure: 0, snoozed: 0} = result
    assert result.success + result.discard > 0
    result
  end

  defp webhook_events do
    WebhookEvent
    |> Ash.Query.sort(received_at: :asc)
    |> Ash.read!(domain: Ingestion)
  end

  defp reload_webhook_event!(id), do: Ash.get!(WebhookEvent, id, domain: Ingestion)

  defp order_for_source!(source) do
    Order
    |> Ash.Query.filter(source_system_id == ^source.id and woo_order_id == ^@woo_order_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(domain: Sales)
  end

  defp order_item_for_order!(order) do
    OrderItem
    |> Ash.Query.filter(order_id == ^order.id and woo_line_item_id == ^@woo_line_item_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(domain: Sales)
  end

  defp assert_dashboard_totals!(event, expected_sold, expected_revenue) do
    assert {:ok, snapshot} = AdminDashboard.snapshot()
    row = Enum.find(snapshot.events, &(&1.event_id == event.id))

    assert row.event_name == event.name
    assert row.total_sold == expected_sold
    assert Decimal.equal?(row.total_revenue, Decimal.new(expected_revenue))

    assert {:ok, hot_summary} = HotStateAggregator.summary_for_event(event.id)
    assert hot_summary.total_sold == expected_sold
    assert Decimal.equal?(hot_summary.total_revenue, Decimal.new(expected_revenue))
  end

  defp assert_admin_dashboard_renders!(conn, event, expected_sold, expected_revenue) do
    admin = create_user!("slice-23-admin-#{System.unique_integer([:positive])}@example.test")
    create_global_role!(admin, :admin)

    {:ok, _view, html} =
      conn
      |> recycle()
      |> sign_in_as(admin)
      |> live("/admin/dashboard")

    assert html =~ event.name
    assert html =~ expected_sold
    assert html =~ expected_revenue
  end

  defp assert_admin_dashboard_renders_event!(conn, event) do
    admin =
      create_user!("slice-23-pending-admin-#{System.unique_integer([:positive])}@example.test")

    create_global_role!(admin, :admin)

    {:ok, _view, html} =
      conn
      |> recycle()
      |> sign_in_as(admin)
      |> live("/admin/dashboard")

    assert html =~ event.name
  end

  defp delete_process_webhook_jobs! do
    worker = Oban.Worker.to_string(ProcessWebhookWorker)

    Oban.Job
    |> where([job], job.worker == ^worker)
    |> Repo.delete_all()
  end
end
