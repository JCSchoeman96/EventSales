defmodule EventSales.Analytics.PeriodProjectionRefreshRollbackTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  require Ash.Query

  alias EventSales.Analytics.PeriodProjectionInvalidator
  alias EventSales.Analytics.Resources.{AnalyticsContributionFact, EventPeriodAggregateSnapshot}
  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Catalog.Resources.{Event, SourceSystem, TicketType}
  alias EventSales.Ingestion.HistoricalOrderMutationDetector
  alias EventSales.Repo
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.{SalesHelpers, UnboxedPostgres}

  test "period bucket failure rolls back facts and keeps committed pending intent" do
    UnboxedPostgres.with_connection(fn ->
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "Period rollback"})
      ticket = SalesHelpers.create_ticket_type!(event, %{name: "Rollback ticket"})
      order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

      item =
        SalesHelpers.create_order_item_from_line!(
          order,
          %{
            "id" => System.unique_integer([:positive]),
            "product_id" => 5001,
            "variation_id" => 5002,
            "name" => "Rollback ticket",
            "quantity" => 1,
            "subtotal" => "20.00",
            "total" => "20.00",
            "total_tax" => "3.00",
            "discount_total" => "0"
          },
          %{
            event_id: event.id,
            ticket_type_id: ticket.id,
            item_kind: :ticket,
            mapping_status: :mapped,
            line_total: Decimal.new("20.00"),
            line_total_tax: Decimal.new("3.00")
          }
        )

      assert {:ok, snapshot} = HistoricalOrderMutationDetector.capture(order)

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 PeriodProjectionInvalidator.invalidate_order_change(nil, snapshot)
               end)

      constraint = "period_block_current_#{System.unique_integer([:positive])}"

      try do
        Repo.query!(
          "ALTER TABLE analytics_event_period_aggregate_snapshots ADD CONSTRAINT #{constraint} CHECK (projection_state != 'current') NOT VALID"
        )

        assert {:error, _reason} = SnapshotRefresh.refresh_event(event.id)

        pending_rows =
          EventPeriodAggregateSnapshot
          |> Ash.Query.filter(event_id == ^event.id)
          |> Ash.read!(domain: EventSales.Analytics)

        assert length(pending_rows) == 2
        assert Enum.all?(pending_rows, &(&1.projection_state == :refresh_pending))

        assert Repo.aggregate(
                 from(fact in AnalyticsContributionFact, where: fact.event_id == ^event.id),
                 :count
               ) == 0

        assert item.event_id == event.id
      after
        Repo.query!(
          "ALTER TABLE analytics_event_period_aggregate_snapshots DROP CONSTRAINT IF EXISTS #{constraint}"
        )

        Repo.delete_all(
          from(fact in AnalyticsContributionFact, where: fact.event_id == ^event.id)
        )

        Repo.delete_all(
          from(bucket in EventPeriodAggregateSnapshot, where: bucket.event_id == ^event.id)
        )

        Repo.delete_all(from(item in OrderItem, where: item.event_id == ^event.id))
        Repo.delete_all(from(order in Order, where: order.source_system_id == ^source.id))
        Repo.delete_all(from(ticket in TicketType, where: ticket.event_id == ^event.id))
        Repo.delete_all(from(event_row in Event, where: event_row.id == ^event.id))
        Repo.delete_all(from(source_row in SourceSystem, where: source_row.id == ^source.id))
      end
    end)
  end
end
