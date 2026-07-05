defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedBoundaryTest do
  use ExUnit.Case, async: true

  @hot_path_files [
    "lib/event_sales/sales/order_upserter.ex",
    "lib/event_sales/catalog/mapping_resolver.ex",
    "lib/event_sales/ingestion/webhook_intake.ex",
    "lib/event_sales/ingestion/webhook_processor.ex",
    "lib/event_sales/ingestion/workers/process_webhook_worker.ex",
    "lib/event_sales_web/controllers/webhook_controller.ex",
    "lib/event_sales/ingestion/csv_imports.ex",
    "lib/event_sales/ingestion/csv/apply_import.ex",
    "lib/event_sales/ingestion/workers/process_csv_import_worker.ex"
  ]

  test "feed client is absent from sales, mapping, webhook, and CSV hot paths" do
    for path <- @hot_path_files do
      source = File.read!(path)

      refute source =~ "WordPressFeedClient"
      refute source =~ "WordPressFeedDiscoverySource"
    end
  end

  test "feed slice does not introduce Req, Finch, or Tesla" do
    mix = File.read!("mix.exs")
    feed_sources = Path.wildcard("lib/event_sales/catalog/tickera_catalog/wordpress_feed*.ex")

    refute mix =~ "{:req"
    refute mix =~ "{:finch"
    refute mix =~ "{:tesla"

    for path <- feed_sources do
      source = File.read!(path)
      refute source =~ "Req."
      refute source =~ "Finch."
      refute source =~ "Tesla."
    end
  end
end
