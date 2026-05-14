defmodule EventSales.E2e.WebhookToDashboardTest do
  use ExUnit.Case, async: true

  @moduledoc false

  @moduletag :pending

  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.MappingSetupHelpers
  alias EventSales.TestSupport.ObanHelpers
  alias EventSales.TestSupport.WooCommerceWebhookHelpers

  @webhook_secret "slice_1_5_webhook_secret"

  test "valid completed webhook reaches dashboard totals" do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    payload = Jason.decode!(raw_body)
    headers = WooCommerceWebhookHelpers.signed_headers(raw_body, secret: @webhook_secret)
    mapping_context = MappingSetupHelpers.completed_order_mapping_context()

    assert payload["status"] == "completed"
    assert payload["line_items"] |> hd() |> Map.fetch!("product_id") == 501

    assert {"x-wc-webhook-signature", _signature} =
             List.keyfind(headers, "x-wc-webhook-signature", 0)

    assert mapping_context.expected_dashboard.tickets_sold == 2
    assert mapping_context.expected_dashboard.completed_revenue == "900.00"

    acceptance_steps = [
      "POST signed completed order webhook to /webhooks/woocommerce/test-token",
      "persist valid webhook before returning 2xx",
      "enqueue and drain Oban webhook processing",
      "resolve product 501 variation 601 to the synthetic event and ticket type",
      "apply completed-only ticket and revenue totals",
      "render dashboard totals from EventSales state"
    ]

    assert is_function(&ObanHelpers.drain_default_queue/0)
    flunk("Pending Slice 1.5 acceptance: " <> Enum.join(acceptance_steps, " -> "))
  end

  test "duplicate completed webhook does not double-count dashboard totals" do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    headers = WooCommerceWebhookHelpers.signed_headers(raw_body, secret: @webhook_secret)
    mapping_context = MappingSetupHelpers.completed_order_mapping_context()

    assert {"x-wc-webhook-delivery-id", "slice-1-5-delivery"} =
             List.keyfind(headers, "x-wc-webhook-delivery-id", 0)

    assert mapping_context.expected_dashboard.tickets_sold == 2
    assert mapping_context.expected_dashboard.completed_revenue == "900.00"

    acceptance_steps = [
      "POST the same signed completed webhook twice",
      "treat the second delivery as idempotent",
      "keep durable orders, line items, aggregate events, and dashboard totals unchanged"
    ]

    flunk("Pending Slice 1.5 duplicate acceptance: " <> Enum.join(acceptance_steps, " -> "))
  end

  test "pending order is accepted but excluded from sold totals" do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_pending)
    payload = Jason.decode!(raw_body)
    headers = WooCommerceWebhookHelpers.signed_headers(raw_body, secret: @webhook_secret)

    assert payload["status"] == "pending"
    assert payload["line_items"] |> hd() |> Map.fetch!("quantity") == 1

    assert {"x-wc-webhook-topic", "order.updated"} =
             List.keyfind(headers, "x-wc-webhook-topic", 0)

    acceptance_steps = [
      "POST signed pending order webhook to /webhooks/woocommerce/test-token",
      "persist the pending order for visibility",
      "exclude pending order items from sold ticket and completed revenue totals",
      "show pending status separately on the dashboard"
    ]

    flunk("Pending Slice 1.5 pending-order acceptance: " <> Enum.join(acceptance_steps, " -> "))
  end
end
