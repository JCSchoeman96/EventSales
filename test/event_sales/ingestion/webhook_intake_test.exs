defmodule EventSales.Ingestion.WebhookIntakeTest do
  use EventSales.DataCase, async: true
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{WebhookDeliveryFailure, WebhookEvent}
  alias EventSales.Ingestion.WebhookIntake
  alias EventSales.Ingestion.Workers.ProcessWebhookWorker
  alias EventSales.Telemetry
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.WooCommerceWebhookHelpers

  @token "test-token"
  @secret "slice_1_5_webhook_secret"

  setup do
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "valid accept persists event and enqueues worker", %{source: _source} do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    headers = signed_headers(raw_body)

    assert {:ok, event} = accept(raw_body, headers)
    assert event.status == :queued
    assert_enqueued(worker: ProcessWebhookWorker, args: %{"webhook_event_id" => event.id})
  end

  test "invalid signature logs failure and does not persist event" do
    raw_body = ~s({"id":1})
    headers = signed_headers(raw_body, signature: "invalid")

    assert {:error, :invalid_signature} = accept(raw_body, headers)
    assert [] = Ash.read!(WebhookEvent, domain: Ingestion)
    assert [%{reason: :invalid_signature}] = Ash.read!(WebhookDeliveryFailure, domain: Ingestion)
    refute_enqueued(worker: ProcessWebhookWorker)
  end

  test "invalid json logs failure without payload in metadata" do
    raw_body = "not-json"
    headers = signed_headers(raw_body)

    assert {:error, :invalid_json} = accept(raw_body, headers)

    assert [%{metadata: metadata}] = Ash.read!(WebhookDeliveryFailure, domain: Ingestion)

    assert Map.get(metadata, "byte_size") ||
             Map.get(metadata, :byte_size) ==
               byte_size(raw_body)

    refute Map.has_key?(metadata, "line_items")
    refute Map.has_key?(metadata, :line_items)
  end

  test "no active woocommerce source system rejects without event or job" do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    headers = signed_headers(raw_body)

    for source <- Ash.read!(SourceSystem, domain: Catalog) do
      Ash.update!(source, %{active: false}, action: :update, domain: Catalog)
    end

    handler_id = "webhook-intake-rejected-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.webhook_rejected(),
        fn _event, measurements, metadata, _config ->
          send(self(), {:telemetry_rejected, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :no_source_system} = accept(raw_body, headers)
    assert [] = Ash.read!(WebhookEvent, domain: Ingestion)
    assert [%{reason: :no_source_system}] = Ash.read!(WebhookDeliveryFailure, domain: Ingestion)
    refute_enqueued(worker: ProcessWebhookWorker)

    assert_receive {:telemetry_rejected, %{count: 1}, %{reason: :no_source_system}}
  end

  test "wrong path token is rejected" do
    raw_body = ~s({"id":1})
    headers = signed_headers(raw_body)

    assert {:error, :wrong_path_token} =
             WebhookIntake.accept(%{
               path_token: "wrong-token",
               raw_body: raw_body,
               headers: headers,
               remote_ip: {127, 0, 0, 1},
               user_agent: "test"
             })
  end

  defp accept(raw_body, headers) do
    WebhookIntake.accept(%{
      path_token: @token,
      raw_body: raw_body,
      headers: headers,
      remote_ip: {127, 0, 0, 1},
      user_agent: "EventSales-Test"
    })
  end

  defp signed_headers(raw_body, opts \\ []) do
    signature = Keyword.get(opts, :signature)

    headers =
      WooCommerceWebhookHelpers.signed_headers(raw_body,
        secret: @secret,
        delivery_id: unique_delivery_id()
      )

    if signature do
      List.keyreplace(headers, "x-wc-webhook-signature", 0, {"x-wc-webhook-signature", signature})
    else
      headers
    end
  end

  defp unique_delivery_id do
    "delivery-#{System.unique_integer([:positive])}"
  end
end
