defmodule EventSales.Ingestion.Resources.SyncRunTest do
  use EventSales.DataCase, async: true

  alias EventSales.Ingestion
  alias EventSales.Ingestion.ReconciliationPeakGuard
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.TestSupport.SalesHelpers

  @peak_monday ~U[2026-05-18 12:00:00.000000Z]
  @off_peak_saturday ~U[2026-05-16 12:00:00.000000Z]
  @coverage_start ~U[2026-05-01 00:00:00.000000Z]
  @sales_covered_through ~U[2026-05-08 12:00:00.000000Z]
  @refunds_covered_through ~U[2026-05-08 12:00:00.000000Z]

  describe "queue_manual_scoped scope validation" do
    test "rejects missing event_id" do
      source = SalesHelpers.create_source_system!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               queue_manual(%{
                 source_system_id: source.id,
                 event_id: nil,
                 date_from: ~U[2026-05-01 00:00:00Z],
                 date_to: ~U[2026-05-02 00:00:00Z],
                 sync_mode: :shallow
               })

      assert field_error?(errors, :event_id)
    end

    test "rejects missing date_from" do
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "Scoped", slug: "scoped-event"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               queue_manual(%{
                 source_system_id: source.id,
                 event_id: event.id,
                 date_from: nil,
                 date_to: ~U[2026-05-02 00:00:00Z],
                 sync_mode: :shallow
               })

      assert field_error?(errors, :date_from)
    end

    test "rejects date_to on or before date_from" do
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "Scoped", slug: "scoped-range"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               queue_manual(%{
                 source_system_id: source.id,
                 event_id: event.id,
                 date_from: ~U[2026-05-02 00:00:00Z],
                 date_to: ~U[2026-05-02 00:00:00Z],
                 sync_mode: :shallow
               })

      assert field_error?(errors, :date_to)
    end

    test "accepts scoped shallow manual sync" do
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "Scoped", slug: "scoped-ok"})

      assert {:ok, run} =
               queue_manual(
                 %{
                   source_system_id: source.id,
                   event_id: event.id,
                   date_from: ~U[2026-05-01 00:00:00Z],
                   date_to: ~U[2026-05-02 00:00:00Z],
                   sync_mode: :shallow
                 },
                 now: @off_peak_saturday
               )

      assert run.status == :queued
      assert run.requested_via == :manual
      assert run.sync_mode == :shallow
    end

    test "rejects deep sync during peak weekdays via queue_manual_scoped" do
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "Peak", slug: "peak-deep"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               queue_manual(
                 %{
                   source_system_id: source.id,
                   event_id: event.id,
                   date_from: ~U[2026-05-01 00:00:00Z],
                   date_to: ~U[2026-05-02 00:00:00Z],
                   sync_mode: :deep
                 },
                 now: @peak_monday
               )

      assert field_error?(errors, :sync_mode)
    end

    test "rejects wide date range during peak weekdays via queue_manual_scoped" do
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "Peak", slug: "peak-wide"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               queue_manual(
                 %{
                   source_system_id: source.id,
                   event_id: event.id,
                   date_from: ~U[2026-05-01 00:00:00Z],
                   date_to: ~U[2026-05-15 00:00:00Z],
                   sync_mode: :shallow
                 },
                 now: @peak_monday
               )

      assert field_error?(errors, :date_to)
    end
  end

  describe "ReconciliationPeakGuard" do
    test "rejects deep sync on peak weekdays" do
      assert {:error, :peak_restricted} =
               ReconciliationPeakGuard.validate(
                 :deep,
                 ~U[2026-05-01 00:00:00Z],
                 ~U[2026-05-02 00:00:00Z],
                 now: @peak_monday
               )
    end

    test "allows shallow sync within max_days on peak weekdays" do
      assert :ok =
               ReconciliationPeakGuard.validate(
                 :shallow,
                 ~U[2026-05-01 00:00:00Z],
                 ~U[2026-05-07 00:00:00Z],
                 now: @peak_monday
               )
    end

    test "allows deep sync off peak weekdays" do
      assert :ok =
               ReconciliationPeakGuard.validate(
                 :deep,
                 ~U[2026-05-01 00:00:00Z],
                 ~U[2026-05-02 00:00:00Z],
                 now: @off_peak_saturday
               )
    end
  end

  describe "status transitions" do
    test "complete from queued is rejected" do
      run = create_manual_run!()

      assert {:error, _} = Ash.update(run, %{}, action: :complete, domain: Ingestion)
      assert Ash.get!(SyncRun, run.id, domain: Ingestion).status == :queued
    end

    test "start from queued sets started_at and running status" do
      run = create_manual_run!()

      assert {:ok, started} = Ash.update(run, %{}, action: :start, domain: Ingestion)
      assert started.status == :running
      assert %DateTime{} = started.started_at
    end

    test "pause from running sets paused_until, pause_reason, and last_error" do
      run = create_manual_run!() |> start_run!()
      paused_until = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, paused} =
               Ash.update(
                 run,
                 %{
                   paused_until: paused_until,
                   pause_reason: :rate_limited,
                   last_error: "429 Too Many Requests"
                 },
                 action: :pause,
                 domain: Ingestion
               )

      assert paused.status == :paused
      assert paused.pause_reason == :rate_limited
      assert paused.last_error == "429 Too Many Requests"
      assert DateTime.compare(paused.paused_until, paused_until) == :eq
    end

    test "complete from running sets finished_at" do
      run = create_manual_run!() |> start_run!()

      assert {:ok, completed} = Ash.update(run, %{}, action: :complete, domain: Ingestion)
      assert completed.status == :completed
      assert %DateTime{} = completed.finished_at
    end

    test "fail from running sets finished_at and last_error" do
      run = create_manual_run!() |> start_run!()

      assert {:ok, failed} =
               Ash.update(run, %{last_error: "worker error"}, action: :fail, domain: Ingestion)

      assert failed.status == :failed
      assert failed.last_error == "worker error"
      assert %DateTime{} = failed.finished_at
    end

    test "cancel from queued sets finished_at" do
      run = create_manual_run!()

      assert {:ok, cancelled} = Ash.update(run, %{}, action: :cancel, domain: Ingestion)
      assert cancelled.status == :cancelled
      assert %DateTime{} = cancelled.finished_at
    end
  end

  describe "coverage watermark" do
    test "new historical SyncRun has incomplete defaults and no coverage audit fields" do
      run = create_historical_run!()
      persisted = Ash.get!(SyncRun, run.id, domain: Ingestion)

      assert persisted.order_coverage_status == :incomplete
      assert persisted.refund_coverage_status == :not_started

      for field <- [
            :coverage_start,
            :sales_covered_through,
            :refunds_covered_through,
            :coverage_certified_at,
            :coverage_invalidated_at,
            :coverage_invalidation_reason
          ] do
        assert Map.get(persisted, field) == nil
      end
    end

    test "record_coverage_certification stores exact boundaries and completes both coverages" do
      run = create_historical_run!()
      attrs = coverage_attrs()

      assert {:ok, certified} =
               Ash.update(run, attrs,
                 action: :record_coverage_certification,
                 domain: Ingestion
               )

      assert certified.coverage_start == attrs.coverage_start
      assert certified.sales_covered_through == attrs.sales_covered_through
      assert certified.refunds_covered_through == attrs.refunds_covered_through
      assert certified.order_coverage_status == :complete
      assert certified.refund_coverage_status == :complete
      assert %DateTime{} = certified.coverage_certified_at
    end

    test "rejects coverage certification when coverage_start is later than sales_covered_through" do
      run = create_historical_run!()

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(
                 run,
                 %{
                   coverage_attrs()
                   | coverage_start: DateTime.add(@sales_covered_through, 1, :second)
                 },
                 action: :record_coverage_certification,
                 domain: Ingestion
               )
    end

    test "accepts a refund coverage boundary later than sales coverage" do
      run = create_historical_run!()
      refunds_covered_through = DateTime.add(@sales_covered_through, 1, :day)

      assert {:ok, certified} =
               Ash.update(
                 run,
                 %{coverage_attrs() | refunds_covered_through: refunds_covered_through},
                 action: :record_coverage_certification,
                 domain: Ingestion
               )

      assert certified.refunds_covered_through == refunds_covered_through
      assert certified.order_coverage_status == :complete
      assert certified.refund_coverage_status == :complete
    end

    test "rejects coverage certification for a non-historical SyncRun" do
      run = create_manual_run!()

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(run, coverage_attrs(),
                 action: :record_coverage_certification,
                 domain: Ingestion
               )
    end

    test "rejects a second coverage certification on the same SyncRun" do
      run = create_historical_run!()
      certified = record_certification!(run)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(certified, coverage_attrs(),
                 action: :record_coverage_certification,
                 domain: Ingestion
               )
    end

    test "invalidate_order_coverage invalidates both statuses and preserves certification audit" do
      run = create_historical_run!()
      certified = record_certification!(run)
      reason = :historical_order_changed

      assert {:ok, invalidated} =
               Ash.update(
                 certified,
                 %{coverage_invalidation_reason: reason},
                 action: :invalidate_order_coverage,
                 domain: Ingestion
               )

      assert invalidated.order_coverage_status == :incomplete
      assert invalidated.refund_coverage_status == :incomplete
      assert invalidated.coverage_invalidation_reason == reason
      assert %DateTime{} = invalidated.coverage_invalidated_at
      assert invalidated.coverage_start == certified.coverage_start
      assert invalidated.sales_covered_through == certified.sales_covered_through
      assert invalidated.refunds_covered_through == certified.refunds_covered_through
      assert invalidated.coverage_certified_at == certified.coverage_certified_at
    end

    test "invalidate_refund_coverage leaves order coverage complete and preserves certification audit" do
      run = create_historical_run!()
      certified = record_certification!(run)
      reason = :historical_refund_changed

      assert {:ok, invalidated} =
               Ash.update(
                 certified,
                 %{coverage_invalidation_reason: reason},
                 action: :invalidate_refund_coverage,
                 domain: Ingestion
               )

      assert invalidated.order_coverage_status == :complete
      assert invalidated.refund_coverage_status == :incomplete
      assert invalidated.coverage_invalidation_reason == reason
      assert %DateTime{} = invalidated.coverage_invalidated_at
      assert invalidated.coverage_start == certified.coverage_start
      assert invalidated.sales_covered_through == certified.sales_covered_through
      assert invalidated.refunds_covered_through == certified.refunds_covered_through
      assert invalidated.coverage_certified_at == certified.coverage_certified_at
    end

    test "rejects an invalid coverage invalidation reason" do
      run = create_historical_run!()

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(
                 run,
                 %{coverage_invalidation_reason: :invalid_reason},
                 action: :invalidate_order_coverage,
                 domain: Ingestion
               )
    end

    test "ordinary SyncRun remains uncertified without a certification action" do
      run = create_manual_run!()
      persisted = Ash.get!(SyncRun, run.id, domain: Ingestion)

      assert persisted.order_coverage_status == :incomplete
      assert persisted.refund_coverage_status == :not_started
      assert is_nil(persisted.coverage_certified_at)
      assert is_nil(persisted.coverage_invalidated_at)
      assert is_nil(persisted.coverage_invalidation_reason)
    end

    test "completed historical SyncRun remains uncertified without coverage evidence" do
      run = create_historical_run!() |> start_run!()
      completed = Ash.update!(run, %{}, action: :complete, domain: Ingestion)
      persisted = Ash.get!(SyncRun, completed.id, domain: Ingestion)

      assert persisted.status == :completed
      assert persisted.order_coverage_status == :incomplete
      assert persisted.refund_coverage_status == :not_started
      assert is_nil(persisted.coverage_certified_at)
    end
  end

  defp queue_manual(attrs, opts \\ []) do
    now = Keyword.get(opts, :now, @off_peak_saturday)

    attrs
    |> Map.put_new(:requested_via, :manual)
    |> then(fn attrs ->
      SyncRun
      |> Ash.Changeset.for_create(
        :queue_manual_scoped,
        attrs,
        context: %{scoped_manual_sync_now: now}
      )
      |> Ash.create(domain: Ingestion)
    end)
  end

  defp create_manual_run! do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Run",
        slug: "run-#{System.unique_integer([:positive])}"
      })

    {:ok, run} =
      queue_manual(%{
        source_system_id: source.id,
        event_id: event.id,
        date_from: ~U[2026-05-01 00:00:00Z],
        date_to: ~U[2026-05-02 00:00:00Z],
        sync_mode: :shallow
      })

    run
  end

  defp create_historical_run! do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Historical Run",
        slug: "historical-run-#{System.unique_integer([:positive])}"
      })

    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: ~U[2026-05-10 00:00:00.000000Z]
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, source.id)
    |> Ash.Changeset.force_change_attribute(:date_from, @coverage_start)
    |> Ash.create!(domain: Ingestion)
  end

  defp coverage_attrs do
    %{
      coverage_start: @coverage_start,
      sales_covered_through: @sales_covered_through,
      refunds_covered_through: @refunds_covered_through
    }
  end

  defp record_certification!(run, attrs \\ coverage_attrs()) do
    Ash.update!(run, attrs, action: :record_coverage_certification, domain: Ingestion)
  end

  defp start_run!(run) do
    Ash.update!(run, %{}, action: :start, domain: Ingestion)
  end

  defp field_error?(errors, field) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{field: ^field} -> true
      _ -> false
    end)
  end
end
