defmodule EventSales.Analytics.AggregateEventTest do
  use ExUnit.Case, async: true

  alias EventSales.Analytics.AggregateEvent

  @event_id "9c486a5d-6523-4ab0-a9f7-d1088b17f9223"
  @source_system_id "78b89f35-67e2-4387-b57a-39d22dc5dbb2"
  @order_id "e0a1f7b2-0e4d-4edb-a49f-7f9f14f54a13"
  @ticket_type_id "48cdcf91-298f-40be-8a3d-479e60d62f73"
  @occurred_at ~U[2026-05-17 10:00:00Z]
  @source_updated_at ~U[2026-05-17 09:59:00Z]

  test "accepts minimal valid aggregate event" do
    assert {:ok, event} =
             AggregateEvent.new(%{
               aggregate_event_id: "agg-1",
               event_id: @event_id,
               reason: :order_processed,
               occurred_at: @occurred_at
             })

    assert event.aggregate_event_id == "agg-1"
    assert event.event_id == @event_id
    assert event.reason == :order_processed
    assert event.occurred_at == @occurred_at
    assert event.source_system_id == nil
    assert event.order_id == nil
    assert event.ticket_type_id == nil
  end

  test "accepts optional source, order, source timestamp, payload hash, and ticket hint" do
    assert {:ok, event} =
             AggregateEvent.new(%{
               "aggregate_event_id" => "agg-2",
               "event_id" => @event_id,
               "reason" => "order_remapped",
               "occurred_at" => DateTime.to_iso8601(@occurred_at),
               "source_system_id" => @source_system_id,
               "order_id" => @order_id,
               "source_updated_at" => DateTime.to_iso8601(@source_updated_at),
               "payload_hash" => "hash-123",
               "ticket_type_id" => @ticket_type_id
             })

    assert event.reason == :order_remapped
    assert event.source_system_id == @source_system_id
    assert event.order_id == @order_id
    assert event.source_updated_at == @source_updated_at
    assert event.payload_hash == "hash-123"
    assert event.ticket_type_id == @ticket_type_id
  end

  test "rejects missing required fields" do
    assert {:error, {:missing_required_fields, [:aggregate_event_id, :occurred_at, :reason]}} =
             AggregateEvent.new(%{event_id: @event_id})
  end

  test "rejects unknown reason" do
    assert {:error, {:invalid_reason, :unknown}} =
             AggregateEvent.new(%{
               aggregate_event_id: "agg-3",
               event_id: @event_id,
               reason: :unknown,
               occurred_at: @occurred_at
             })
  end

  test "rejects sales deltas as part of the Slice 9.5 contract" do
    assert {:error, {:unsupported_fields, [:quantity_delta, :revenue_delta]}} =
             AggregateEvent.new(%{
               aggregate_event_id: "agg-4",
               event_id: @event_id,
               reason: :order_processed,
               occurred_at: @occurred_at,
               quantity_delta: 2,
               revenue_delta: Decimal.new("900.00")
             })
  end
end
