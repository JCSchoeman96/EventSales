defmodule EventSales.Ingestion.OrderReconciliationTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.OrderReconciliation
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.Order
  alias EventSales.TestSupport.{FixtureHelpers, SalesHelpers}

  defmodule FakeTransport do
    @behaviour EventSales.Ingestion.Clients.WooCommerceTransport

    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], requests: []} end, name: __MODULE__)

    def reset!(responses) do
      Agent.update(__MODULE__, fn _ -> %{responses: responses, requests: []} end)
    end

    def requests do
      Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    end

    @impl true
    def request(_method, url, _headers, _body, _opts) do
      Agent.get_and_update(__MODULE__, fn %{responses: [response | rest], requests: requests} =
                                            state ->
        {response, %{state | responses: rest, requests: [%{url: url} | requests]}}
      end)
    end
  end

  defmodule FakeNotifier do
    @moduledoc false

    def notify_order_reconciled(order, sync_run, event_id, _opts \\ []) do
      send(self(), {:notify_order_reconciled, order.id, sync_run.id, event_id})
      :ok
    end
  end

  setup do
    start_supervised!(FakeTransport)

    original_config = Application.get_env(:event_sales, :woocommerce_rest)
    original_breaker = Application.get_env(:event_sales, :rest_circuit_breaker)

    Application.put_env(:event_sales, :rest_circuit_breaker,
      failure_threshold: 3,
      cooldown_ms: 50
    )

    Application.put_env(:event_sales, :woocommerce_rest,
      base_url: "https://woo.example.test",
      consumer_key: "ck_test_secret",
      consumer_secret: "cs_test_secret",
      timeout_ms: 1_000,
      queue_timeout_ms: 1_000,
      per_page: 2,
      max_pages: 3,
      transport: FakeTransport
    )

    EventSales.Ingestion.RestRateLimiter.reset_for_test!(max_concurrency: 2)
    EventSales.Ingestion.RestCircuitBreaker.reset_for_test!()

    on_exit(fn ->
      restore_env(:woocommerce_rest, original_config)
      restore_env(:rest_circuit_breaker, original_breaker)
      EventSales.Ingestion.RestRateLimiter.reset_for_test!(max_concurrency: 2)
      EventSales.Ingestion.RestCircuitBreaker.reset_for_test!()
    end)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "Reconcile", slug: unique_slug("reconcile")})

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    {:ok, source: source, event: event, ticket: ticket}
  end

  test "woo_params include modified window, sort, and pagination", %{source: source, event: event} do
    run =
      create_running_run!(source, event, %{
        date_from: ~U[2026-05-01 00:00:00Z],
        date_to: ~U[2026-05-03 00:00:00Z]
      })

    cursor = cursor_for!(run, %{page: 2, modified_after: ~U[2026-05-01 12:00:00Z]})

    params = OrderReconciliation.woo_params(run, cursor)

    assert params == %{
             "modified_after" => "2026-05-01T12:00:00Z",
             "modified_before" => "2026-05-03T00:00:00Z",
             "orderby" => "modified",
             "order" => "asc",
             "page" => "2",
             "per_page" => "2"
           }
  end

  test "run_step sends exact Woo query params through the REST client", %{
    source: source,
    event: event
  } do
    ticket = SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{name: "Variation GA"})
    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    run = create_running_run!(source, event, %{})
    cursor = cursor_for!(run, %{})

    order = FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)

    FakeTransport.reset!([
      {:ok, 200, [], Jason.encode!([order])}
    ])

    assert {:complete, finished} =
             OrderReconciliation.run_step(run, cursor,
               transport: FakeTransport,
               notifier: FakeNotifier
             )

    assert finished.orders_seen_count == 1
    assert finished.orders_matched_count == 1
    assert finished.orders_upserted_count == 1

    assert [%{url: url}] = FakeTransport.requests()
    query = URI.parse(url) |> Map.get(:query) |> URI.decode_query()

    assert query["modified_after"] == iso8601_second(run.date_from)
    assert query["modified_before"] == iso8601_second(run.date_to)
    assert query["orderby"] == "modified"
    assert query["order"] == "asc"
    assert query["page"] == "1"
    assert query["per_page"] == "2"
  end

  test "variation mapping requires both product and variation ids", %{
    source: source,
    event: event
  } do
    ticket = SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{name: "Variation GA"})
    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    line = %{"product_id" => 501, "variation_id" => 999}
    refute OrderReconciliation.matches_event_mapping?(line, active_mappings(source, event))

    assert OrderReconciliation.matches_event_mapping?(
             %{"product_id" => 501, "variation_id" => 601},
             active_mappings(source, event)
           )
  end

  test "product-only mapping matches only lines without a variation id", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    create_mapping!(source, event, ticket, %{woo_product_id: 777, woo_variation_id: nil})

    mappings = active_mappings(source, event)

    assert OrderReconciliation.matches_event_mapping?(
             %{"product_id" => 777, "variation_id" => 0},
             mappings
           )

    refute OrderReconciliation.matches_event_mapping?(
             %{"product_id" => 777, "variation_id" => 888},
             mappings
           )
  end

  test "product-only mapping does not match another event's variation-specific mapping", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    other_event = SalesHelpers.create_event!(source, %{name: "Other", slug: unique_slug("other")})

    other_ticket =
      SalesHelpers.create_variation_ticket_type!(other_event, 900, 801, %{name: "VIP"})

    create_mapping!(source, event, ticket, %{woo_product_id: 900, woo_variation_id: nil})

    create_mapping!(source, other_event, other_ticket, %{
      woo_product_id: 900,
      woo_variation_id: 801
    })

    assert OrderReconciliation.matches_event_mapping?(
             %{"product_id" => 900, "variation_id" => 0},
             active_mappings(source, event)
           )

    refute OrderReconciliation.matches_event_mapping?(
             %{"product_id" => 900, "variation_id" => 801},
             active_mappings(source, event)
           )
  end

  test "retryable WooCommerce error pauses the sync run with paused_until", %{
    source: source,
    event: event
  } do
    run = create_running_run!(source, event, %{})
    cursor = cursor_for!(run, %{})

    FakeTransport.reset!([{:ok, 429, [], "{}"}])

    assert {:pause, paused, :rate_limited, seconds} =
             OrderReconciliation.run_step(run, cursor, transport: FakeTransport)

    assert seconds > 0
    assert paused.status == :paused
    assert paused.pause_reason == :rate_limited
    assert %DateTime{} = paused.paused_until
    assert DateTime.compare(paused.paused_until, DateTime.utc_now()) == :gt
  end

  test "successful upsert increments counts and notifies once per order", %{
    source: source,
    event: event
  } do
    ticket = SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{name: "Variation GA"})
    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    run = create_running_run!(source, event, %{})
    cursor = cursor_for!(run, %{})

    order_payload = FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)

    FakeTransport.reset!([
      {:ok, 200, [], Jason.encode!([order_payload])}
    ])

    assert {:complete, finished} =
             OrderReconciliation.run_step(run, cursor,
               transport: FakeTransport,
               notifier: FakeNotifier
             )

    assert finished.orders_upserted_count == 1
    assert Ash.count!(Order, domain: Sales) == 1

    assert_receive {:notify_order_reconciled, _order_id, run_id, event_id}
    assert run_id == run.id
    assert event_id == event.id
    refute_receive {:notify_order_reconciled, _, _, _}, 50
  end

  test "stale upsert increments orders_stale_count", %{
    source: source,
    event: event
  } do
    ticket = SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{name: "Variation GA"})
    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    existing =
      SalesHelpers.create_order_from_fixture!(:order_completed, source)
      |> Ash.update!(
        %{updated_at_source: ~U[2099-01-01 00:00:00Z]},
        action: :sync_from_normalized,
        domain: Sales
      )

    run = create_running_run!(source, event, %{})
    cursor = cursor_for!(run, %{})

    FakeTransport.reset!([
      {:ok, 200, [],
       Jason.encode!([FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)])}
    ])

    assert {:complete, finished} =
             OrderReconciliation.run_step(run, cursor,
               transport: FakeTransport,
               notifier: FakeNotifier
             )

    assert finished.orders_stale_count == 1
    assert finished.orders_upserted_count == 0

    assert DateTime.compare(
             Ash.get!(Order, existing.id, domain: Sales).updated_at_source,
             ~U[2099-01-01 00:00:00Z]
           ) == :eq
  end

  test "load_or_init_cursor creates a per-run cursor scoped to the run dates", %{
    source: source,
    event: event
  } do
    run = create_manual_run!(source, event, %{})

    assert {:ok, cursor} = OrderReconciliation.load_or_init_cursor(run)
    assert cursor.sync_run_id == run.id
    assert cursor.page == 1
    assert cursor.modified_after == run.date_from
    assert cursor.modified_before == run.date_to
    assert cursor.status == :active
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)

  defp create_manual_run!(source, event, attrs) do
    defaults = %{
      source_system_id: source.id,
      event_id: event.id,
      date_from: ~U[2026-05-01 00:00:00Z],
      date_to: ~U[2026-05-02 00:00:00Z],
      sync_mode: :shallow,
      requested_via: :manual
    }

    {:ok, run} =
      SyncRun
      |> Ash.Changeset.for_create(:queue_manual_scoped, Map.merge(defaults, attrs))
      |> Ash.create(
        domain: Ingestion,
        context: %{scoped_manual_sync_now: ~U[2026-05-16 12:00:00Z]}
      )

    run
  end

  defp create_running_run!(source, event, attrs) do
    source
    |> then(&create_manual_run!(&1, event, attrs))
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
  end

  defp cursor_for!(run, attrs) do
    {:ok, cursor} =
      SyncCursor
      |> Ash.Changeset.for_create(:upsert_active, %{
        sync_run_id: run.id,
        page: Map.get(attrs, :page, 1),
        modified_after: Map.get(attrs, :modified_after, run.date_from),
        modified_before: run.date_to,
        metadata: %{}
      })
      |> Ash.create(domain: Ingestion)

    cursor
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

    Ash.create!(ProductMapping, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp active_mappings(source, event) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source.id and event_id == ^event.id and active == true
    )
    |> Ash.read!(domain: Catalog)
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp iso8601_second(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
