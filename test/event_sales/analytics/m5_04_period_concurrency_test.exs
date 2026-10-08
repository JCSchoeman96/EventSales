# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule EventSales.Analytics.M5_04PeriodConcurrencyTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Analytics.EventSnapshotRefreshFence
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Repo
  alias EventSales.TestSupport.M5_04PeriodCertificationHelpers, as: Cert
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.UnboxedPostgres

  @now ~U[2026-05-17 10:17:33.000000Z]
  @sale_at ~U[2026-05-16 08:00:00.000000Z]
  @late_refund_at ~U[2026-05-17 08:00:00.000000Z]

  test "late refund commits during rolling reader RR transaction stays coherent" do
    UnboxedPostgres.with_exclusive_setup(fn ->
      source = Cert.create_unboxed_certification_source!()
      event = Cert.prepare_analytics_ready_event!(source)

      ticket = SalesHelpers.create_ticket_type!(event, %{name: "RR late refund"})

      {order, item, order_snap} =
        Cert.ingest_sale_and_refresh!(event, nil, source, ticket, @sale_at, @now)

      {:ok, _windows, plan} =
        EventSales.TestSupport.PeriodComparisonHelpers.plan_for(:today, @now)

      reader = self()

      writer =
        Task.async(fn ->
          receive do
            {:reader_loaded, _} ->
              UnboxedPostgres.with_connection(fn ->
                Cert.create_qualifying_refund!(source, order, item, @late_refund_at)
                after_snap = Cert.capture_order_snapshot!(order)
                Cert.invalidate_order_change!(order_snap, after_snap)
                Cert.refresh_period_projections!(event.id, @now)
              end)

              send(reader, :late_refund_committed)
          after
            20_000 -> raise "writer timeout"
          end
        end)

      transaction_opts =
        [timeout: 30_000] ++ EventSnapshotRefreshFence.coherent_transaction_opts()

      assert {:ok, first_refund} =
               UnboxedPostgres.with_connection(fn ->
                 Repo.transaction(
                   fn ->
                     payload =
                       PeriodComparisonReader.load_operand_payload_for_test!(
                         event.id,
                         "ZAR",
                         plan
                       )

                     first = sum_event_row_refund(payload)

                     send(writer.pid, {:reader_loaded, first})

                     receive do
                       :late_refund_committed -> :ok
                     after
                       20_000 -> Repo.rollback(:writer_timeout)
                     end

                     second_payload =
                       PeriodComparisonReader.load_operand_payload_for_test!(
                         event.id,
                         "ZAR",
                         plan
                       )

                     second = sum_event_row_refund(second_payload)

                     assert first == second
                     first
                   end,
                   transaction_opts
                 )
               end)

      assert Task.await(writer, 20_000)

      outside_payload =
        PeriodComparisonReader.load_operand_payload_for_test!(event.id, "ZAR", plan)

      assert sum_event_row_refund(outside_payload) > first_refund
    end)
  end

  test "exact replay after refresh produces no contribution semantic churn" do
    source = SalesHelpers.create_source_system!()
    event = Cert.prepare_analytics_ready_event!(source)
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Replay"})

    {_order, _item, snap} =
      Cert.ingest_sale_and_refresh!(event, nil, source, ticket, @sale_at, @now)

    before = Cert.contribution_semantic_fingerprint(event.id)
    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id, now: @now, refreshed_at: @now)
    Cert.invalidate_order_change!(snap, snap)
    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id, now: @now, refreshed_at: @now)
    after_fp = Cert.contribution_semantic_fingerprint(event.id)
    assert before == after_fp
  end

  test "same-event refresh callers serialize while distinct events run in parallel" do
    source = SalesHelpers.create_source_system!()
    event_a = Cert.prepare_analytics_ready_event!(source, %{name: "Fence A"})
    event_b = Cert.prepare_analytics_ready_event!(source, %{name: "Fence B"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "A"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "B"})
    Cert.ingest_sale_and_refresh!(event_a, nil, source, ticket_a, @sale_at, @now)
    Cert.ingest_sale_and_refresh!(event_b, nil, source, ticket_b, @sale_at, @now)

    same_event =
      Task.async_stream(
        1..6,
        fn _ ->
          {us, result} =
            :timer.tc(fn ->
              SnapshotRefresh.refresh_event(event_a.id, now: @now, refreshed_at: @now)
            end)

          {div(us, 1000), result}
        end,
        max_concurrency: 6,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, v} -> v end)

    assert Enum.all?(same_event, fn {_ms, result} -> match?({:ok, _}, result) end)

    distinct =
      Task.async_stream(
        [event_a, event_b],
        fn event ->
          {us, result} =
            :timer.tc(fn ->
              SnapshotRefresh.refresh_event(event.id, now: @now, refreshed_at: @now)
            end)

          {div(us, 1000), result}
        end,
        max_concurrency: 2,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, v} -> v end)

    assert length(distinct) == 2
    assert Enum.all?(distinct, fn {_ms, result} -> match?({:ok, _}, result) end)
  end

  defp sum_event_row_refund(payload) do
    payload.event_rows
    |> Enum.map(& &1.refund_ticket_quantity)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end
end
