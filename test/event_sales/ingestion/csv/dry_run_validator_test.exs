defmodule EventSales.Ingestion.Csv.DryRunValidatorTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion.Csv.DryRunValidator
  alias EventSales.Sales
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "CSV Import Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "General Admission"})
    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    {:ok, source: source, event: event, ticket: ticket}
  end

  test "valid rows normalize without mutating sales truth", %{source: source, event: event} do
    before_orders = Ash.count!(Order, domain: Sales)
    before_items = Ash.count!(OrderItem, domain: Sales)

    assert {:ok, result} =
             DryRunValidator.validate_file(fixture_path("import_valid.csv"), %{
               event_id: event.id,
               source_system_id: source.id
             })

    assert result.row_count == 2
    assert result.valid_count == 2
    assert result.error_count == 0
    assert Enum.all?(result.rows, &(&1.status == :valid))
    assert Ash.count!(Order, domain: Sales) == before_orders
    assert Ash.count!(OrderItem, domain: Sales) == before_items
  end

  test "invalid money and quantity produce row errors without sales mutation", %{
    source: source,
    event: event
  } do
    assert_no_sales_mutation(fn ->
      assert {:ok, result} =
               DryRunValidator.validate_file(fixture_path("import_invalid.csv"), %{
                 event_id: event.id,
                 source_system_id: source.id
               })

      assert result.error_count == 2
      assert Enum.any?(result.rows, &("quantity must be a positive integer" in &1.error_messages))

      assert Enum.any?(
               result.rows,
               &("line_total must be a non-negative money value" in &1.error_messages)
             )
    end)
  end

  test "unknown mappings fail without creating catalog or sales records", %{
    source: source,
    event: event
  } do
    assert_no_sales_mutation(fn ->
      assert {:ok, result} =
               DryRunValidator.validate_file(fixture_path("import_unknown_mapping.csv"), %{
                 event_id: event.id,
                 source_system_id: source.id
               })

      assert result.error_count == 1
      assert [%{status: :invalid, error_messages: messages}] = result.rows
      assert Enum.any?(messages, &String.contains?(&1, "unknown mapping"))
    end)
  end

  test "mappings for a different event fail", %{source: source} do
    selected_event = SalesHelpers.create_event!(source, %{name: "Selected Event"})

    other_event = SalesHelpers.create_event!(source, %{name: "Other Event"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other Ticket"})

    create_mapping!(source, other_event, other_ticket, %{
      woo_product_id: 777,
      woo_variation_id: nil
    })

    path =
      write_csv!([
        valid_row(%{
          "woo_order_id" => "30001",
          "order_number" => "ES-30001",
          "woo_line_item_id" => "90001",
          "woo_product_id" => "777",
          "woo_variation_id" => ""
        })
      ])

    assert {:ok, result} =
             DryRunValidator.validate_file(path, %{
               event_id: selected_event.id,
               source_system_id: source.id
             })

    assert [%{status: :invalid, error_messages: messages}] = result.rows
    assert "mapping belongs to a different event" in messages
  end

  test "in-file duplicates are flagged as duplicate rows", %{source: source, event: event} do
    assert_no_sales_mutation(fn ->
      assert {:ok, result} =
               DryRunValidator.validate_file(fixture_path("import_duplicate_rows.csv"), %{
                 event_id: event.id,
                 source_system_id: source.id
               })

      assert result.duplicate_count == 1
      assert Enum.any?(result.rows, &(&1.status == :duplicate))
    end)
  end

  test "existing durable duplicates check order identity then order item identity", %{
    source: source,
    event: event
  } do
    assert {:ok, _order} = OrderUpserter.upsert_order(source.id, completed_payload())

    before_orders = Ash.count!(Order, domain: Sales)
    before_items = Ash.count!(OrderItem, domain: Sales)

    assert {:ok, result} =
             DryRunValidator.validate_file(fixture_path("import_valid.csv"), %{
               event_id: event.id,
               source_system_id: source.id
             })

    assert Enum.any?(result.rows, &("line already exists in EventSales" in &1.error_messages))
    assert Ash.count!(Order, domain: Sales) == before_orders
    assert Ash.count!(OrderItem, domain: Sales) == before_items
  end

  defp assert_no_sales_mutation(fun) do
    before_orders = Ash.count!(Order, domain: Sales)
    before_items = Ash.count!(OrderItem, domain: Sales)
    fun.()
    assert Ash.count!(Order, domain: Sales) == before_orders
    assert Ash.count!(OrderItem, domain: Sales) == before_items
  end

  defp fixture_path(name), do: Path.join(["test", "fixtures", "csv", name])

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

  defp completed_payload do
    %{
      "id" => 10_001,
      "number" => "ES-10001",
      "status" => "completed",
      "currency" => "ZAR",
      "date_created_gmt" => "2026-05-01T08:00:00",
      "date_modified_gmt" => "2026-05-01T08:05:00",
      "date_completed_gmt" => "2026-05-01T08:05:00",
      "total" => "900.00",
      "discount_total" => "0.00",
      "total_tax" => "0.00",
      "line_items" => [
        %{
          "id" => 70_001,
          "product_id" => 501,
          "variation_id" => 601,
          "name" => "General Admission",
          "quantity" => 2,
          "subtotal" => "1000.00",
          "total" => "900.00",
          "discount_total" => "100.00"
        }
      ],
      "coupon_lines" => []
    }
  end

  defp write_csv!(rows) do
    headers = EventSales.Ingestion.Csv.Parser.required_headers()
    path = Path.join(System.tmp_dir!(), "event-sales-validator-#{System.unique_integer()}.csv")

    body =
      rows
      |> Enum.map_join("\n", fn row ->
        Enum.map_join(headers, ",", &Map.get(row, &1, ""))
      end)

    File.write!(path, Enum.join(headers, ",") <> "\n" <> body <> "\n")
    path
  end

  defp valid_row(overrides) do
    Map.merge(
      %{
        "woo_order_id" => "10001",
        "order_number" => "ES-10001",
        "woo_line_item_id" => "70001",
        "woo_product_id" => "501",
        "quantity" => "2",
        "line_subtotal" => "1000.00",
        "line_total" => "900.00",
        "order_raw_total" => "900.00",
        "status" => "completed",
        "currency" => "ZAR",
        "created_at_source" => "2026-05-01T08:00:00",
        "updated_at_source" => "2026-05-01T08:05:00"
      },
      overrides
    )
  end
end
