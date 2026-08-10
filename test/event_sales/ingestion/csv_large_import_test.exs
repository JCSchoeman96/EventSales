defmodule EventSales.Ingestion.CsvLargeImportTest do
  use EventSales.DataCase, async: false

  import EventSales.TestSupport.AuthHelpers

  require Ash.Query

  alias EventSales.Analytics.HotStateAggregator
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Csv.ApplyImport
  alias EventSales.Ingestion.CsvImports
  alias EventSales.Ingestion.Resources.CsvImportRow
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  @row_count 2_000
  @moduletag timeout: 300_000

  setup do
    HotStateAggregator.reset_for_test!()
    on_exit(fn -> HotStateAggregator.reset_for_test!() end)

    admin = create_user!("csv-large-import@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Large CSV Event"})
    ticket = SalesHelpers.create_variation_ticket_type!(event, 9001, 9002, %{name: "GA"})
    create_mapping!(source, event, ticket, %{woo_product_id: 9001, woo_variation_id: 9002})

    path = write_large_csv!()

    on_exit(fn -> File.rm(path) end)

    {:ok, admin: admin, event: event, path: path}
  end

  test "dry-run and apply complete for a 2000-row synthetic CSV without PII", %{
    admin: admin,
    event: event,
    path: path
  } do
    assert {:ok, batch} =
             CsvImports.dry_run_file(
               path,
               %{event_id: event.id, source_filename: "large_import.csv"},
               actor: admin
             )

    assert batch.status == :dry_run_passed
    assert Ash.count!(CsvImportRow, domain: Ingestion) == @row_count

    assert {:ok, applied} = ApplyImport.apply(batch.id)
    assert applied.status == :applied
    assert Ash.count!(Order, domain: Sales) == @row_count
    assert Ash.count!(OrderItem, domain: Sales) == @row_count
  end

  defp write_large_csv! do
    path =
      Path.join(System.tmp_dir!(), "eventsales-large-#{System.unique_integer([:positive])}.csv")

    headers =
      [
        "woo_order_id",
        "order_number",
        "woo_line_item_id",
        "woo_product_id",
        "quantity",
        "line_subtotal",
        "line_total",
        "order_raw_total",
        "status",
        "currency",
        "created_at_source",
        "updated_at_source",
        "woo_variation_id"
      ]
      |> Enum.join(",")

    rows =
      Enum.map(1..@row_count, fn index ->
        [
          100_000 + index,
          "L-#{index}",
          200_000 + index,
          9001,
          1,
          "100.00",
          "100.00",
          "100.00",
          "completed",
          "ZAR",
          "2026-05-01T10:00:00Z",
          "2026-05-01T10:00:00Z",
          9002
        ]
        |> Enum.join(",")
      end)

    File.write!(path, [headers | rows] |> Enum.join("\n"))
    path
  end

  defp create_mapping!(source, event, ticket, attrs) do
    Ash.create!(
      ProductMapping,
      Map.merge(
        %{
          source_system_id: source.id,
          event_id: event.id,
          ticket_type_id: ticket.id,
          original_label: "GA",
          current_label: "GA",
          active: true
        },
        attrs
      ),
      action: :create,
      domain: Catalog
    )
  end
end
