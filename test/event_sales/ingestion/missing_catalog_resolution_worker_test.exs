defmodule EventSales.Ingestion.MissingCatalogResolutionWorkerTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.ProductMetadataCache
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion.Clients.WooCommerceError
  alias EventSales.Ingestion.Workers.MissingCatalogResolutionWorker
  alias EventSales.Sales
  alias EventSales.Sales.Resources.OrderItem
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers

  defmodule FakeWooClient do
    @moduledoc false

    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], calls: []} end, name: __MODULE__)

    def reset!(responses) do
      Agent.update(__MODULE__, fn _state -> %{responses: responses, calls: []} end)
    end

    def calls do
      Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    end

    def fetch_product(id, opts \\ []) do
      Agent.get_and_update(__MODULE__, fn %{responses: [response | rest], calls: calls} = state ->
        {{:reply, response}, %{state | responses: rest, calls: [{id, opts} | calls]}}
      end)
      |> case do
        {:reply, response} -> response
      end
    end
  end

  setup do
    start_supervised!(FakeWooClient)
    ProductMetadataCache.reset_for_test!()

    original_client = Application.get_env(:event_sales, :woocommerce_client)
    Application.put_env(:event_sales, :woocommerce_client, FakeWooClient)

    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event = SalesHelpers.create_event!(source, %{name: "Recovered Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Recovered Ticket"})

    on_exit(fn ->
      restore_env(:woocommerce_client, original_client)
      ProductMetadataCache.reset_for_test!()
    end)

    {:ok, source: source, order: order, event: event, ticket: ticket}
  end

  test "cache miss fetches product metadata through configured client, caches, and remaps", %{
    source: source,
    order: order,
    event: event
  } do
    ticket =
      SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{
        name: "Recovered Variation"
      })

    item = create_item!(order, %{woo_product_id: 501, woo_variation_id: 601})
    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    FakeWooClient.reset!([
      {:ok, %{"id" => 501, "name" => "VIP Ticket", "type" => "variable", "status" => "publish"}}
    ])

    assert :ok =
             perform(%{
               "source_system_id" => source.id,
               "woo_product_id" => 501,
               "woo_variation_id" => 601
             })

    assert [{501, _opts}] = FakeWooClient.calls()

    assert {:ok, %{name: "VIP Ticket", woo_variation_id: 601}} =
             ProductMetadataCache.get(source.id, 501, 601)

    assert Ash.get!(OrderItem, item.id, domain: Sales).mapping_status == :mapped
  end

  test "cache hit skips client and still runs local resolver", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    item = create_item!(order, %{woo_product_id: 501, woo_variation_id: nil})
    create_mapping!(source, event, ticket, %{woo_product_id: 501})

    assert :ok =
             ProductMetadataCache.put(%{
               source_system_id: source.id,
               woo_product_id: 501,
               woo_variation_id: nil,
               name: "Cached Product",
               product_type: "simple",
               status: "publish"
             })

    FakeWooClient.reset!([])

    assert :ok =
             perform(%{
               "source_system_id" => source.id,
               "woo_product_id" => 501,
               "woo_variation_id" => nil
             })

    assert [] = FakeWooClient.calls()
    assert Ash.get!(OrderItem, item.id, domain: Sales).mapping_status == :mapped
  end

  test "not_found marks matching pending rows unmapped", %{source: source, order: order} do
    item = create_item!(order, %{woo_product_id: 999_999, woo_variation_id: nil})
    FakeWooClient.reset!([{:error, WooCommerceError.exception(reason: :not_found)}])

    assert :ok =
             perform(%{
               "source_system_id" => source.id,
               "woo_product_id" => 999_999,
               "woo_variation_id" => nil
             })

    assert Ash.get!(OrderItem, item.id, domain: Sales).mapping_status == :unmapped
  end

  test "transient errors retry through Oban", %{source: source} do
    FakeWooClient.reset!([{:error, WooCommerceError.exception(reason: :timeout)}])

    assert {:error, :timeout} =
             perform(%{
               "source_system_id" => source.id,
               "woo_product_id" => 501,
               "woo_variation_id" => nil
             })
  end

  test "auth and config errors discard without mutating pending rows", %{
    source: source,
    order: order
  } do
    item = create_item!(order, %{woo_product_id: 501, woo_variation_id: nil})
    FakeWooClient.reset!([{:error, WooCommerceError.exception(reason: :unauthorized)}])

    assert :discard =
             perform(%{
               "source_system_id" => source.id,
               "woo_product_id" => 501,
               "woo_variation_id" => nil
             })

    assert Ash.get!(OrderItem, item.id, domain: Sales).mapping_status ==
             :pending_mapping_resolution
  end

  test "duplicate active jobs are unique without suppressing completed jobs", %{source: source} do
    args = %{
      "source_system_id" => source.id,
      "woo_product_id" => 501,
      "woo_variation_id" => nil
    }

    assert %Oban.Job{conflict?: false} =
             args |> MissingCatalogResolutionWorker.new() |> Oban.insert!()

    assert %Oban.Job{conflict?: true} =
             args |> MissingCatalogResolutionWorker.new() |> Oban.insert!()

    assert refute_completed_uniqueness()
  end

  defp perform(args), do: MissingCatalogResolutionWorker.perform(%Oban.Job{args: args})

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

  defp create_item!(order, attrs) do
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

  defp refute_completed_uniqueness do
    MissingCatalogResolutionWorker.__opts__()
    |> Keyword.fetch!(:unique)
    |> Keyword.fetch!(:states)
    |> Enum.member?(:completed)
    |> Kernel.not()
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
