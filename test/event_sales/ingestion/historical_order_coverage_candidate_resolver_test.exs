defmodule EventSales.Ingestion.HistoricalOrderCoverageCandidateResolverTest do
  use EventSales.DataCase, async: true

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion.HistoricalOrderCoverageCandidateResolver
  alias EventSales.Sales.Resources.Order
  alias EventSales.TestSupport.SalesHelpers

  test "includes every persisted Event ID" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    event = create_event!(source, 10_001)

    assert {:ok, [event_id]} =
             resolve(order, snapshot([item(event_id: event.id)]))

    assert event_id == event.id
  end

  test "unions persisted Event IDs from BEFORE and AFTER" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    event_a = create_event!(source, 10_002)
    event_b = create_event!(source, 10_003)

    assert {:ok, event_ids} =
             resolve(
               order,
               snapshot([item(event_id: event_a.id)]),
               snapshot([item(event_id: event_b.id)])
             )

    assert event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "resolves an exact source Event when its TicketType is unresolved" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    event = create_event!(source, 10_004)

    assert {:ok, [event_id]} =
             resolve(
               order,
               snapshot([]),
               snapshot([
                 item(
                   source_tickera_event_id: 10_004,
                   attribution_status_reason: :source_ticket_type_not_found
                 )
               ])
             )

    assert event_id == event.id
  end

  test "does not create a candidate for a missing source Event" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)

    assert {:ok, []} =
             resolve(
               order,
               snapshot([
                 item(
                   source_tickera_event_id: 10_005,
                   attribution_status_reason: :source_event_not_found
                 )
               ])
             )
  end

  test "resolves a source Event that appears before a later Order mutation" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)

    before =
      snapshot([
        item(
          source_tickera_event_id: 10_006,
          attribution_status_reason: :source_event_not_found
        )
      ])

    assert {:ok, []} = resolve(order, nil, before)

    event = create_event!(source, 10_006)

    assert {:ok, [event_id]} = resolve(order, before, before)
    assert event_id == event.id
  end

  test "excludes invalid source identity even when the exact Event exists" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    _event = create_event!(source, 10_007)

    assert {:ok, []} =
             resolve(
               order,
               snapshot([
                 item(
                   source_tickera_event_id: 10_007,
                   attribution_status_reason: :invalid_source_tickera_event_id
                 )
               ])
             )
  end

  test "excludes conflicting source identity without persisted attribution" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    _event = create_event!(source, 10_008)

    assert {:ok, []} =
             resolve(
               order,
               snapshot([
                 item(
                   source_tickera_event_id: 10_008,
                   attribution_status_reason: :source_event_identity_conflict
                 )
               ])
             )
  end

  test "retains persisted attribution despite a conflicting source identity" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    event_a = create_event!(source, 10_009)
    _event_b = create_event!(source, 10_010)

    assert {:ok, [event_id]} =
             resolve(
               order,
               snapshot([
                 item(
                   event_id: event_a.id,
                   source_tickera_event_id: 10_010,
                   attribution_status_reason: :source_event_identity_conflict
                 )
               ])
             )

    assert event_id == event_a.id
  end

  test "retains a BEFORE source candidate when the source is removed AFTER" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    event = create_event!(source, 10_011)

    assert {:ok, [event_id]} =
             resolve(
               order,
               snapshot([
                 item(
                   source_tickera_event_id: 10_011,
                   attribution_status_reason: :source_event_not_found
                 )
               ]),
               snapshot([])
             )

    assert event_id == event.id
  end

  test "unions source X and source Y" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    event_x = create_event!(source, 10_012)
    event_y = create_event!(source, 10_013)

    assert {:ok, event_ids} =
             resolve(
               order,
               snapshot([item(source_tickera_event_id: 10_012)]),
               snapshot([item(source_tickera_event_id: 10_013)])
             )

    assert event_ids == Enum.sort([event_x.id, event_y.id])
  end

  test "unions source IDs on separate lines" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    event_x = create_event!(source, 10_014)
    event_y = create_event!(source, 10_015)

    assert {:ok, event_ids} =
             resolve(
               order,
               snapshot([
                 item(source_tickera_event_id: 10_014),
                 item(source_tickera_event_id: 10_015)
               ])
             )

    assert event_ids == Enum.sort([event_x.id, event_y.id])
  end

  test "unions persisted Event A with latent source Event B" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    event_a = create_event!(source, 10_016)
    event_b = create_event!(source, 10_017)

    assert {:ok, event_ids} =
             resolve(
               order,
               snapshot([
                 item(event_id: event_a.id),
                 item(
                   source_tickera_event_id: 10_017,
                   attribution_status_reason: :source_ticket_type_not_found
                 )
               ])
             )

    assert event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "unions explicit reconciliation Event with latent source Events" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    event_x = create_event!(source, 10_018)
    event_y = create_event!(source, 10_019)
    event_t = create_event!(source, 10_020)

    assert {:ok, event_ids} =
             resolve(
               order,
               snapshot([
                 item(source_tickera_event_id: 10_018),
                 item(source_tickera_event_id: 10_019)
               ]),
               snapshot([]),
               [event_t.id]
             )

    assert event_ids == Enum.sort([event_t.id, event_x.id, event_y.id])
  end

  test "deduplicates and sorts canonical UUID evidence" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    event_a = create_event!(source, 10_021)
    event_b = create_event!(source, 10_022)

    assert {:ok, event_ids} =
             resolve(
               order,
               snapshot([item(event_id: String.upcase(event_a.id))]),
               snapshot([
                 item(event_id: event_a.id),
                 item(source_tickera_event_id: 10_022)
               ]),
               [String.upcase(event_b.id), event_a.id]
             )

    assert event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "rejects a malformed explicit Event UUID" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)

    assert {:error, :invalid_explicit_event_id} =
             resolve(order, snapshot([]), snapshot([]), ["not-a-uuid"])
  end

  test "returns no candidate without source identity or persisted attribution" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)

    assert {:ok, []} = resolve(order, snapshot([item()]))
  end

  test "does not derive a candidate from ProductMapping alone" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)
    event = create_event!(source, 10_023)
    ticket = SalesHelpers.create_variation_ticket_type!(event, 90_001, 90_002)

    Ash.create!(
      ProductMapping,
      %{
        source_system_id: source.id,
        event_id: event.id,
        ticket_type_id: ticket.id,
        woo_product_id: 90_001,
        woo_variation_id: 90_002,
        original_label: "Ticket",
        current_label: "Ticket",
        active: true
      },
      action: :create,
      domain: Catalog
    )

    assert {:ok, []} =
             resolve(order, snapshot([item(woo_product_id: 90_001, woo_variation_id: 90_002)]))
  end

  test "rejects an invalid durable Order" do
    assert {:error, :invalid_order} =
             HistoricalOrderCoverageCandidateResolver.resolve(
               %Order{},
               nil,
               snapshot([])
             )
  end

  test "rejects an invalid historical snapshot" do
    source = SalesHelpers.create_source_system!()
    order = create_order!(source)

    assert {:error, :invalid_historical_order_snapshot} =
             resolve(order, %{order_items: :not_a_list}, snapshot([]))
  end

  defp resolve(order, after_snapshot),
    do: HistoricalOrderCoverageCandidateResolver.resolve(order, nil, after_snapshot)

  defp resolve(order, before_snapshot, after_snapshot),
    do: HistoricalOrderCoverageCandidateResolver.resolve(order, before_snapshot, after_snapshot)

  defp resolve(order, before_snapshot, after_snapshot, explicit_event_ids),
    do:
      HistoricalOrderCoverageCandidateResolver.resolve(
        order,
        before_snapshot,
        after_snapshot,
        explicit_event_ids
      )

  defp create_order!(source),
    do: SalesHelpers.create_order_from_fixture!(:order_completed, source)

  defp create_event!(source, external_event_id),
    do:
      SalesHelpers.create_event!(source, %{
        external_event_id: external_event_id,
        external_event_kind: :tickera_event
      })

  defp snapshot(order_items), do: %{order_items: order_items}

  defp item(attrs \\ []) do
    defaults = %{
      event_id: nil,
      source_tickera_event_id: nil,
      attribution_status_reason: nil
    }

    Map.merge(defaults, Map.new(attrs))
  end
end
