defmodule EventSales.Ingestion.ProductUpdatedHandlerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Ecto.Query

  alias EventSales.Analytics.DashboardCache
  alias EventSales.Catalog
  alias EventSales.Catalog.ProductMetadataCache
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.Workers.MappingChangedWorker
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Handlers.ProductUpdatedHandler
  alias EventSales.Ingestion.Resources.WebhookDeliveryFailure
  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.Repo
  alias EventSales.Telemetry
  alias EventSales.TestSupport.SalesHelpers

  setup do
    ProductMetadataCache.reset_for_test!()
    DashboardCache.ensure_table!()
    DashboardCache.delete_table_for_test!()
    DashboardCache.ensure_table!()

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Handler Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Handler Ticket"})

    on_exit(fn ->
      ProductMetadataCache.reset_for_test!()
      DashboardCache.delete_table_for_test!()
    end)

    {:ok, source: source, event: event, ticket: ticket}
  end

  test "updated known product invalidates dashboard cache and emits cache telemetry", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    mapping =
      create_mapping!(source, event, ticket, %{woo_product_id: 601, current_label: "Old Label"})

    assert :ok = DashboardCache.put_event_summary(event.id, %{total_sold: 10})
    assert {:ok, _} = DashboardCache.get_event_summary(event.id)

    cache_handler_id = "product-updated-cache-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        cache_handler_id,
        Telemetry.cache_invalidate(),
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(cache_handler_id) end)

    {:ok, webhook_event} =
      create_product_event(source, %{
        resource_id: "601",
        payload: %{"id" => 601, "name" => "New Label"}
      })

    assert :ok = ProductUpdatedHandler.handle(webhook_event)
    assert Ash.get!(ProductMapping, mapping.id, domain: Catalog).current_label == "New Label"
    assert :miss = DashboardCache.get_event_summary(event.id)
    assert mapping_worker_count() == 0

    assert_receive {:telemetry, [:event_sales, :cache, :invalidate], %{count: 1},
                    %{event_id: event_id, reason: :product_metadata_updated}}
                   when event_id == event.id
  end

  test "unchanged known product does not invalidate dashboard cache or enqueue mapping worker", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    create_mapping!(source, event, ticket, %{woo_product_id: 602, current_label: "Same Label"})
    assert :ok = DashboardCache.put_event_summary(event.id, %{total_sold: 10})

    {:ok, webhook_event} =
      create_product_event(source, %{
        resource_id: "602",
        payload: %{"id" => 602, "name" => "Same Label"}
      })

    assert :ok = ProductUpdatedHandler.handle(webhook_event)
    assert {:ok, %{total_sold: 10}} = DashboardCache.get_event_summary(event.id)
    assert mapping_worker_count() == 0
  end

  test "unknown product logs bounded alert and returns ignored", %{source: source} do
    {:ok, webhook_event} =
      create_product_event(source, %{
        resource_id: "999999",
        payload: %{"id" => 999_999, "name" => "Unknown Product"}
      })

    assert {:ignored, :unknown_product} = ProductUpdatedHandler.handle(webhook_event)

    assert [
             %WebhookDeliveryFailure{
               reason: :unknown_product,
               topic: "product.updated",
               source_system_id: source_system_id,
               metadata: metadata
             }
           ] = Ash.read!(WebhookDeliveryFailure, domain: Ingestion)

    assert source_system_id == source.id
    assert metadata["webhook_event_id"] == webhook_event.id
    assert metadata["resource_id"] == "999999"
    assert metadata["woo_product_id"] == 999_999
    refute Map.has_key?(metadata, "payload")
    refute Map.has_key?(metadata, "raw_body")
  end

  test "invalid payload is permanent handler failure", %{source: source} do
    {:ok, webhook_event} =
      create_product_event(source, %{
        resource_id: "missing-name",
        payload: %{"id" => 603}
      })

    assert {:error, {:permanent, {:invalid_product_payload, :name, :missing}}} =
             ProductUpdatedHandler.handle(webhook_event)
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

  defp create_product_event(source, attrs) do
    now = DateTime.utc_now()

    defaults = %{
      source_system_id: source.id,
      topic: "product.updated",
      resource_type: "product",
      resource_id: "601",
      delivery_id: "delivery-#{System.unique_integer([:positive])}",
      payload: %{"id" => 601, "name" => "Product"},
      payload_hash: "hash-#{System.unique_integer([:positive])}",
      raw_body_size: 42,
      signature_validated_at: now,
      received_at: now,
      source_updated_at: ~U[2026-05-01 08:05:00Z],
      sanitized_headers_snapshot: %{}
    }

    WebhookEventStore.create_receive(Map.merge(defaults, attrs))
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
