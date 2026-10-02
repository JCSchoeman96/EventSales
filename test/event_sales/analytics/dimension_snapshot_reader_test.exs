defmodule EventSales.Analytics.DimensionSnapshotReaderTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.DimensionSnapshotReader
  alias EventSales.Analytics.Resources.{EventAggregateSnapshot, EventDimensionAggregateSnapshot}
  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  @refreshed_at ~U[2026-05-22 10:00:00.000000Z]
  @forbidden_pii_keys ~w(
    customer_name customer_email order_number payment_method
    payment_gateway_transaction_id raw_payload
  )

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Dimension Reader Event"})
    admin = create_admin!()

    %{source: source, event: event, admin: admin}
  end

  test "reads all dimension kinds with multi-currency grouping and stable ordering", %{
    source: source,
    event: event,
    admin: admin
  } do
    ticket_a = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    ticket_b = SalesHelpers.create_ticket_type!(event, %{name: "VIP", active: false})

    seed_ready_v2!(event, "ZAR", gross_qty: 4, refreshed_at: @refreshed_at)
    seed_ready_v2!(event, "USD", gross_qty: 1, refreshed_at: @refreshed_at)

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket_b.id,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("11.00"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket_a.id,
      gross_ticket_quantity: 3,
      gross_ticket_value: Decimal.new("33.00"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :source_product, %{
      currency: "ZAR",
      source_system_id: source.id,
      woo_product_id: 100,
      gross_ticket_quantity: 4,
      gross_ticket_value: Decimal.new("44.00"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :source_variation, %{
      currency: "ZAR",
      source_system_id: source.id,
      woo_product_id: 100,
      woo_variation_id: 200,
      gross_ticket_quantity: 4,
      gross_ticket_value: Decimal.new("44.00"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :ticket_type, %{
      currency: "USD",
      ticket_type_id: ticket_a.id,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("9.00"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :source_product, %{
      currency: "USD",
      source_system_id: source.id,
      woo_product_id: 101,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("9.00"),
      refreshed_at: @refreshed_at
    })

    assert {:ok, result} = DimensionSnapshotReader.list_for_event(event.id, actor: admin)
    assert result.pii_visibility == :none
    assert result.revenue_visible?
    refute_map_contains_pii_keys!(result)

    currencies_by_code = Map.new(result.currencies, &{&1.currency, &1})
    zar = Map.fetch!(currencies_by_code, "ZAR")
    _usd = Map.fetch!(currencies_by_code, "USD")
    assert Enum.map(result.currencies, & &1.currency) == Enum.sort(Map.keys(currencies_by_code))

    tickets_by_id = Map.new(zar.dimensions.ticket_type, &{&1.ticket_type_id, &1})
    ga = Map.fetch!(tickets_by_id, ticket_a.id)
    vip = Map.fetch!(tickets_by_id, ticket_b.id)
    assert ga.ticket_type_name == "GA"
    assert vip.active == false
    assert vip.ticket_type_name == "VIP"

    assert Enum.map(zar.dimensions.ticket_type, & &1.ticket_type_id) ==
             Enum.sort([ticket_a.id, ticket_b.id])

    assert [%{woo_product_id: 100, source_system_name: name}] = zar.dimensions.source_product
    assert is_binary(name)

    assert [%{woo_variation_id: 200}] = zar.dimensions.source_variation
    refute Map.has_key?(result, :total_gross_ticket_value)
  end

  test "optional dimension_kind filter returns one family", %{
    source: source,
    event: event,
    admin: admin
  } do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    seed_ready_v2!(event, "ZAR", gross_qty: 1, refreshed_at: @refreshed_at)

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :source_product, %{
      currency: "ZAR",
      source_system_id: source.id,
      woo_product_id: 501,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00"),
      refreshed_at: @refreshed_at
    })

    assert {:ok, filtered} =
             DimensionSnapshotReader.list_for_event(event.id,
               actor: admin,
               dimension_kind: :ticket_type
             )

    bucket = hd(filtered.currencies)
    assert length(bucket.dimensions.ticket_type) == 1
    assert bucket.dimensions.source_product == []
    assert bucket.dimensions.source_variation == []
  end

  test "optional source_product filter returns one family", %{
    source: source,
    event: event,
    admin: admin
  } do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    seed_ready_v2!(event, "ZAR", gross_qty: 1, refreshed_at: @refreshed_at)

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :source_product, %{
      currency: "ZAR",
      source_system_id: source.id,
      woo_product_id: 502,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00"),
      refreshed_at: @refreshed_at
    })

    assert {:ok, filtered} =
             DimensionSnapshotReader.list_for_event(event.id,
               actor: admin,
               dimension_kind: :source_product
             )

    bucket = hd(filtered.currencies)
    assert length(bucket.dimensions.source_product) == 1
    assert bucket.dimensions.ticket_type == []
    assert bucket.dimensions.source_variation == []
  end

  test "filtered source_variation on product-only projection succeeds when readiness families exist",
       %{source: source, event: event, admin: admin} do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    seed_ready_v2!(event, "ZAR", gross_qty: 1, refreshed_at: @refreshed_at)

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :source_product, %{
      currency: "ZAR",
      source_system_id: source.id,
      woo_product_id: 777,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00"),
      refreshed_at: @refreshed_at
    })

    assert {:ok, result} =
             DimensionSnapshotReader.list_for_event(event.id,
               actor: admin,
               dimension_kind: :source_variation
             )

    assert hd(result.currencies).dimensions.source_variation == []
  end

  test "refresh-backed fixture matches reader output", %{
    source: source,
    event: event,
    admin: admin
  } do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Refresh Ticket"})
    order = create_order!(source, :completed)

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 601,
      quantity: 2,
      line_total: Decimal.new("20.00"),
      line_total_tax: Decimal.new("2.00")
    )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    assert {:ok, result} = DimensionSnapshotReader.list_for_event(event.id, actor: admin)
    bucket = hd(result.currencies)

    assert length(bucket.dimensions.ticket_type) == 1
    assert length(bucket.dimensions.source_product) == 1
    assert length(bucket.dimensions.source_variation) == 1
    assert hd(bucket.dimensions.ticket_type).ticket_type_id == ticket.id
    assert hd(bucket.dimensions.source_product).woo_product_id == 501
    assert hd(bucket.dimensions.source_variation).woo_variation_id == 601
    assert hd(bucket.dimensions.source_product).source_system_id == source.id
  end

  test "no canonical v2 snapshots returns miss", %{event: event, admin: admin} do
    assert :miss = DimensionSnapshotReader.list_for_event(event.id, actor: admin)
  end

  test "unknown event id returns not_found for authorized admin", %{admin: admin} do
    unknown_id = Ecto.UUID.generate()
    assert :not_found = DimensionSnapshotReader.list_for_event(unknown_id, actor: admin)
  end

  test "invalid uuid returns before authorization" do
    assert {:error, {:invalid_uuid, :event_id}} =
             DimensionSnapshotReader.list_for_event("bad-id", actor: nil)
  end

  test "invalid dimension kind is rejected", %{event: event, admin: admin} do
    assert {:error, :invalid_dimension_kind} =
             DimensionSnapshotReader.list_for_event(event.id,
               actor: admin,
               dimension_kind: :bogus
             )
  end

  test "generation mismatch fails closed", %{source: source, event: event, admin: admin} do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    seed_ready_v2!(event, "ZAR", gross_qty: 1, refreshed_at: @refreshed_at)

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00"),
      refreshed_at: DateTime.add(@refreshed_at, 1, :second)
    })

    seed_dimension!(event, :source_product, %{
      currency: "ZAR",
      source_system_id: source.id,
      woo_product_id: 1,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00"),
      refreshed_at: @refreshed_at
    })

    assert {:error, :snapshot_not_ready} =
             DimensionSnapshotReader.list_for_event(event.id, actor: admin)
  end

  test "orphan dimension currency fails closed", %{source: source, event: event, admin: admin} do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    seed_ready_v2!(event, "ZAR", gross_qty: 1, refreshed_at: @refreshed_at)

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :source_product, %{
      currency: "ZAR",
      source_system_id: source.id,
      woo_product_id: 1,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("10.00"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :ticket_type, %{
      currency: "USD",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("5.00"),
      refreshed_at: @refreshed_at
    })

    assert {:error, :snapshot_not_ready} =
             DimensionSnapshotReader.list_for_event(event.id, actor: admin)
  end

  test "positive gross without required families is not ready", %{event: event, admin: admin} do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    seed_ready_v2!(event, "ZAR", gross_qty: 3, refreshed_at: @refreshed_at)

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 3,
      gross_ticket_value: Decimal.new("30.00"),
      refreshed_at: @refreshed_at
    })

    assert {:error, :snapshot_not_ready} =
             DimensionSnapshotReader.list_for_event(event.id, actor: admin)
  end

  test "gross quantity only on event requires ticket_type and source_product families", %{
    event: event,
    admin: admin
  } do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    seed_ready_v2!(event, "ZAR",
      gross_qty: 2,
      refund_qty: 0,
      gross_value: Decimal.new("0"),
      refund_value: Decimal.new("0"),
      refreshed_at: @refreshed_at
    )

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 2,
      refund_ticket_quantity: 0,
      gross_ticket_value: Decimal.new("0"),
      refund_ticket_value: Decimal.new("0"),
      refreshed_at: @refreshed_at
    })

    assert {:error, :snapshot_not_ready} =
             DimensionSnapshotReader.list_for_event(event.id, actor: admin)
  end

  test "visible caller receives derived net quantities and money fields", %{
    source: source,
    event: event,
    admin: admin
  } do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    seed_ready_v2!(event, "ZAR",
      gross_qty: 3,
      refund_qty: 1,
      gross_value: Decimal.new("90"),
      refund_value: Decimal.new("20"),
      refreshed_at: @refreshed_at
    )

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 3,
      refund_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("90"),
      refund_ticket_value: Decimal.new("20"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :source_product, %{
      currency: "ZAR",
      source_system_id: source.id,
      woo_product_id: 601,
      gross_ticket_quantity: 3,
      refund_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("90"),
      refund_ticket_value: Decimal.new("20"),
      refreshed_at: @refreshed_at
    })

    assert {:ok, result} = DimensionSnapshotReader.list_for_event(event.id, actor: admin)
    row = hd(hd(result.currencies).dimensions.ticket_type)

    assert row.gross_ticket_quantity == 3
    assert row.refund_ticket_quantity == 1
    assert row.net_ticket_quantity == 2
    assert is_integer(row.gross_ticket_quantity)
    assert row.gross_ticket_value == Decimal.new("90")
    assert row.refund_ticket_value == Decimal.new("20")
    assert row.net_ticket_value == Decimal.new("70")
    assert row.average_ticket_value == Decimal.new("35")
  end

  test "value-only refund value derives net and ATV", %{
    source: source,
    event: event,
    admin: admin
  } do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    seed_ready_v2!(event, "ZAR",
      gross_qty: 2,
      refund_qty: 0,
      gross_value: Decimal.new("100"),
      refund_value: Decimal.new("25"),
      refreshed_at: @refreshed_at
    )

    for kind <- [:ticket_type, :source_product] do
      attrs =
        %{
          currency: "ZAR",
          gross_ticket_quantity: 2,
          refund_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("100"),
          refund_ticket_value: Decimal.new("25"),
          refreshed_at: @refreshed_at
        }
        |> Map.merge(
          case kind do
            :ticket_type -> %{ticket_type_id: ticket.id}
            :source_product -> %{source_system_id: source.id, woo_product_id: 602}
          end
        )

      seed_dimension!(event, kind, attrs)
    end

    assert {:ok, result} = DimensionSnapshotReader.list_for_event(event.id, actor: admin)
    row = hd(hd(result.currencies).dimensions.ticket_type)
    assert row.net_ticket_quantity == 2
    assert row.net_ticket_value == Decimal.new("75")
    assert row.average_ticket_value == Decimal.new("37.5")
  end

  test "over-refund row preserves negative net and positive ATV magnitude", %{
    source: source,
    event: event,
    admin: admin
  } do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    seed_ready_v2!(event, "ZAR",
      gross_qty: 1,
      refund_qty: 2,
      gross_value: Decimal.new("50"),
      refund_value: Decimal.new("120"),
      refreshed_at: @refreshed_at
    )

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 1,
      refund_ticket_quantity: 2,
      gross_ticket_value: Decimal.new("50"),
      refund_ticket_value: Decimal.new("120"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :source_product, %{
      currency: "ZAR",
      source_system_id: source.id,
      woo_product_id: 603,
      gross_ticket_quantity: 1,
      refund_ticket_quantity: 2,
      gross_ticket_value: Decimal.new("50"),
      refund_ticket_value: Decimal.new("120"),
      refreshed_at: @refreshed_at
    })

    assert {:ok, result} = DimensionSnapshotReader.list_for_event(event.id, actor: admin)
    row = hd(hd(result.currencies).dimensions.ticket_type)
    assert row.net_ticket_quantity == -1
    assert row.net_ticket_value == Decimal.new("-70")
    assert row.average_ticket_value == Decimal.new("70")
  end

  test "zero net quantity yields nil average ticket value on rows", %{
    source: source,
    event: event,
    admin: admin
  } do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    seed_ready_v2!(event, "ZAR",
      gross_qty: 2,
      refund_qty: 2,
      gross_value: Decimal.new("40"),
      refund_value: Decimal.new("10"),
      refreshed_at: @refreshed_at
    )

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 2,
      refund_ticket_quantity: 2,
      gross_ticket_value: Decimal.new("40"),
      refund_ticket_value: Decimal.new("10"),
      refreshed_at: @refreshed_at
    })

    seed_dimension!(event, :source_product, %{
      currency: "ZAR",
      source_system_id: source.id,
      woo_product_id: 604,
      gross_ticket_quantity: 2,
      refund_ticket_quantity: 2,
      gross_ticket_value: Decimal.new("40"),
      refund_ticket_value: Decimal.new("10"),
      refreshed_at: @refreshed_at
    })

    assert {:ok, result} = DimensionSnapshotReader.list_for_event(event.id, actor: admin)
    row = hd(hd(result.currencies).dimensions.ticket_type)
    assert row.net_ticket_quantity == 0
    assert row.average_ticket_value == nil
  end

  test "value-only refund on event requires ticket_type and source_product families", %{
    event: event,
    admin: admin
  } do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    seed_ready_v2!(event, "ZAR",
      gross_qty: 0,
      refund_qty: 0,
      gross_value: Decimal.new("0"),
      refund_value: Decimal.new("25"),
      refreshed_at: @refreshed_at
    )

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 0,
      refund_ticket_quantity: 0,
      gross_ticket_value: Decimal.new("0"),
      refund_ticket_value: Decimal.new("25"),
      refreshed_at: @refreshed_at
    })

    assert {:error, :snapshot_not_ready} =
             DimensionSnapshotReader.list_for_event(event.id, actor: admin)
  end

  test "refund quantity only on event requires ticket_type and source_product families", %{
    event: event,
    admin: admin
  } do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    seed_ready_v2!(event, "ZAR",
      gross_qty: 0,
      refund_qty: 1,
      gross_value: Decimal.new("0"),
      refund_value: Decimal.new("0"),
      refreshed_at: @refreshed_at
    )

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 0,
      refund_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("0"),
      refund_ticket_value: Decimal.new("0"),
      refreshed_at: @refreshed_at
    })

    assert {:error, :snapshot_not_ready} =
             DimensionSnapshotReader.list_for_event(event.id, actor: admin)
  end

  test "gross value only on event requires required families", %{event: event, admin: admin} do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    seed_ready_v2!(event, "ZAR",
      gross_qty: 0,
      refund_qty: 0,
      gross_value: Decimal.new("15"),
      refund_value: Decimal.new("0"),
      refreshed_at: @refreshed_at
    )

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 0,
      gross_ticket_value: Decimal.new("15"),
      refreshed_at: @refreshed_at
    })

    assert {:error, :snapshot_not_ready} =
             DimensionSnapshotReader.list_for_event(event.id, actor: admin)
  end

  test "filtered ticket_type still fails when source_product family missing", %{
    event: event,
    admin: admin
  } do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    seed_ready_v2!(event, "ZAR", gross_qty: 2, refreshed_at: @refreshed_at)

    seed_dimension!(event, :ticket_type, %{
      currency: "ZAR",
      ticket_type_id: ticket.id,
      gross_ticket_quantity: 2,
      gross_ticket_value: Decimal.new("20.00"),
      refreshed_at: @refreshed_at
    })

    assert {:error, :snapshot_not_ready} =
             DimensionSnapshotReader.list_for_event(event.id,
               actor: admin,
               dimension_kind: :ticket_type
             )
  end

  test "zero gross with no dimension rows returns successful empty bucket", %{
    event: event,
    admin: admin
  } do
    seed_ready_v2!(event, "ZAR", gross_qty: 0, refreshed_at: @refreshed_at)

    assert {:ok, result} = DimensionSnapshotReader.list_for_event(event.id, actor: admin)
    bucket = hd(result.currencies)

    assert bucket.dimensions.ticket_type == []
    assert bucket.dimensions.source_product == []
    assert bucket.dimensions.source_variation == []
  end

  test "projection and catalogue query counts stay flat as row cardinality grows", %{
    source: source,
    event: event,
    admin: admin
  } do
    classified =
      for row_count <- [1, 50, 200] do
        cleanup_dimensions!(event.id)
        seed_projection_rows!(event, source, row_count)

        {_result, queries} =
          capture_queries(fn ->
            DimensionSnapshotReader.list_for_event(event.id, actor: admin)
          end)

        projection_catalog_query_counts(queries)
      end

    first = hd(classified)

    for counts <- classified do
      assert counts == first
      assert_reader_projection_catalog_bounds!(counts)
    end
  end

  test "catalogue enrichment uses one TicketType and one SourceSystem query for multi-currency output",
       %{source: source, event: event, admin: admin} do
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Multi Currency"})
    seed_multi_currency_projection!(event, source, ticket)

    {_result, queries} =
      capture_queries(fn ->
        DimensionSnapshotReader.list_for_event(event.id, actor: admin)
      end)

    counts = projection_catalog_query_counts(queries)
    assert_reader_projection_catalog_bounds!(counts)
    refute queries == []
  end

  defp seed_multi_currency_projection!(event, source, ticket) do
    for {currency, product_id, variation_id} <- [
          {"ZAR", 801, 901},
          {"USD", 802, 902}
        ] do
      seed_ready_v2!(event, currency, gross_qty: 2, refreshed_at: @refreshed_at)

      seed_dimension!(event, :ticket_type, %{
        currency: currency,
        ticket_type_id: ticket.id,
        gross_ticket_quantity: 2,
        gross_ticket_value: Decimal.new("20.00"),
        refreshed_at: @refreshed_at
      })

      seed_dimension!(event, :source_product, %{
        currency: currency,
        source_system_id: source.id,
        woo_product_id: product_id,
        gross_ticket_quantity: 2,
        gross_ticket_value: Decimal.new("20.00"),
        refreshed_at: @refreshed_at
      })

      seed_dimension!(event, :source_variation, %{
        currency: currency,
        source_system_id: source.id,
        woo_product_id: product_id,
        woo_variation_id: variation_id,
        gross_ticket_quantity: 2,
        gross_ticket_value: Decimal.new("20.00"),
        refreshed_at: @refreshed_at
      })
    end
  end

  defp seed_projection_rows!(event, source, row_count) do
    refreshed_at = @refreshed_at

    seed_ready_v2!(event, "ZAR",
      gross_qty: row_count,
      refund_qty: 1,
      gross_value: Decimal.new("#{row_count}.00"),
      refund_value: Decimal.new("0.50"),
      refreshed_at: refreshed_at
    )

    batch_id = System.unique_integer([:positive])

    for index <- 1..row_count do
      ticket = SalesHelpers.create_ticket_type!(event, %{name: "Ticket #{batch_id}-#{index}"})

      seed_dimension!(event, :ticket_type, %{
        currency: "ZAR",
        ticket_type_id: ticket.id,
        gross_ticket_quantity: 1,
        refund_ticket_quantity: 0,
        gross_ticket_value: Decimal.new("1.00"),
        refund_ticket_value: Decimal.new("0"),
        refreshed_at: refreshed_at
      })
    end

    seed_dimension!(event, :source_product, %{
      currency: "ZAR",
      source_system_id: source.id,
      woo_product_id: 9000 + row_count,
      gross_ticket_quantity: row_count,
      refund_ticket_quantity: 1,
      gross_ticket_value: Decimal.new("#{row_count}.00"),
      refund_ticket_value: Decimal.new("0.50"),
      refreshed_at: refreshed_at
    })
  end

  defp create_order!(source, status, opts \\ []) do
    timestamp = ~U[2026-05-17 08:00:00.000000Z]

    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "dim-reader-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: timestamp,
      created_at_source: ~U[2026-05-17 07:00:00.000000Z],
      updated_at_source: timestamp,
      raw_total: Decimal.new("0"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0")
    }

    Ash.create!(Order, Map.merge(defaults, Map.new(opts)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, event, ticket, opts \\ []) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: System.unique_integer([:positive]),
      woo_variation_id: nil,
      name: "Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("10.00"),
      line_total: Decimal.new("10.00"),
      line_total_tax: Decimal.new("0.00"),
      discount_total: Decimal.new("0.00"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(opts)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp seed_ready_v2!(event, currency, opts) do
    gross_qty = Keyword.fetch!(opts, :gross_qty)
    refreshed_at = Keyword.fetch!(opts, :refreshed_at)
    refund_qty = Keyword.get(opts, :refund_qty, 0)

    gross_value =
      Keyword.get_lazy(opts, :gross_value, fn ->
        if gross_qty > 0, do: Decimal.new("100"), else: Decimal.new("0")
      end)

    refund_value = Keyword.get(opts, :refund_value, Decimal.new("0"))

    Ash.create!(
      EventAggregateSnapshot,
      %{
        event_id: event.id,
        total_sold: gross_qty,
        total_revenue: Decimal.new("0"),
        today_sold: 0,
        today_revenue: Decimal.new("0"),
        gross_ticket_quantity: gross_qty,
        refund_ticket_quantity: refund_qty,
        gross_ticket_value: gross_value,
        refund_ticket_value: refund_value,
        recognised_order_count: max(gross_qty, 1),
        currency: currency,
        business_timezone: "Africa/Johannesburg",
        refreshed_at: refreshed_at,
        source_row_count: 0,
        snapshot_version: 2
      },
      action: :create_snapshot,
      domain: EventSales.Analytics
    )
  end

  defp seed_dimension!(event, kind, attrs) do
    base = %{
      event_id: event.id,
      dimension_kind: kind,
      gross_ticket_quantity: 0,
      refund_ticket_quantity: 0,
      gross_ticket_value: Decimal.new("0"),
      refund_ticket_value: Decimal.new("0"),
      refreshed_at: @refreshed_at
    }

    Ash.create!(EventDimensionAggregateSnapshot, Map.merge(base, Map.new(attrs)),
      action: :create_snapshot,
      domain: EventSales.Analytics
    )
  end

  defp cleanup_dimensions!(event_id) do
    import Ecto.Query

    alias EventSales.Catalog.Resources.TicketType

    Repo.delete_all(from(d in EventDimensionAggregateSnapshot, where: d.event_id == ^event_id))
    Repo.delete_all(from(e in EventAggregateSnapshot, where: e.event_id == ^event_id))
    Repo.delete_all(from(t in TicketType, where: t.event_id == ^event_id))
  end

  defp create_admin! do
    user =
      Ash.create!(
        User,
        %{
          email: "dimension-reader-admin-#{System.unique_integer([:positive])}@example.com",
          name: "Dimension Reader Admin",
          password: "valid-pass-123",
          password_confirmation: "valid-pass-123"
        },
        action: :register_with_password,
        domain: Accounts
      )

    role =
      Role
      |> Ash.Query.filter(name == :admin)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: :admin}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )

    user
  end

  defp refute_map_contains_pii_keys!(value) do
    keys =
      value
      |> collect_string_keys([])
      |> MapSet.new()

    for key <- @forbidden_pii_keys do
      refute MapSet.member?(keys, key)
    end

    :ok
  end

  defp collect_string_keys(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn
      {key, %DateTime{}}, keys ->
        [to_string(key) | keys]

      {key, %Decimal{}}, keys ->
        [to_string(key) | keys]

      {key, nested}, keys when is_map(nested) or is_list(nested) ->
        collect_string_keys(nested, [to_string(key) | keys])

      {key, _}, keys ->
        [to_string(key) | keys]
    end)
  end

  defp collect_string_keys(list, acc) when is_list(list) do
    Enum.reduce(list, acc, fn item, keys -> collect_string_keys(item, keys) end)
  end

  defp collect_string_keys(_other, acc), do: acc

  defp capture_queries(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, {test_pid, id} ->
          send(test_pid, {id, inspect(metadata.query)})
        end,
        {parent, handler_id}
      )

    try do
      {fun.(), collect_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> collect_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp projection_catalog_query_counts(queries) do
    relevant =
      Enum.reject(queries, fn query ->
        String.match?(query, ~r/\b(BEGIN|COMMIT|ROLLBACK)\b/i)
      end)

    %{
      event_v2: count_table_queries(relevant, "analytics_event_aggregate_snapshots"),
      dimensions: count_table_queries(relevant, "analytics_event_dimension_aggregate_snapshots"),
      ticket_types: count_table_queries(relevant, "catalog_ticket_types"),
      source_systems: count_table_queries(relevant, "catalog_source_systems"),
      catalog_events: count_table_queries(relevant, "catalog_events"),
      sales_orders: count_table_queries(relevant, "sales_orders"),
      sales_order_items: count_table_queries(relevant, "sales_order_items"),
      sales_refunds: count_table_queries(relevant, "sales_refunds"),
      sales_refund_lines: count_table_queries(relevant, "sales_refund_lines"),
      product_mappings: count_table_queries(relevant, "catalog_product_mappings")
    }
  end

  defp assert_reader_projection_catalog_bounds!(counts) do
    assert counts.event_v2 <= 1
    assert counts.dimensions <= 1
    assert counts.ticket_types <= 1
    assert counts.source_systems <= 1
    assert counts.sales_orders == 0
    assert counts.sales_order_items == 0
    assert counts.sales_refunds == 0
    assert counts.sales_refund_lines == 0
    assert counts.product_mappings == 0
  end

  defp count_table_queries(queries, table) do
    Enum.count(queries, &String.contains?(&1, table))
  end
end
