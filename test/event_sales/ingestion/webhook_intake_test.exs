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

  test "duplicate delivery_id with matching payload_hash is ignored idempotently", %{
    source: _source
  } do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    delivery_id = unique_delivery_id()
    headers = signed_headers(raw_body, delivery_id: delivery_id)

    assert {:ok, first} = accept(raw_body, headers)
    assert_enqueued(worker: ProcessWebhookWorker, args: %{"webhook_event_id" => first.id})

    assert {:ignored, :duplicate, second} = accept(raw_body, headers)
    assert second.id == first.id
    assert length(Ash.read!(WebhookEvent, domain: Ingestion)) == 1
    assert length(process_webhook_jobs()) == 1
    assert_single_job_for_event!(first.id)
  end

  test "duplicate delivery_id with different payload_hash logs mismatch and ignores", %{
    source: source
  } do
    delivery_id = unique_delivery_id()
    raw_body_a = ~s({"id":10001,"status":"completed"})
    raw_body_b = ~s({"id":10001,"status":"pending"})

    headers_a = signed_headers(raw_body_a, delivery_id: delivery_id)
    assert {:ok, _} = accept(raw_body_a, headers_a)

    headers_b = signed_headers(raw_body_b, delivery_id: delivery_id)

    assert {:ignored, :duplicate_payload_mismatch} = accept(raw_body_b, headers_b)

    assert [%{reason: :duplicate_payload_mismatch, source_system_id: sid, metadata: metadata}] =
             Ash.read!(WebhookDeliveryFailure, domain: Ingestion)

    assert sid == source.id
    assert metadata["delivery_id"] == delivery_id
    assert metadata["existing_payload_hash"]
    assert metadata["incoming_payload_hash"]
    refute Map.has_key?(metadata, "payload")
    refute Map.has_key?(metadata, "raw_body")
    assert length(Ash.read!(WebhookEvent, domain: Ingestion)) == 1
    assert length(process_webhook_jobs()) == 1
  end

  test "stale replay returns ignored stale_replay without event or enqueue", %{source: source} do
    base = FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)
    newer = Map.put(base, "date_modified_gmt", "2026-05-01T08:10:00")
    older = Map.put(base, "date_modified_gmt", "2026-05-01T08:05:00")

    newer_raw = Jason.encode!(newer)
    older_raw = Jason.encode!(older)

    newer_headers = signed_headers(newer_raw, delivery_id: unique_delivery_id())
    assert {:ok, first} = accept(newer_raw, newer_headers)
    assert_enqueued(worker: ProcessWebhookWorker, args: %{"webhook_event_id" => first.id})

    older_headers = signed_headers(older_raw, delivery_id: unique_delivery_id())
    assert {:ignored, :stale_replay} = accept(older_raw, older_headers)

    assert [%{reason: :stale_replay, source_system_id: sid}] =
             Ash.read!(WebhookDeliveryFailure, domain: Ingestion)

    assert sid == source.id
    assert length(Ash.read!(WebhookEvent, domain: Ingestion)) == 1
    assert length(process_webhook_jobs()) == 1
    assert_single_job_for_event!(first.id)
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
    delivery_id = Keyword.get(opts, :delivery_id, unique_delivery_id())

    headers =
      WooCommerceWebhookHelpers.signed_headers(raw_body,
        secret: @secret,
        delivery_id: delivery_id
      )

    if signature do
      List.keyreplace(headers, "x-wc-webhook-signature", 0, {"x-wc-webhook-signature", signature})
    else
      headers
    end
  end

  defp process_webhook_jobs do
    all_enqueued(worker: ProcessWebhookWorker)
  end

  defp assert_single_job_for_event!(event_id) do
    jobs = Enum.filter(process_webhook_jobs(), &(&1.args["webhook_event_id"] == event_id))
    assert length(jobs) == 1
    hd(jobs)
  end

  defp unique_delivery_id do
    "delivery-#{System.unique_integer([:positive])}"
  end
end
