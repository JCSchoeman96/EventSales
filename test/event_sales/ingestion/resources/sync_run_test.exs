defmodule EventSales.Ingestion.Resources.SyncRunTest do
  use EventSales.DataCase, async: true

  alias EventSales.Ingestion
  alias EventSales.Ingestion.ReconciliationPeakGuard
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.TestSupport.SalesHelpers

  @peak_monday ~U[2026-05-18 12:00:00.000000Z]
  @off_peak_saturday ~U[2026-05-16 12:00:00.000000Z]

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

  defp queue_manual(attrs, opts \\ []) do
    now = Keyword.get(opts, :now, @off_peak_saturday)

    attrs
    |> Map.put_new(:requested_via, :manual)
    |> then(fn attrs ->
      SyncRun
      |> Ash.Changeset.for_create(:queue_manual_scoped, attrs)
      |> Ash.create(
        domain: Ingestion,
        context: %{scoped_manual_sync_now: now}
      )
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
