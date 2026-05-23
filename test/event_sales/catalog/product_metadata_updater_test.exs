defmodule EventSales.Catalog.ProductMetadataUpdaterTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Ecto.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.ProductMetadataCache
  alias EventSales.Catalog.ProductMetadataUpdater
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.Workers.MappingChangedWorker
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.OrderItem
  alias EventSales.Telemetry
  alias EventSales.TestSupport.SalesHelpers

  setup do
    ProductMetadataCache.reset_for_test!()
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Product Metadata Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "General Admission"})

    handler_id = "product-metadata-updater-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.product_metadata_update(),
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      ProductMetadataCache.reset_for_test!()
    end)

    {:ok, source: source, event: event, ticket: ticket}
  end

  test "known product refreshes current label without changing original label or order item label",
       %{
         source: source,
         event: event,
         ticket: ticket
       } do
    mapping =
      create_mapping!(source, event, ticket, %{
        woo_product_id: 501,
        current_label: "Old Product Label",
        original_label: "Original Product Label"
      })

    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    item =
      SalesHelpers.create_order_item_from_line!(
        order,
        product_line(%{"product_id" => 501, "name" => "Original Order Item Label"}),
        %{
          event_id: event.id,
          ticket_type_id: ticket.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    assert :ok = ProductMetadataCache.put(cached_metadata(source.id, 501, "Old Product Label"))

    assert {:ok,
            %{
              status: :updated,
              mapping: updated,
              previous_label: "Old Product Label",
              current_label: "New Product Label"
            }} =
             ProductMetadataUpdater.update_from_payload(source.id, %{
               "id" => 501,
               "name" => "New Product Label"
             })

    reloaded_mapping = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
    assert updated.id == mapping.id
    assert reloaded_mapping.current_label == "New Product Label"
    assert reloaded_mapping.original_label == "Original Product Label"
    assert Ash.get!(OrderItem, item.id, domain: Sales).name == "Original Order Item Label"
    assert :miss = ProductMetadataCache.get(source.id, 501, nil)
    assert mapping_worker_count() == 0

    assert_receive {:telemetry, [:event_sales, :catalog, :product_metadata, :update], %{count: 1},
                    %{result: :updated, source: :woocommerce}}
  end

  test "unchanged known product does not update, version, enqueue, or invalidate metadata cache",
       %{
         source: source,
         event: event,
         ticket: ticket
       } do
    mapping =
      create_mapping!(source, event, ticket, %{
        woo_product_id: 502,
        current_label: "Same Product Label"
      })

    assert :ok = ProductMetadataCache.put(cached_metadata(source.id, 502, "Same Product Label"))
    before_updated_at = mapping.updated_at

    assert {:ok, %{status: :unchanged, mapping: unchanged, current_label: "Same Product Label"}} =
             ProductMetadataUpdater.update_from_payload(source.id, %{
               "id" => 502,
               "name" => "Same Product Label"
             })

    reloaded_mapping = Ash.get!(ProductMapping, mapping.id, domain: Catalog)
    assert unchanged.id == mapping.id
    assert reloaded_mapping.updated_at == before_updated_at

    assert Ash.load!(reloaded_mapping, :paper_trail_versions, domain: Catalog).paper_trail_versions ==
             []

    assert {:ok, %{name: "Same Product Label"}} = ProductMetadataCache.get(source.id, 502, nil)
    assert mapping_worker_count() == 0

    assert_receive {:telemetry, [:event_sales, :catalog, :product_metadata, :update], %{count: 1},
                    %{result: :unchanged, source: :woocommerce}}
  end

  test "unknown product is ignored, does not create mapping, and invalidates cached metadata", %{
    source: source
  } do
    assert :ok = ProductMetadataCache.put(cached_metadata(source.id, 999_999, "Old Unknown"))
    before_count = Ash.count!(ProductMapping, domain: Catalog)

    assert {:ignored, :unknown_product, %{woo_product_id: 999_999, current_label: "Unknown"}} =
             ProductMetadataUpdater.update_from_payload(source.id, %{
               "id" => 999_999,
               "name" => "Unknown"
             })

    assert Ash.count!(ProductMapping, domain: Catalog) == before_count
    assert :miss = ProductMetadataCache.get(source.id, 999_999, nil)

    assert_receive {:telemetry, [:event_sales, :catalog, :product_metadata, :update], %{count: 1},
                    %{result: :unknown_product, source: :woocommerce}}
  end

  test "invalid payload is permanent input failure and emits invalid telemetry", %{source: source} do
    assert {:error, {:invalid_product_payload, :id, :missing}} =
             ProductMetadataUpdater.update_from_payload(source.id, %{"name" => "No ID"})

    assert {:error, {:invalid_product_payload, :name, :blank}} =
             ProductMetadataUpdater.update_from_payload(source.id, %{"id" => 501, "name" => "  "})

    assert_receive {:telemetry, [:event_sales, :catalog, :product_metadata, :update], %{count: 1},
                    %{result: :invalid_payload, source: :woocommerce}}
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
    |> tap(fn _ -> delete_mapping_jobs!() end)
  end

  defp product_line(overrides) do
    %{
      "id" => System.unique_integer([:positive]),
      "product_id" => 501,
      "variation_id" => nil,
      "name" => "Original Order Item Label",
      "quantity" => 1,
      "subtotal" => "450.00",
      "total" => "450.00",
      "discount_total" => "0.00"
    }
    |> Map.merge(overrides)
  end

  defp cached_metadata(source_system_id, woo_product_id, name) do
    %{
      source_system_id: source_system_id,
      woo_product_id: woo_product_id,
      woo_variation_id: nil,
      name: name,
      product_type: "simple",
      status: "publish"
    }
  end

  defp mapping_worker_count do
    worker = Oban.Worker.to_string(MappingChangedWorker)

    from(j in Oban.Job, where: j.worker == ^worker, select: count(j.id))
    |> Repo.one!()
  end

  defp delete_mapping_jobs! do
    worker = Oban.Worker.to_string(MappingChangedWorker)

    from(j in Oban.Job, where: j.worker == ^worker)
    |> Repo.delete_all()
  end
end
