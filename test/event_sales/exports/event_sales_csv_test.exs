defmodule EventSales.Exports.EventSalesCsvTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Exports.EventSalesCsv
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    admin = create_user!("exports-admin@example.com")
    create_global_role!(admin, :admin)
    staff = create_user!("exports-staff@example.com")
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Exports Event",
        slug: unique_slug("exports"),
        capacity: 10
      })

    other_event =
      SalesHelpers.create_event!(source, %{
        name: "Other Exports Event",
        slug: unique_slug("other-exports")
      })

    balcony = SalesHelpers.create_ticket_type!(event, %{name: "Balcony", capacity: nil})
    stalls = SalesHelpers.create_ticket_type!(event, %{name: "Stalls", capacity: 6})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other Ticket"})

    %{
      admin: admin,
      staff: staff,
      source: source,
      event: event,
      other_event: other_event,
      balcony: balcony,
      stalls: stalls,
      other_ticket: other_ticket
    }
  end

  test "summary export is event-scoped, ordered by ticket type, and totals last", %{
    admin: admin,
    source: source,
    event: event,
    other_event: other_event,
    balcony: balcony,
    stalls: stalls,
    other_ticket: other_ticket
  } do
    completed = create_order!(source, :completed, order_number: "VISIBLE")
    create_item!(completed, event, stalls, quantity: 2, line_total: Decimal.new("200.00"))
    create_item!(completed, event, balcony, quantity: 1, line_total: Decimal.new("125.00"))

    create_item!(completed, other_event, other_ticket,
      quantity: 8,
      line_total: Decimal.new("800.00")
    )

    pending = create_order!(source, :pending, order_number: "PENDING")
    create_item!(pending, event, stalls, quantity: 5, line_total: Decimal.new("500.00"))

    create_item!(completed, event, stalls,
      name: "Unmapped Item",
      woo_line_item_id: 701,
      mapping_status: :unmapped,
      item_kind: :unknown,
      line_total: Decimal.new("900.00")
    )

    create_item!(completed, event, stalls,
      name: "Non Ticket Item",
      woo_line_item_id: 702,
      mapping_status: :non_ticket,
      item_kind: :non_ticket,
      line_total: Decimal.new("300.00")
    )

    assert {:ok, chunks, false} = EventSalesCsv.summary_csv(event.id, actor: admin)

    rows = csv_rows(chunks)

    assert [
             [
               "row_type",
               "event_id",
               "event_name",
               "ticket_type_id",
               "ticket_type_name",
               "capacity",
               "sold",
               "remaining",
               "revenue",
               "currency"
             ],
             balcony_row,
             stalls_row,
             total_row
           ] = rows

    assert [
             "ticket_type",
             event_id,
             "Exports Event",
             balcony_id,
             "Balcony",
             "",
             "1",
             "",
             "125.00",
             "ZAR"
           ] = balcony_row

    assert [
             "ticket_type",
             ^event_id,
             "Exports Event",
             stalls_id,
             "Stalls",
             "6",
             "2",
             "4",
             "200.00",
             "ZAR"
           ] = stalls_row

    assert [
             "total",
             ^event_id,
             "Exports Event",
             "",
             "Total",
             "10",
             "3",
             "7",
             "325.00",
             "ZAR"
           ] = total_row

    assert event_id == event.id
    assert balcony_id == balcony.id
    assert stalls_id == stalls.id

    flat = csv_body(chunks)
    refute flat =~ "Other Exports Event"
    refute flat =~ "PENDING"
    refute flat =~ "Unmapped Item"
    refute flat =~ "Non Ticket Item"
  end

  test "order export includes operational item rows, excludes other events and PII, and is deterministic",
       %{
         admin: admin,
         source: source,
         event: event,
         other_event: other_event,
         balcony: balcony,
         stalls: stalls,
         other_ticket: other_ticket
       } do
    newest =
      create_order!(source, :completed,
        order_number: "NEWEST",
        updated_at_source: ~U[2026-05-18 10:00:00.000000Z]
      )

    older =
      create_order!(source, :completed,
        order_number: "OLDER",
        updated_at_source: ~U[2026-05-18 09:00:00.000000Z]
      )

    create_item!(newest, event, stalls,
      woo_line_item_id: 20,
      name: "Needs Mapping",
      mapping_status: :unmapped,
      item_kind: :unknown
    )

    create_item!(newest, event, balcony,
      woo_line_item_id: 10,
      name: "Newest Ticket",
      quantity: 2,
      line_total: Decimal.new("220.00")
    )

    create_item!(older, event, stalls,
      woo_line_item_id: 30,
      name: "Old Non Ticket",
      mapping_status: :non_ticket,
      item_kind: :non_ticket
    )

    create_item!(older, other_event, other_ticket,
      woo_line_item_id: 40,
      name: "Other Event Item"
    )

    assert {:ok, chunks, false} = EventSalesCsv.orders_csv(event.id, actor: admin)
    rows = csv_rows(chunks)
    body = csv_body(chunks)

    assert [
             _headers,
             newest_ticket,
             newest_unmapped,
             older_non_ticket
           ] = rows

    assert Enum.at(newest_ticket, 3) == "NEWEST"
    assert Enum.at(newest_ticket, 5) == "10"
    assert Enum.at(newest_ticket, 8) == "Newest Ticket"
    assert Enum.at(newest_ticket, 10) == "mapped"

    assert Enum.at(newest_unmapped, 3) == "NEWEST"
    assert Enum.at(newest_unmapped, 5) == "20"
    assert Enum.at(newest_unmapped, 10) == "unmapped"

    assert Enum.at(older_non_ticket, 3) == "OLDER"
    assert Enum.at(older_non_ticket, 10) == "non_ticket"

    refute body =~ "Other Event Item"
    refute body =~ "Private Customer"
    refute body =~ "private@example.test"
    refute body =~ "txn_private"
    refute body =~ "payment_gateway_transaction_id"
  end

  test "exports require admin actor", %{staff: staff, event: event} do
    assert {:error, :forbidden} = EventSalesCsv.summary_csv(event.id, actor: staff)
    assert {:error, :forbidden} = EventSalesCsv.orders_csv(event.id, actor: staff)
    assert {:error, :forbidden} = EventSalesCsv.summary_csv(event.id, actor: nil)
    assert {:error, :forbidden} = EventSalesCsv.orders_csv(event.id, actor: nil)
  end

  test "order export caps data rows and reports truncation", %{
    admin: admin,
    source: source,
    event: event,
    stalls: stalls
  } do
    for index <- 1..3 do
      order =
        create_order!(source, :completed,
          woo_order_id: 8_000 + index,
          order_number: "CAP-#{index}",
          updated_at_source: DateTime.add(~U[2026-05-18 08:00:00.000000Z], index, :second)
        )

      create_item!(order, event, stalls, woo_line_item_id: 9_000 + index)
    end

    assert {:ok, chunks, true} = EventSalesCsv.orders_csv(event.id, actor: admin, max_rows: 2)
    rows = csv_rows(chunks)

    assert length(rows) == 3
    assert rows |> Enum.at(1) |> Enum.at(3) == "CAP-3"
    assert rows |> Enum.at(2) |> Enum.at(3) == "CAP-2"
  end

  defp csv_rows(chunks) do
    chunks
    |> csv_body()
    |> NimbleCSV.RFC4180.parse_string(skip_headers: false)
  end

  defp csv_body(chunks) do
    chunks
    |> Enum.into([])
    |> IO.iodata_to_binary()
  end

  defp create_user!(email, password \\ "valid-pass-123") do
    Ash.create!(
      User,
      %{email: email, name: "Test User", password: password, password_confirmation: password},
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    role =
      Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "EXPORT-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: ~U[2026-05-18 08:00:00.000000Z],
      created_at_source: ~U[2026-05-18 07:00:00.000000Z],
      updated_at_source: ~U[2026-05-18 08:00:00.000000Z],
      customer_name: "Private Customer",
      customer_email: "private@example.test",
      raw_total: Decimal.new("900.00"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0"),
      payment_gateway_transaction_id: "txn_private"
    }

    Ash.create!(Order, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, %Event{} = event, %TicketType{} = ticket, attrs) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: System.unique_integer([:positive]),
      woo_variation_id: nil,
      name: "Export Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("100.00"),
      line_total: Decimal.new("100.00"),
      discount_total: Decimal.new("0"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
