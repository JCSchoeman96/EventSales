defmodule EventSales.Analytics.PeriodProjectionInvalidatorTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Analytics
  alias EventSales.Analytics.PeriodBucketRules
  alias EventSales.Analytics.PeriodProjectionInvalidator
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Ingestion.HistoricalOrderMutationDetector
  alias EventSales.Ingestion.HistoricalRefundMutationDetector
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.SalesHelpers

  test "a new recognised order creates pending hour and Johannesburg day identities" do
    {_source, event, order, after_snapshot} = mapped_order_snapshot!()
    invalidate_order!(nil, after_snapshot)

    rows = snapshots_for_event(event.id)

    assert Enum.map(rows, & &1.bucket_kind) |> Enum.sort() ==
             [:johannesburg_day, :utc_hour]

    assert Enum.all?(rows, &(&1.projection_state == :refresh_pending))
    assert Enum.all?(rows, &(&1.currency == order.currency))
    assert Enum.all?(rows, &(&1.generation_id != nil))

    assert Enum.all?(rows, fn row ->
             row.gross_ticket_quantity == 0 and row.refund_ticket_quantity == 0 and
               Decimal.equal?(row.gross_ticket_value, Decimal.new("0")) and
               Decimal.equal?(row.refund_ticket_value, Decimal.new("0"))
           end)
  end

  test "exact replay and a missing selected clock do not create buckets" do
    {_source, event, _order, snapshot} = mapped_order_snapshot!()

    invalidate_order!(snapshot, snapshot)
    assert snapshots_for_event(event.id) == []

    without_effective_clock =
      put_in(snapshot.header.completed_at, nil)
      |> put_in([:header, :paid_at], nil)

    assert without_effective_clock.header.created_at_source != nil

    invalidate_order!(nil, without_effective_clock)

    assert snapshots_for_event(event.id) == []
  end

  test "period invalidation requires the source mutation transaction" do
    {_source, event, _order, snapshot} = mapped_order_snapshot!()

    assert {:error, :period_projection_invalidation_requires_transaction} =
             PeriodProjectionInvalidator.invalidate_order_change(nil, snapshot)

    assert snapshots_for_event(event.id) == []
  end

  test "a recognised mapped sale with incomplete primitives still invalidates its known buckets" do
    {_source, event, _order, snapshot} = mapped_order_snapshot!()

    incomplete_snapshot =
      update_in(snapshot, [:order_items, Access.at(0)], &Map.put(&1, :line_total_tax, nil))

    invalidate_order!(nil, incomplete_snapshot)

    rows = snapshots_for_event(event.id)
    assert Enum.map(rows, & &1.bucket_kind) |> Enum.sort() == [:johannesburg_day, :utc_hour]
    assert Enum.all?(rows, &(&1.projection_state == :refresh_pending))
  end

  test "completed to cancelled with completed_at retained preserves sale contribution truth" do
    {_source, event, _order, before_snapshot} = mapped_order_snapshot!()
    after_snapshot = put_in(before_snapshot, [:header, :status], :cancelled)

    invalidate_order!(before_snapshot, after_snapshot)

    assert snapshots_for_event(event.id) == []
  end

  test "selected sale-clock correction invalidates old and new buckets" do
    {_source, event, _order, before_snapshot} = mapped_order_snapshot!()

    after_snapshot =
      before_snapshot
      |> put_in([:header, :paid_at], ~U[2026-06-01 12:00:00.000000Z])
      |> put_in([:header, :completed_at], nil)

    invalidate_order!(before_snapshot, after_snapshot)

    assert length(snapshots_for_event(event.id)) == 4
  end

  test "a recognised sale losing its effective clock invalidates only its old buckets" do
    {_source, event, _order, before_snapshot} = mapped_order_snapshot!()

    after_snapshot =
      before_snapshot
      |> put_in([:header, :paid_at], nil)
      |> put_in([:header, :completed_at], nil)

    invalidate_order!(before_snapshot, after_snapshot)

    assert length(snapshots_for_event(event.id)) == 2
  end

  test "same-bucket source changes invalidate current rows without replacing their values" do
    {_source, event, order, before_snapshot} = mapped_order_snapshot!()
    [bucket | _rest] = bucket_identities!(order, before_snapshot)
    generation_id = Ecto.UUID.generate()

    assert {:ok, _snapshot} =
             Ash.create(
               EventPeriodAggregateSnapshot,
               Map.merge(bucket, %{
                 event_id: event.id,
                 currency: order.currency,
                 gross_ticket_quantity: 3,
                 gross_ticket_value: Decimal.new("123.45"),
                 refund_ticket_quantity: 1,
                 refund_ticket_value: Decimal.new("10.00"),
                 generation_id: generation_id,
                 semantic_version: 1,
                 coverage_identity: "m5_04_coverage_v1",
                 projection_state: :current,
                 refreshed_at: ~U[2026-05-18 09:05:00.000000Z]
               }),
               action: :create_snapshot,
               domain: Analytics
             )

    [item] = before_snapshot.order_items

    after_snapshot =
      Map.update!(before_snapshot, :order_items, fn [_item] ->
        [Map.put(item, :quantity, item.quantity + 1)]
      end)

    invalidate_order!(before_snapshot, after_snapshot)

    updated = Enum.find(snapshots_for_event(event.id), &(&1.bucket_kind == bucket.bucket_kind))
    assert updated.projection_state == :refresh_pending
    assert updated.generation_id == generation_id
    assert updated.gross_ticket_quantity == 3
    assert Decimal.equal?(updated.gross_ticket_value, Decimal.new("123.45"))
    assert updated.refund_ticket_quantity == 1
    assert Decimal.equal?(updated.refund_ticket_value, Decimal.new("10.00"))
  end

  test "selected-clock, event, and currency corrections invalidate both identities" do
    {source, event_a, order, before_snapshot} = mapped_order_snapshot!()
    event_b = SalesHelpers.create_event!(source, %{name: "Second period event"})

    after_snapshot =
      before_snapshot
      |> put_in([:header, :paid_at], ~U[2026-05-04 08:00:00.000000Z])
      |> put_in([:header, :currency], "USD")
      |> update_in([:order_items, Access.at(0)], &Map.put(&1, :event_id, event_b.id))

    invalidate_order!(before_snapshot, after_snapshot)

    rows_a = snapshots_for_event(event_a.id)
    rows_b = snapshots_for_event(event_b.id)
    assert length(rows_a) == 2
    assert length(rows_b) == 2
    assert Enum.all?(rows_a, &(&1.currency == order.currency))
    assert Enum.all?(rows_b, &(&1.currency == "USD"))
    assert Enum.all?(rows_a ++ rows_b, &(&1.projection_state == :refresh_pending))
  end

  test "a value-only exact refund contributes and creates its effective hour and day" do
    {_source, event, refund_snapshot} = refund_snapshot_fixture!(refunded_quantity: 0)

    invalidate_refund!(nil, refund_snapshot)

    rows = snapshots_for_event(event.id)
    assert Enum.map(rows, & &1.bucket_kind) |> Enum.sort() == [:johannesburg_day, :utc_hour]
    assert Enum.all?(rows, &(&1.projection_state == :refresh_pending))
  end

  test "refund effective-time correction and event correction invalidate before and after" do
    {source, event_a, refund_snapshot} = refund_snapshot_fixture!()
    event_b = SalesHelpers.create_event!(source, %{name: "Refund correction event"})
    new_parent_item_id = Ecto.UUID.generate()
    new_parent_line_id = 44_002

    new_parent_item = %{
      id: new_parent_item_id,
      woo_line_item_id: new_parent_line_id,
      event_id: event_b.id,
      ticket_type_id: Ecto.UUID.generate(),
      woo_product_id: 5003,
      woo_variation_id: 6003,
      item_kind: :ticket,
      mapping_status: :mapped
    }

    changed_snapshot =
      refund_snapshot
      |> put_in([:refund_truth, :source_created_at], ~U[2026-06-19 12:30:00.000000Z])
      |> update_in([:parent_order_item_evidence], &(&1 ++ [new_parent_item]))
      |> update_in([:refund_line_truth, Access.at(0)], fn line ->
        line
        |> Map.put(:order_item_id, new_parent_item_id)
        |> Map.put(:woo_refunded_item_id, new_parent_line_id)
      end)

    invalidate_refund!(refund_snapshot, changed_snapshot)

    rows_a = snapshots_for_event(event_a.id)
    rows_b = snapshots_for_event(event_b.id)
    assert length(rows_a) == 2
    assert length(rows_b) == 2
    assert Enum.all?(rows_a ++ rows_b, &(&1.projection_state == :refresh_pending))
  end

  test "voiding and unresolved detail invalidate only the formerly qualifying refund buckets" do
    {source, event, refund_snapshot} = refund_snapshot_fixture!()

    voided = put_in(refund_snapshot, [:refund_truth, :source_state], :voided)

    invalidate_refund!(refund_snapshot, voided)

    rows = snapshots_for_event(event.id)
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1.projection_state == :refresh_pending))

    unresolved_before = put_in(refund_snapshot, [:refund_truth, :detail_status], :unresolved)
    another_event = SalesHelpers.create_event!(source, %{name: "Refund detail event"})

    completed_after =
      refund_snapshot
      |> put_in([:refund_truth, :source_created_at], ~U[2026-06-20 12:30:00.000000Z])
      |> update_in(
        [:parent_order_item_evidence, Access.at(0)],
        &Map.put(&1, :event_id, another_event.id)
      )

    invalidate_refund!(unresolved_before, completed_after)

    assert length(snapshots_for_event(another_event.id)) == 2
  end

  test "complete to unresolved invalidates only the before refund buckets" do
    {source, event_before, refund_snapshot} = refund_snapshot_fixture!()
    event_after = SalesHelpers.create_event!(source, %{name: "Unresolved refund event"})

    unresolved_after =
      refund_snapshot
      |> put_in([:refund_truth, :detail_status], :unresolved)
      |> put_in([:refund_truth, :source_created_at], ~U[2026-06-22 12:30:00.000000Z])
      |> update_in(
        [:parent_order_item_evidence, Access.at(0)],
        &Map.put(&1, :event_id, event_after.id)
      )

    invalidate_refund!(refund_snapshot, unresolved_after)

    assert length(snapshots_for_event(event_before.id)) == 2
    assert snapshots_for_event(event_after.id) == []
  end

  test "a qualifying refund losing its effective clock invalidates only its old buckets" do
    {_source, event, refund_snapshot} = refund_snapshot_fixture!()
    clockless = put_in(refund_snapshot, [:refund_truth, :source_created_at], nil)

    invalidate_refund!(refund_snapshot, clockless)

    assert length(snapshots_for_event(event.id)) == 2
  end

  test "header-only, unbound, and clockless refunds do not invent buckets" do
    {_source, event, refund_snapshot} = refund_snapshot_fixture!()

    invalidate_refund!(refund_snapshot, refund_snapshot)
    assert snapshots_for_event(event.id) == []

    unbound =
      update_in(refund_snapshot, [:refund_line_truth, Access.at(0)], fn line ->
        Map.put(line, :binding_reason, "unresolved_parent_line")
      end)

    invalidate_refund!(nil, unbound)

    header_only = %{refund_snapshot | refund_line_truth: []}
    invalidate_refund!(nil, header_only)

    mismatched_currency = put_in(refund_snapshot, [:refund_truth, :currency], "USD")
    invalidate_refund!(nil, mismatched_currency)

    without_clock = put_in(refund_snapshot, [:refund_truth, :source_created_at], nil)
    invalidate_refund!(nil, without_clock)
    assert snapshots_for_event(event.id) == []
  end

  defp snapshots_for_event(event_id) do
    EventPeriodAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort(bucket_kind: :asc)
    |> Ash.read!(domain: Analytics)
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

  defp invalidate_refund!(before_snapshot, after_snapshot) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               PeriodProjectionInvalidator.invalidate_refund_change(
                 before_snapshot,
                 after_snapshot
               )
             end)
  end

  defp mapped_order_snapshot! do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Period invalidation"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Ticket"})
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    SalesHelpers.create_order_item_from_line!(
      order,
      %{
        "id" => 40_001,
        "product_id" => 5001,
        "variation_id" => 5002,
        "name" => "Ticket",
        "quantity" => 2,
        "subtotal" => "100.00",
        "total" => "90.00",
        "total_tax" => "9.00",
        "discount_total" => "10.00"
      },
      %{
        event_id: event.id,
        ticket_type_id: ticket.id,
        item_kind: :ticket,
        mapping_status: :mapped,
        line_total_tax: Decimal.new("9.00")
      }
    )

    {:ok, snapshot} = HistoricalOrderMutationDetector.capture(order)
    {source, event, order, snapshot}
  end

  defp refund_snapshot_fixture!(opts \\ []) do
    {source, event, order, order_snapshot} = mapped_order_snapshot!()
    item_snapshot = List.first(order_snapshot.order_items)

    item =
      OrderItem
      |> Ash.Query.filter(id == ^item_snapshot.id)
      |> Ash.read_one!(domain: Sales)

    refund_at = Keyword.get(opts, :source_created_at, ~U[2026-06-02 14:30:00.123456Z])

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
          summary_total_amount: Decimal.new("10.00"),
          header_amount: Decimal.new("0"),
          unallocated_header_amount: Decimal.new("0"),
          source_created_at: refund_at
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
        refunded_quantity: Keyword.get(opts, :refunded_quantity, 1),
        refund_total_amount: Decimal.new("10.00"),
        refund_total_tax: Decimal.new("2.00"),
        binding_reason: nil,
        validation_reason: nil
      },
      action: :create_normalized,
      domain: Sales
    )

    assert {:ok, snapshot} = HistoricalRefundMutationDetector.capture(refund)
    {source, event, snapshot}
  end

  defp bucket_identities!(order, snapshot) do
    {:ok, buckets} = PeriodBucketRules.for_instant(order.paid_at || order.completed_at)

    Enum.map(buckets, fn bucket ->
      Map.merge(bucket, %{
        event_id: List.first(snapshot.order_items).event_id,
        currency: order.currency
      })
    end)
  end
end
