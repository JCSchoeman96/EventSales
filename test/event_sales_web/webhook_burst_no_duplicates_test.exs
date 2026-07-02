defmodule EventSalesWeb.WebhookBurstNoDuplicatesTest do
  use EventSalesWeb.ConnCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Ecto.Query
  import EventSales.DataCase, only: [setup_sandbox: 1]

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias EventSales.Repo

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.Workers.ProcessWebhookWorker
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.Ingestion.MemoryRateLimiterAdapter
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.WooCommerceWebhookHelpers

  @path_token "test-token"
  @webhook_secret "slice_1_5_webhook_secret"
  @burst_count 24

  setup tags do
    setup_sandbox(tags)
    MemoryRateLimiterAdapter.reset_for_test!()
    delete_process_webhook_jobs!()

    on_exit(fn ->
      MemoryRateLimiterAdapter.reset_for_test!()
      delete_process_webhook_jobs!()
    end)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Burst Test Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    create_product_mapping!(source, event, ticket)

    {:ok, event: event}
  end

  test "concurrent duplicate delivery creates one webhook event and one order line", %{
    event: event
  } do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    delivery_id = "vs-25-burst-#{System.unique_integer([:positive])}"

    headers =
      WooCommerceWebhookHelpers.signed_headers(raw_body,
        secret: @webhook_secret,
        delivery_id: delivery_id
      )

    parent = self()

    results =
      1..@burst_count
      |> Task.async_stream(
        fn _ ->
          Sandbox.allow(Repo, parent, self())

          build_conn()
          |> put_req_headers(headers)
          |> put_req_header("content-type", "application/json")
          |> post(~p"/webhooks/woocommerce/#{@path_token}", raw_body)
          |> response(200)
        end,
        max_concurrency: @burst_count,
        timeout: 30_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, "ok"} -> true
             _ -> false
           end)

    assert [%WebhookEvent{}] =
             WebhookEvent
             |> Ash.Query.filter(delivery_id == ^delivery_id)
             |> Ash.read!(domain: Ingestion)

    assert_enqueued(worker: ProcessWebhookWorker, queue: :webhooks)
    drain_jobs!()

    assert Ash.count!(Order, domain: Sales) == 1
    assert Ash.count!(OrderItem, domain: Sales) == 1

    assert [%OrderItem{quantity: 2}] = Ash.read!(OrderItem, domain: Sales)
    refute is_nil(event.id)
  end

  defp put_req_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      put_req_header(acc, name, value)
    end)
  end

  defp create_product_mapping!(source, event, ticket) do
    Ash.create!(
      ProductMapping,
      %{
        source_system_id: source.id,
        event_id: event.id,
        ticket_type_id: ticket.id,
        woo_product_id: 501,
        woo_variation_id: 601,
        original_label: "GA",
        current_label: "GA",
        active: true
      },
      action: :create,
      domain: Catalog
    )
  end

  defp delete_process_webhook_jobs! do
    Repo.delete_all(
      from(j in Oban.Job, where: j.worker == ^"EventSales.Ingestion.Workers.ProcessWebhookWorker")
    )
  end

  defp drain_jobs! do
    Oban.drain_queue(queue: :webhooks, with_safety: false)
  end
end
