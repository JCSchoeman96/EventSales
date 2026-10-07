defmodule EventSales.Analytics.PeriodCoverageConcurrencyTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Analytics
  alias EventSales.Analytics.PeriodCoverageMaterializer
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Repo
  alias EventSales.Sales.OrderUpserter
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.PeriodCoverageHelpers
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.StubRefreshSnapshotWorker
  alias EventSales.TestSupport.UnboxedPostgres

  @now ~U[2026-05-17 10:00:00.000000Z]

  test "concurrent materializers create one logical bucket identity" do
    UnboxedPostgres.with_exclusive_setup(fn ->
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "Concurrent seeder"})
      EventDetailCertificationHelpers.certify_analytics_ready!(event)
      PeriodCoverageHelpers.seed_v2_currency!(event, "ZAR")

      parent = self()

      tasks =
        for _ <- 1..4 do
          Task.async(fn ->
            UnboxedPostgres.with_connection(fn ->
              PeriodCoverageMaterializer.materialize(event.id, @now,
                refresh_snapshot_worker: StubRefreshSnapshotWorker
              )
            end)
          end)
        end

      results = Task.await_many(tasks, 60_000)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      count =
        EventPeriodAggregateSnapshot
        |> Ash.Query.filter(event_id == ^event.id)
        |> Ash.read!(domain: Analytics)
        |> length()

      assert count > 0

      send(parent, :done)
    end)

    assert true
  end

  test "pre-materialized CURRENT zero becomes refresh_pending after canonical sale mutation" do
    UnboxedPostgres.with_exclusive_setup(fn ->
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "Zero then sale"})
      ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

      completed_at = ~U[2026-05-21 10:00:00.000000Z]

      {:ok, [spec, _day]} = EventSales.Analytics.PeriodBucketRules.for_instant(completed_at)

      zero_row =
        PeriodComparisonHelpers.create_event_bucket!(
          event.id,
          "ZAR",
          spec,
          %{
            projection_state: :current,
            gross_ticket_quantity: 0,
            gross_ticket_value: Decimal.new("0")
          }
        )

      normalized = %{
        woo_order_id: 90_010,
        order_number: "ZERO-SALE",
        status: :completed,
        currency: "ZAR",
        completed_at: completed_at,
        created_at_source: completed_at,
        updated_at_source: completed_at,
        customer_name: "Zero Sale",
        customer_email: "zero@sale.test",
        raw_total: Decimal.new("100.00"),
        raw_discount_total: Decimal.new("0"),
        raw_tax_total: Decimal.new("0"),
        payment_method: "payfast",
        payment_method_title: "PayFast",
        payment_gateway_transaction_id: "zero-sale-1",
        coupons: [],
        line_items: [
          %{
            woo_line_item_id: 80_010,
            woo_product_id: 501,
            woo_variation_id: 601,
            name: "GA",
            quantity: 1,
            line_subtotal: Decimal.new("100.00"),
            line_total: Decimal.new("100.00"),
            line_total_tax: Decimal.new("0"),
            discount_total: Decimal.new("0"),
            event_id: event.id,
            ticket_type_id: ticket.id,
            item_kind: :ticket,
            mapping_status: :mapped
          }
        ]
      }

      assert {:ok, _order} =
               OrderUpserter.upsert_normalized_order(source.id, normalized,
                 snapshot_refresh_scheduler: fn _ -> :ok end
               )

      reloaded = Ash.get!(EventPeriodAggregateSnapshot, zero_row.id, domain: Analytics)
      assert reloaded.projection_state == :refresh_pending
    end)
  end
end
