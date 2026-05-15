defmodule EventSales.Ingestion.WebhookIntakeBufferTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.WebhookIntake
  alias EventSales.Ingestion.Workers.{ProcessWebhookWorker, RedisWebhookBufferDrainer}
  alias EventSales.Telemetry
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.Ingestion.{MemoryWebhookBufferAdapter, StubWebhookEventStore}
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.WooCommerceWebhookHelpers

  @token "test-token"
  @secret "slice_1_5_webhook_secret"

  setup do
    MemoryWebhookBufferAdapter.reset!()
    StubWebhookEventStore.clear!()

    on_exit(fn ->
      MemoryWebhookBufferAdapter.reset!()
      StubWebhookEventStore.clear!()
    end)

    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "pool saturated buffers without postgres row or oban job", %{source: _source} do
    err = %DBConnection.ConnectionError{message: "queue_timeout", reason: :queue_timeout}
    StubWebhookEventStore.set_persist_error(err)

    handler_id = attach_telemetry()

    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    headers = signed_headers(raw_body)

    assert {:buffered, %{buffer_depth: 1}} = accept(raw_body, headers)
    assert [] = Ash.read!(WebhookEvent, domain: Ingestion)
    refute_enqueued(worker: ProcessWebhookWorker)
    refute_enqueued(worker: RedisWebhookBufferDrainer)

    assert_receive {:telemetry_buffered, %{count: 1, buffer_depth: 1},
                    %{adapter: _, accepted_via: :redis_buffer}}

    :telemetry.detach(handler_id)
  end

  test "buffer full returns error when at capacity", %{source: _source} do
    err = %DBConnection.ConnectionError{message: "queue_timeout", reason: :queue_timeout}
    StubWebhookEventStore.set_persist_error(err)

    for _ <- 1..3 do
      raw = ~s({"id":#{System.unique_integer([:positive])}})
      assert {:buffered, _} = accept(raw, signed_headers(raw))
    end

    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    assert {:error, :buffer_full} = accept(raw_body, signed_headers(raw_body))
  end

  test "pool saturated returns intake_unavailable when buffer disabled", %{source: _source} do
    previous = Application.get_env(:event_sales, :redis_webhook_buffer, [])
    disabled = Keyword.merge(previous, enabled: false, durability_accepted: false)

    Application.put_env(:event_sales, :redis_webhook_buffer, disabled)
    on_exit(fn -> Application.put_env(:event_sales, :redis_webhook_buffer, previous) end)

    err = %DBConnection.ConnectionError{message: "queue_timeout", reason: :queue_timeout}
    StubWebhookEventStore.set_persist_error(err)

    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    assert {:error, :intake_unavailable} = accept(raw_body, signed_headers(raw_body))
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
    delivery_id = Keyword.get(opts, :delivery_id, unique_delivery_id())

    WooCommerceWebhookHelpers.signed_headers(raw_body,
      secret: @secret,
      delivery_id: delivery_id
    )
  end

  defp attach_telemetry do
    handler_id = "webhook-intake-buffered-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.webhook_buffered(),
        fn _event, measurements, metadata, _config ->
          send(self(), {:telemetry_buffered, measurements, metadata})
        end,
        nil
      )

    handler_id
  end

  defp unique_delivery_id do
    "delivery-#{System.unique_integer([:positive])}"
  end
end
