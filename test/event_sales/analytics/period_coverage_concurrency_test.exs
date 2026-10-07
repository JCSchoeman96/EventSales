defmodule EventSales.Analytics.PeriodCoverageConcurrencyTest do
  use EventSales.DataCase, async: false

  import Ecto.Query

  require Ash.Query

  alias EventSales.Analytics

  alias EventSales.Analytics.{
    EventSnapshotRefreshFence,
    PeriodCoverageMaterializer,
    PeriodProjectionInvalidator,
    SnapshotRefresh
  }

  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Ingestion.HistoricalOrderMutationDetector
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.EventSnapshotRefreshTestSupport
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.PeriodCoverageHelpers
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.StubRefreshSnapshotWorker
  alias EventSales.TestSupport.UnboxedPostgres

  @now ~U[2026-05-17 10:00:00.000000Z]
  @completed_at ~U[2026-05-21 10:00:00.000000Z]

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
      cleanup_unboxed_event!(source, event)
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

      cleanup_unboxed_event!(source, event)
    end)
  end

  test "ordering A: source commits invalidation before materializer cannot leave stale CURRENT zero" do
    UnboxedPostgres.with_exclusive_setup(fn ->
      {source, event, ticket, zero_row, normalized} = zero_bucket_fixture!(order?: false)

      assert {:ok, _order} =
               UnboxedPostgres.with_connection(fn ->
                 OrderUpserter.upsert_normalized_order(source.id, normalized,
                   snapshot_refresh_scheduler: fn _ -> :ok end
                 )
               end)

      reloaded = Ash.get!(EventPeriodAggregateSnapshot, zero_row.id, domain: Analytics)
      assert reloaded.projection_state == :refresh_pending

      assert {:ok, %{bucket_intents_created: 0}} =
               UnboxedPostgres.with_connection(fn ->
                 PeriodCoverageMaterializer.materialize(event.id, @now,
                   refresh_snapshot_worker: StubRefreshSnapshotWorker,
                   enqueue_refresh?: false
                 )
               end)

      still = Ash.get!(EventPeriodAggregateSnapshot, zero_row.id, domain: Analytics)
      assert still.projection_state == :refresh_pending

      assert {:ok, _} =
               UnboxedPostgres.with_connection(fn ->
                 SnapshotRefresh.refresh_event(event.id, now: @completed_at)
               end)

      final = Ash.get!(EventPeriodAggregateSnapshot, zero_row.id, domain: Analytics)
      assert final.projection_state == :current
      assert final.gross_ticket_quantity > 0

      cleanup_unboxed_event!(source, event)
    end)
  end

  test "ordering B: materializer xact fence serializes with source upsert without stale CURRENT zero" do
    UnboxedPostgres.with_exclusive_setup(fn ->
      {source, event, ticket, zero_row, normalized} = zero_bucket_fixture!(order?: false)
      parent = self()

      holder =
        Task.async(fn ->
          UnboxedPostgres.with_connection(fn ->
            Repo.transaction(fn ->
              assert :ok = EventSnapshotRefreshFence.lock_events_in_transaction([event.id])
              send(parent, :materializer_fence_held)

              receive do
                :release_materializer_fence -> :ok
              after
                20_000 -> Repo.rollback(:materializer_fence_timeout)
              end
            end)
          end)
        end)

      assert_receive :materializer_fence_held, 5_000

      source_task =
        Task.async(fn ->
          UnboxedPostgres.with_connection(fn ->
            backend = EventSnapshotRefreshFence.connection_backend_pid()
            send(parent, {:source_backend, backend})

            OrderUpserter.upsert_normalized_order(source.id, normalized,
              snapshot_refresh_scheduler: fn _ -> :ok end
            )
          end)
        end)

      assert_receive {:source_backend, source_backend}, 5_000
      EventSnapshotRefreshTestSupport.wait_for_advisory_lock_wait!(source_backend)
      send(holder.pid, :release_materializer_fence)

      assert {:ok, :ok} = Task.await(holder, 10_000)
      assert {:ok, _order} = Task.await(source_task, 20_000)

      reloaded = Ash.get!(EventPeriodAggregateSnapshot, zero_row.id, domain: Analytics)
      refute reloaded.projection_state == :current and reloaded.gross_ticket_quantity == 0

      assert {:ok, _} =
               UnboxedPostgres.with_connection(fn ->
                 SnapshotRefresh.refresh_event(event.id, now: @completed_at)
               end)

      final = Ash.get!(EventPeriodAggregateSnapshot, zero_row.id, domain: Analytics)
      assert final.projection_state == :current
      assert final.gross_ticket_quantity > 0

      cleanup_unboxed_event!(source, event)
    end)
  end

  test "ordering C: source holds invalidation until materializer finishes then commits" do
    UnboxedPostgres.with_exclusive_setup(fn ->
      {source, event, ticket, zero_row, _normalized} = zero_bucket_fixture!(order?: true)
      parent = self()

      source_task =
        Task.async(fn ->
          UnboxedPostgres.with_connection(fn ->
            Repo.transaction(fn ->
              order =
                Order
                |> Ash.Query.filter(woo_order_id == 90_010 and source_system_id == ^source.id)
                |> Ash.read_one!(domain: Sales)

              {:ok, before_snapshot} = HistoricalOrderMutationDetector.capture(order)

              order_id = Ecto.UUID.dump!(order.id)

              Repo.update_all(
                from(oi in "sales_order_items", where: oi.order_id == ^order_id),
                set: [quantity: 2, line_total: Decimal.new("200.00")]
              )

              order =
                Order
                |> Ash.Query.filter(id == ^order.id)
                |> Ash.read_one!(domain: Sales)

              {:ok, after_snapshot} = HistoricalOrderMutationDetector.capture(order)

              assert :ok =
                       PeriodProjectionInvalidator.invalidate_order_change(
                         before_snapshot,
                         after_snapshot
                       )

              send(parent, :source_invalidated_uncommitted)

              receive do
                :commit_source -> :ok
              after
                20_000 -> Repo.rollback(:source_lock_timeout)
              end
            end)
          end)
        end)

      assert_receive :source_invalidated_uncommitted, 5_000

      assert {:ok, %{bucket_intents_created: 0}} =
               UnboxedPostgres.with_connection(fn ->
                 PeriodCoverageMaterializer.materialize(event.id, @now,
                   refresh_snapshot_worker: StubRefreshSnapshotWorker,
                   enqueue_refresh?: false
                 )
               end)

      send(source_task.pid, :commit_source)
      assert {:ok, :ok} = Task.await(source_task, 10_000)

      reloaded = Ash.get!(EventPeriodAggregateSnapshot, zero_row.id, domain: Analytics)
      refute reloaded.projection_state == :current and reloaded.gross_ticket_quantity == 0

      cleanup_unboxed_event!(source, event)
    end)
  end

  defp zero_bucket_fixture!(order?: include_order?) do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Race zero bucket"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    {:ok, [spec, _day]} = EventSales.Analytics.PeriodBucketRules.for_instant(@completed_at)

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

    if include_order? do
      order =
        Ash.create!(
          Order,
          %{
            source_system_id: source.id,
            woo_order_id: 90_010,
            order_number: "RACE-ZERO",
            status: :completed,
            currency: "ZAR",
            completed_at: @completed_at,
            created_at_source: @completed_at,
            updated_at_source: @completed_at,
            raw_total: Decimal.new("100.00"),
            raw_discount_total: Decimal.new("0"),
            raw_tax_total: Decimal.new("0")
          },
          action: :create_normalized,
          domain: Sales
        )

      Ash.create!(
        OrderItem,
        %{
          order_id: order.id,
          event_id: event.id,
          ticket_type_id: ticket.id,
          woo_line_item_id: 80_010,
          woo_product_id: 501,
          woo_variation_id: 601,
          name: "GA",
          quantity: 1,
          line_subtotal: Decimal.new("100.00"),
          line_total: Decimal.new("100.00"),
          line_total_tax: Decimal.new("0"),
          discount_total: Decimal.new("0"),
          item_kind: :ticket,
          mapping_status: :mapped
        },
        action: :create_normalized,
        domain: Sales
      )
    end

    normalized = %{
      woo_order_id: 90_010,
      order_number: "RACE-ZERO",
      status: :completed,
      currency: "ZAR",
      completed_at: @completed_at,
      created_at_source: @completed_at,
      updated_at_source: @completed_at,
      customer_name: "Race",
      customer_email: "race@test",
      raw_total: Decimal.new("100.00"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0"),
      payment_method: "payfast",
      payment_method_title: "PayFast",
      payment_gateway_transaction_id: "race-1",
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

    {source, event, ticket, zero_row, normalized}
  end

  defp cleanup_unboxed_event!(source, event) do
    event_id = Ecto.UUID.dump!(event.id)
    source_id = Ecto.UUID.dump!(source.id)

    Repo.delete_all(from o in Order, where: o.source_system_id == ^source_id)
    Repo.delete_all(from(oi in "sales_order_items", where: oi.event_id == ^event_id))
    Repo.delete_all(from(f in "analytics_contribution_facts", where: f.event_id == ^event_id))

    Repo.delete_all(
      from(s in "analytics_event_dimension_period_aggregate_snapshots",
        where: s.event_id == ^event_id
      )
    )

    Repo.delete_all(
      from(s in "analytics_event_dimension_aggregate_snapshots", where: s.event_id == ^event_id)
    )

    Repo.delete_all(
      from(r in "analytics_event_period_aggregate_snapshots", where: r.event_id == ^event_id)
    )

    Repo.delete_all(
      from(r in "ingestion_financial_reconciliation_runs", where: r.event_id == ^event_id)
    )

    Repo.delete_all(from(r in "ingestion_sync_runs", where: r.event_id == ^event_id))
    Repo.delete_all(from(tt in "catalog_ticket_types", where: tt.event_id == ^event_id))
    Repo.delete_all(from(e in "catalog_events", where: e.id == ^event_id))
    Repo.delete_all(from(s in "catalog_source_systems", where: s.id == ^source_id))
  end
end
