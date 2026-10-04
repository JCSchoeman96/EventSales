defmodule EventSales.Analytics.PeriodProjectionRefreshTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Analytics
  alias EventSales.Analytics.PeriodProjectionInvalidator
  alias EventSales.Analytics.PeriodProjectionRefresh

  alias EventSales.Analytics.Resources.{
    AnalyticsContributionFact,
    EventDimensionPeriodAggregateSnapshot,
    EventPeriodAggregateSnapshot
  }

  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Ingestion.HistoricalOrderMutationDetector
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.SalesHelpers

  @sale_at ~U[2026-07-01 10:15:00.123456Z]
  @refund_at ~U[2026-07-03 12:45:00.654321Z]
  @refreshed_at ~U[2026-07-10 10:00:00.000000Z]

  test "rebuilds only pending hour and Johannesburg day buckets from sale and refund facts" do
    {source, event, order, item} = source_fixture!()
    refund_line = create_refund!(source, order, item)
    snapshot = capture!(order)

    invalidate_order!(nil, snapshot)
    unaffected_seed = seed_unaffected_current_bucket!(event.id)

    unaffected_dimension =
      Ash.create!(
        EventDimensionPeriodAggregateSnapshot,
        Map.merge(
          Map.take(unaffected_seed, [
            :event_id,
            :currency,
            :bucket_kind,
            :bucket_timezone,
            :bucket_start_utc,
            :bucket_end_utc,
            :gross_ticket_quantity,
            :gross_ticket_value,
            :generation_id,
            :semantic_version,
            :coverage_identity,
            :projection_state,
            :refreshed_at
          ]),
          %{dimension_kind: :ticket_type, ticket_type_id: item.ticket_type_id}
        ),
        action: :create_snapshot,
        domain: Analytics
      )

    assert {:ok, _snapshots} =
             SnapshotRefresh.refresh_event(event.id, refreshed_at: @refreshed_at)

    period_rows = period_rows!(event.id)
    assert length(period_rows) == 5
    assert Enum.all?(Enum.take(period_rows, 4), &(&1.projection_state == :current))

    sale_hour = bucket!(period_rows, :utc_hour, @sale_at)
    sale_day = bucket!(period_rows, :johannesburg_day, @sale_at)
    refund_hour = bucket!(period_rows, :utc_hour, @refund_at)
    refund_day = bucket!(period_rows, :johannesburg_day, @refund_at)

    for bucket <- [sale_hour, sale_day] do
      assert bucket.gross_ticket_quantity == 2
      assert Decimal.equal?(bucket.gross_ticket_value, Decimal.new("115.00"))
      assert bucket.refund_ticket_quantity == 0
      assert Decimal.equal?(bucket.refund_ticket_value, Decimal.new("0"))
      assert bucket.projection_state == :current
    end

    for bucket <- [refund_hour, refund_day] do
      assert bucket.gross_ticket_quantity == 0
      assert Decimal.equal?(bucket.gross_ticket_value, Decimal.new("0"))
      assert bucket.refund_ticket_quantity == 1
      assert Decimal.equal?(bucket.refund_ticket_value, Decimal.new("12.00"))
      assert bucket.projection_state == :current
    end

    facts = contribution_facts!(event.id)
    assert Enum.map(facts, & &1.contribution_kind) |> Enum.sort() == [:refund, :sale]
    assert Enum.find(facts, &(&1.contribution_kind == :sale)).source_contribution_id == item.id

    assert Enum.find(facts, &(&1.contribution_kind == :refund)).source_contribution_id ==
             refund_line.id

    dimension_rows = dimension_rows!(event.id)
    assert length(dimension_rows) == 13

    persisted_attributes =
      EventDimensionPeriodAggregateSnapshot
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    assert Map.take(
             Enum.find(dimension_rows, &(&1.id == unaffected_dimension.id)),
             persisted_attributes
           ) ==
             Map.take(unaffected_dimension, persisted_attributes)

    assert Enum.all?(dimension_rows, &(&1.projection_state == :current))

    for bucket <- [sale_hour, sale_day] do
      rows = dimension_rows_for_bucket(dimension_rows, bucket)

      assert Enum.map(rows, & &1.dimension_kind) |> Enum.sort() == [
               :source_product,
               :source_variation,
               :ticket_type
             ]

      assert Enum.all?(rows, &(&1.gross_ticket_quantity == 2))
      assert Enum.all?(rows, &Decimal.equal?(&1.gross_ticket_value, Decimal.new("115.00")))
      assert Enum.all?(rows, &(&1.refund_ticket_quantity == 0))
      assert Enum.all?(rows, &Decimal.equal?(&1.refund_ticket_value, Decimal.new("0")))
      assert Enum.all?(rows, &(&1.generation_id == bucket.generation_id))
      assert Enum.all?(rows, &(&1.semantic_version == bucket.semantic_version))
      assert Enum.all?(rows, &(&1.coverage_identity == bucket.coverage_identity))
      assert Enum.all?(rows, &(&1.refreshed_at == bucket.refreshed_at))
      assert Enum.all?(rows, &(&1.source_watermark_at == bucket.source_watermark_at))
    end

    for bucket <- [refund_hour, refund_day] do
      rows = dimension_rows_for_bucket(dimension_rows, bucket)

      assert Enum.map(rows, & &1.dimension_kind) |> Enum.sort() == [
               :source_product,
               :source_variation,
               :ticket_type
             ]

      assert Enum.all?(rows, &(&1.gross_ticket_quantity == 0))
      assert Enum.all?(rows, &Decimal.equal?(&1.gross_ticket_value, Decimal.new("0")))
      assert Enum.all?(rows, &(&1.refund_ticket_quantity == 1))
      assert Enum.all?(rows, &Decimal.equal?(&1.refund_ticket_value, Decimal.new("12.00")))
      assert Enum.all?(rows, &(&1.generation_id == bucket.generation_id))
      assert Enum.all?(rows, &(&1.semantic_version == bucket.semantic_version))
      assert Enum.all?(rows, &(&1.coverage_identity == bucket.coverage_identity))
      assert Enum.all?(rows, &(&1.refreshed_at == bucket.refreshed_at))
      assert Enum.all?(rows, &(&1.source_watermark_at == bucket.source_watermark_at))
    end

    assert [replacement_generation] =
             [sale_hour, sale_day, refund_hour, refund_day]
             |> Enum.map(& &1.generation_id)
             |> Enum.uniq()

    unaffected = Enum.find(period_rows, &(&1.currency == "EUR"))
    assert unaffected.projection_state == :current
    assert unaffected.generation_id == unaffected_seed.generation_id
    refute replacement_generation == unaffected_seed.generation_id
    assert unaffected.refreshed_at == unaffected_seed.refreshed_at
    assert Decimal.equal?(unaffected.gross_ticket_value, Decimal.new("77.00"))
  end

  test "persists a value-only refund contribution with zero refund quantity" do
    {source, event, order, item} = source_fixture!()
    refund_line = create_refund!(source, order, item, refunded_quantity: 0)
    snapshot = capture!(order)

    invalidate_order!(nil, snapshot)
    assert {:ok, :ok} = refresh_transaction(event.id, @refreshed_at)

    [refund_fact] = Enum.filter(contribution_facts!(event.id), &(&1.contribution_kind == :refund))
    assert refund_fact.source_contribution_id == refund_line.id
    assert refund_fact.refund_ticket_quantity == 0
    assert Decimal.equal?(refund_fact.refund_ticket_value, Decimal.new("12.00"))

    rows = period_rows!(event.id)
    refund_hour = bucket!(rows, :utc_hour, @refund_at)
    assert refund_hour.refund_ticket_quantity == 0
    assert Decimal.equal?(refund_hour.refund_ticket_value, Decimal.new("12.00"))
    refund_dimensions = dimension_rows_for_bucket(dimension_rows!(event.id), refund_hour)
    assert length(refund_dimensions) == 3
    assert Enum.all?(refund_dimensions, &(&1.refund_ticket_quantity == 0))

    assert Enum.all?(
             refund_dimensions,
             &Decimal.equal?(&1.refund_ticket_value, Decimal.new("12.00"))
           )
  end

  test "a no-variation sale populates ticket type and product families only" do
    {_source, event, order, item} = source_fixture!()
    before_snapshot = capture!(order)

    Repo.query!(
      "UPDATE sales_order_items SET woo_variation_id = NULL WHERE id = $1::text::uuid",
      [item.id]
    )

    after_snapshot = capture!(order)
    invalidate_order!(before_snapshot, after_snapshot)

    assert {:ok, :ok} = refresh_transaction(event.id, @refreshed_at)

    rows = dimension_rows!(event.id)
    assert length(rows) == 4

    assert Enum.map(rows, & &1.dimension_kind) |> Enum.sort() == [
             :source_product,
             :source_product,
             :ticket_type,
             :ticket_type
           ]

    refute Enum.any?(rows, &(&1.dimension_kind == :source_variation))
  end

  test "exact-equal facts stay untouched while another contribution in the day changes" do
    {_source, event, order, original_item} = source_fixture!()
    before_snapshot = capture!(order)
    invalidate_order!(nil, before_snapshot)
    assert {:ok, :ok} = refresh_transaction(event.id, @refreshed_at)

    [original_before] =
      Enum.filter(contribution_facts!(event.id), &(&1.contribution_kind == :sale))

    bucket_before = bucket!(period_rows!(event.id), :utc_hour, @sale_at)

    added_item = create_second_item!(order, original_item)
    after_add_snapshot = capture!(order)

    invalidate_order!(before_snapshot, after_add_snapshot)

    assert {:ok, :ok} = refresh_transaction(event.id, DateTime.add(@refreshed_at, 1, :hour))

    sale_facts = Enum.filter(contribution_facts!(event.id), &(&1.contribution_kind == :sale))
    assert length(sale_facts) == 2
    original_after_add = Enum.find(sale_facts, &(&1.source_contribution_id == original_item.id))
    added_fact = Enum.find(sale_facts, &(&1.source_contribution_id == added_item.id))
    bucket_after_add = bucket!(period_rows!(event.id), :utc_hour, @sale_at)
    assert original_after_add.id == original_before.id
    assert original_after_add.generation_id == original_before.generation_id
    assert original_after_add.refreshed_at == original_before.refreshed_at
    assert original_after_add.updated_at == original_before.updated_at
    assert added_fact != nil
    assert bucket_after_add.projection_state == :current
    refute bucket_after_add.generation_id == bucket_before.generation_id

    assert Ash.update!(added_item, %{}, action: :remap, domain: Sales).mapping_status ==
             :pending_mapping_resolution

    after_remove_snapshot = capture!(order)

    invalidate_order!(after_add_snapshot, after_remove_snapshot)

    assert {:ok, :ok} = refresh_transaction(event.id, DateTime.add(@refreshed_at, 2, :hour))

    [remaining_fact] =
      Enum.filter(contribution_facts!(event.id), &(&1.contribution_kind == :sale))

    assert remaining_fact.source_contribution_id == original_item.id
    assert remaining_fact.id == original_before.id
    assert remaining_fact.generation_id == original_before.generation_id
    assert remaining_fact.refreshed_at == original_before.refreshed_at
    assert remaining_fact.updated_at == original_before.updated_at

    original_pending = Ash.update!(original_item, %{}, action: :remap, domain: Sales)
    assert original_pending.mapping_status == :pending_mapping_resolution
    after_all_removed_snapshot = capture!(order)

    invalidate_order!(after_remove_snapshot, after_all_removed_snapshot)

    assert {:ok, :ok} = refresh_transaction(event.id, DateTime.add(@refreshed_at, 3, :hour))
    assert Enum.filter(contribution_facts!(event.id), &(&1.contribution_kind == :sale)) == []

    current_buckets =
      period_rows!(event.id)
      |> Enum.filter(&(&1.currency == "ZAR"))

    assert length(current_buckets) == 2
    assert Enum.all?(current_buckets, &(&1.projection_state == :current))

    assert Enum.all?(current_buckets, fn bucket ->
             bucket.gross_ticket_quantity == 0 and
               Decimal.equal?(bucket.gross_ticket_value, Decimal.new("0"))
           end)

    assert dimension_rows!(event.id) == []
  end

  test "a pending day includes existing sales without replacing their unaffected hour dimensions" do
    {_source, event, order, item} = source_fixture!()
    invalidate_order!(nil, capture!(order))
    assert {:ok, :ok} = refresh_transaction(event.id, @refreshed_at)
    original_hour = bucket!(period_rows!(event.id), :utc_hour, @sale_at)
    original_dimensions = dimension_rows_for_bucket(dimension_rows!(event.id), original_hour)

    second_order =
      Ash.create!(
        Order,
        order
        |> Map.take([
          :source_system_id,
          :status,
          :currency,
          :created_at_source,
          :updated_at_source,
          :raw_total,
          :raw_discount_total,
          :raw_tax_total
        ])
        |> Map.merge(%{
          woo_order_id: System.unique_integer([:positive]),
          order_number: "unaffected-hour",
          paid_at: DateTime.add(@sale_at, 1, :hour)
        }),
        action: :create_normalized,
        domain: Sales
      )

    create_second_item!(second_order, item)
    invalidate_order!(nil, capture!(second_order))
    assert {:ok, :ok} = refresh_transaction(event.id, DateTime.add(@refreshed_at, 1, :hour))
    dimensions = dimension_rows!(event.id)
    assert dimension_rows_for_bucket(dimensions, original_hour) == original_dimensions
    day = bucket!(period_rows!(event.id), :johannesburg_day, @sale_at)
    assert day.gross_ticket_quantity == 3
    assert Enum.all?(dimension_rows_for_bucket(dimensions, day), &(&1.gross_ticket_quantity == 3))
    second_hour = bucket!(period_rows!(event.id), :utc_hour, DateTime.add(@sale_at, 1, :hour))

    assert Enum.all?(
             dimension_rows_for_bucket(dimensions, second_hour),
             &(&1.gross_ticket_quantity == 1)
           )
  end

  test "ticket type, product, and variation corrections replace the old dimensional grains" do
    {_source, event, order, item} = source_fixture!()
    before = capture!(order)
    invalidate_order!(nil, before)
    assert {:ok, :ok} = refresh_transaction(event.id, @refreshed_at)

    replacement_ticket = SalesHelpers.create_ticket_type!(event, %{name: "Corrected ticket"})

    for {field, value} <- [
          {:ticket_type_id, replacement_ticket.id},
          {:woo_product_id, 6001},
          {:woo_variation_id, 6002}
        ] do
      before = capture!(order)
      old_rows = dimension_rows!(event.id)
      cast = if field == :ticket_type_id, do: "::text::uuid", else: "::bigint"

      Repo.query!("UPDATE sales_order_items SET #{field} = $1#{cast} WHERE id = $2::text::uuid", [
        value,
        item.id
      ])

      after_snapshot = capture!(order)
      invalidate_order!(before, after_snapshot)
      assert {:ok, :ok} = refresh_transaction(event.id, @refreshed_at)
      rows = dimension_rows!(event.id)
      assert length(rows) == 6

      affected =
        case field do
          :ticket_type_id -> [:ticket_type]
          :woo_product_id -> [:source_product, :source_variation]
          :woo_variation_id -> [:source_variation]
        end

      for row <- Enum.filter(rows, &(&1.dimension_kind in affected)) do
        assert Map.fetch!(row, field) == value
      end

      refute Enum.any?(rows, fn row -> Enum.any?(old_rows, &(&1.id == row.id)) end)
    end
  end

  test "event, currency, and effective-time corrections remove old partitions" do
    {source, event, order, item} = source_fixture!()
    before = capture!(order)
    invalidate_order!(nil, before)
    assert {:ok, :ok} = refresh_transaction(event.id, @refreshed_at)
    other_event = SalesHelpers.create_event!(source, %{name: "Corrected event"})

    other_ticket =
      SalesHelpers.create_ticket_type!(other_event, %{name: "Corrected event ticket"})

    Repo.query!(
      "UPDATE sales_order_items SET event_id = $1::text::uuid, ticket_type_id = $2::text::uuid WHERE id = $3::text::uuid",
      [other_event.id, other_ticket.id, item.id]
    )

    after_event = capture!(order)
    invalidate_order!(before, after_event)
    assert {:ok, :ok} = refresh_transaction(event.id, @refreshed_at)
    assert {:ok, :ok} = refresh_transaction(other_event.id, @refreshed_at)
    assert dimension_rows!(event.id) == []
    assert length(dimension_rows!(other_event.id)) == 6

    assert Enum.all?(
             period_rows!(event.id),
             &(&1.gross_ticket_quantity == 0 and &1.projection_state == :current)
           )

    Repo.query!("UPDATE sales_orders SET currency = 'EUR' WHERE id = $1::text::uuid", [order.id])
    euro_order = Ash.get!(Order, order.id, domain: Sales)
    after_currency = capture!(euro_order)
    invalidate_order!(after_event, after_currency)
    assert {:ok, :ok} = refresh_transaction(other_event.id, @refreshed_at)
    assert Enum.all?(dimension_rows!(other_event.id), &(&1.currency == "EUR"))

    assert Enum.all?(
             Enum.filter(period_rows!(other_event.id), &(&1.currency == "ZAR")),
             &(&1.gross_ticket_quantity == 0)
           )

    corrected_at = ~U[2026-07-04 17:15:00.000000Z]

    Repo.query!("UPDATE sales_orders SET paid_at = $1 WHERE id = $2::text::uuid", [
      corrected_at,
      order.id
    ])

    corrected_order = Ash.get!(Order, order.id, domain: Sales)
    invalidate_order!(after_currency, capture!(corrected_order))
    assert {:ok, :ok} = refresh_transaction(other_event.id, @refreshed_at)
    rows = dimension_rows!(other_event.id)
    assert length(rows) == 6
    assert Enum.all?(rows, &(DateTime.compare(&1.bucket_start_utc, @sale_at) == :gt))
    assert Enum.all?(rows, &(&1.currency == "EUR" and &1.projection_state == :current))
  end

  test "voiding an active refund removes its dimensions while preserving sale dimensions" do
    {source, event, order, item} = source_fixture!()
    line = create_refund!(source, order, item)
    before = capture!(order)
    invalidate_order!(nil, before)
    assert {:ok, :ok} = refresh_transaction(event.id, @refreshed_at)
    sale_rows = Enum.filter(dimension_rows!(event.id), &(&1.gross_ticket_quantity > 0))
    assert length(dimension_rows!(event.id)) == 12

    Repo.query!("UPDATE sales_refunds SET source_state = 'voided' WHERE id = $1::text::uuid", [
      line.refund_id
    ])

    invalidate_order!(before, capture!(order))
    assert {:ok, :ok} = refresh_transaction(event.id, @refreshed_at)
    assert dimension_rows!(event.id) == sale_rows
    assert Enum.all?(period_rows!(event.id), &(&1.refund_ticket_quantity == 0))
  end

  defp source_fixture! do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Period refresh"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Ticket"})

    order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: System.unique_integer([:positive]),
          order_number: "period-refresh-#{System.unique_integer([:positive])}",
          status: :completed,
          currency: "ZAR",
          paid_at: @sale_at,
          completed_at: nil,
          created_at_source: ~U[2026-07-01 09:00:00.000000Z],
          updated_at_source: ~U[2026-07-01 10:15:01.000000Z],
          raw_total: Decimal.new("115.00"),
          raw_discount_total: Decimal.new("0"),
          raw_tax_total: Decimal.new("15.00")
        },
        action: :create_normalized,
        domain: Sales
      )

    item =
      Ash.create!(
        OrderItem,
        %{
          order_id: order.id,
          event_id: event.id,
          ticket_type_id: ticket.id,
          woo_line_item_id: 70_001,
          woo_product_id: 5001,
          woo_variation_id: 5002,
          name: "Ticket",
          quantity: 2,
          line_subtotal: Decimal.new("100.00"),
          line_total: Decimal.new("100.00"),
          line_total_tax: Decimal.new("15.00"),
          discount_total: Decimal.new("0"),
          item_kind: :ticket,
          mapping_status: :mapped
        },
        action: :create_normalized,
        domain: Sales
      )

    {source, event, order, item}
  end

  defp create_refund!(source, order, item, opts \\ []) do
    refund =
      Ash.create!(
        Refund,
        %{
          source_system_id: source.id,
          order_id: order.id,
          woo_order_id: order.woo_order_id,
          woo_refund_id: System.unique_integer([:positive]),
          currency: order.currency,
          source_state: :active,
          detail_status: :complete,
          summary_total_amount: Decimal.new("12.00"),
          header_amount: Decimal.new("0"),
          shipping_refund_amount: Decimal.new("0"),
          shipping_refund_tax: Decimal.new("0"),
          fee_refund_amount: Decimal.new("0"),
          fee_refund_tax: Decimal.new("0"),
          unallocated_header_amount: Decimal.new("0"),
          source_created_at: @refund_at
        },
        action: :create_normalized,
        domain: Sales
      )

    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: item.id,
        woo_refund_line_item_id: System.unique_integer([:positive]),
        woo_refunded_item_id: item.woo_line_item_id,
        woo_product_id: item.woo_product_id,
        woo_variation_id: item.woo_variation_id,
        refunded_quantity: Keyword.get(opts, :refunded_quantity, 1),
        refund_subtotal_amount: Decimal.new("10.00"),
        refund_total_amount: Decimal.new("10.00"),
        refund_total_tax: Decimal.new("2.00"),
        binding_reason: nil,
        validation_reason: nil
      },
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_second_item!(order, original_item) do
    Ash.create!(
      OrderItem,
      %{
        order_id: order.id,
        event_id: original_item.event_id,
        ticket_type_id: original_item.ticket_type_id,
        woo_line_item_id: 70_002,
        woo_product_id: original_item.woo_product_id,
        woo_variation_id: original_item.woo_variation_id,
        name: "Second ticket",
        quantity: 1,
        line_subtotal: Decimal.new("25.00"),
        line_total: Decimal.new("25.00"),
        line_total_tax: Decimal.new("3.75"),
        discount_total: Decimal.new("0"),
        item_kind: :ticket,
        mapping_status: :mapped
      },
      action: :create_normalized,
      domain: Sales
    )
  end

  defp capture!(order) do
    assert {:ok, snapshot} = HistoricalOrderMutationDetector.capture(order)
    snapshot
  end

  defp refresh_transaction(event_id, refreshed_at) do
    Repo.transaction(fn ->
      case PeriodProjectionRefresh.refresh_pending_event(event_id, refreshed_at: refreshed_at) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp invalidate_order!(before_snapshot, after_snapshot) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               PeriodProjectionInvalidator.invalidate_order_change(
                 before_snapshot,
                 after_snapshot
               )
             end)
  end

  defp seed_unaffected_current_bucket!(event_id) do
    generation_id = Ecto.UUID.generate()
    refreshed_at = ~U[2026-06-01 09:00:00.000000Z]

    row =
      Ash.create!(
        EventPeriodAggregateSnapshot,
        %{
          event_id: event_id,
          currency: "EUR",
          bucket_kind: :utc_hour,
          bucket_timezone: "UTC",
          bucket_start_utc: ~U[2026-06-01 09:00:00.000000Z],
          bucket_end_utc: ~U[2026-06-01 10:00:00.000000Z],
          gross_ticket_quantity: 7,
          gross_ticket_value: Decimal.new("77.00"),
          generation_id: generation_id,
          semantic_version: 1,
          coverage_identity: "m5_04_coverage_v1",
          projection_state: :current,
          refreshed_at: refreshed_at
        },
        action: :create_snapshot,
        domain: Analytics
      )

    Map.merge(row, %{generation_id: generation_id, refreshed_at: refreshed_at})
  end

  defp period_rows!(event_id) do
    EventPeriodAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort([:currency, :bucket_kind, :bucket_start_utc])
    |> Ash.read!(domain: Analytics)
  end

  defp contribution_facts!(event_id) do
    AnalyticsContributionFact
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.read!(domain: Analytics)
  end

  defp dimension_rows!(event_id) do
    EventDimensionPeriodAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort([:currency, :bucket_kind, :bucket_start_utc, :dimension_kind])
    |> Ash.read!(domain: Analytics)
  end

  defp dimension_rows_for_bucket(rows, bucket) do
    Enum.filter(rows, fn row ->
      row.currency == bucket.currency and
        row.bucket_kind == bucket.bucket_kind and
        row.bucket_start_utc == bucket.bucket_start_utc and
        row.bucket_end_utc == bucket.bucket_end_utc
    end)
  end

  defp bucket!(rows, kind, %DateTime{} = instant) do
    Enum.find(rows, fn row ->
      row.bucket_kind == kind and
        DateTime.compare(row.bucket_start_utc, instant) in [:lt, :eq] and
        DateTime.compare(row.bucket_end_utc, instant) == :gt
    end) || flunk("missing #{kind} for #{DateTime.to_iso8601(instant)}")
  end
end
