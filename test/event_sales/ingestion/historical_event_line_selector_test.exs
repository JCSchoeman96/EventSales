defmodule EventSales.Ingestion.HistoricalEventLineSelectorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog.Resources.{Event, SourceSystem}
  alias EventSales.Ingestion.HistoricalEventLineSelector
  alias EventSales.TestSupport.SalesHelpers

  test "returns literal raw lines resolved to the target event" do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 880_101,
        external_event_kind: :tickera_event
      })

    SalesHelpers.create_variation_ticket_type!(event, 501, 601)

    target_line =
      line(1, 501, 601, [
        %{"key" => "tickera_event_id", "value" => "880101"}
      ])

    unrelated_line =
      line(2, 502, nil, [
        %{"key" => "tickera_event_id", "value" => "880999"}
      ])

    payload = order_payload([target_line, unrelated_line])

    assert {:ok, selected} = HistoricalEventLineSelector.select(event, source, payload)
    assert selected == [target_line]
    assert hd(selected) === target_line
    assert %Event{} = event
    assert %SourceSystem{} = source
  end

  test "fails closed for an unresolved line explicitly naming the target event" do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 880_102,
        external_event_kind: :tickera_event
      })

    unresolved_line =
      line(3, 503, 603, [
        %{"key" => "tickera_event_id", "value" => "880102"}
      ])

    assert {:error, {:historical_event_line_unresolved, 3, _reason}} =
             HistoricalEventLineSelector.select(event, source, order_payload([unresolved_line]))
  end

  test "excludes an unresolved line explicitly naming another event" do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 880_103,
        external_event_kind: :tickera_event
      })

    unrelated_line =
      line(4, 504, 604, [
        %{"key" => "tickera_event_id", "value" => "880999"}
      ])

    assert {:ok, []} =
             HistoricalEventLineSelector.select(event, source, order_payload([unrelated_line]))
  end

  defp order_payload(lines) do
    %{
      "id" => 91_001,
      "number" => "91001",
      "status" => "completed",
      "currency" => "ZAR",
      "date_created_gmt" => "2026-08-13T12:00:00.000000Z",
      "date_modified_gmt" => "2026-08-13T12:05:00.000000Z",
      "date_completed_gmt" => "2026-08-13T12:04:00.000000Z",
      "total" => "100.00",
      "discount_total" => "0.00",
      "total_tax" => "0.00",
      "billing" => %{
        "first_name" => "Test",
        "last_name" => "Buyer",
        "email" => "test@example.test"
      },
      "line_items" => lines,
      "coupon_lines" => []
    }
  end

  defp line(id, product_id, variation_id, meta_data) do
    %{
      "id" => id,
      "product_id" => product_id,
      "variation_id" => variation_id,
      "name" => "Ticket #{id}",
      "quantity" => 1,
      "subtotal" => "100.00",
      "total" => "100.00",
      "discount_total" => "0.00",
      "meta_data" => meta_data
    }
  end
end
