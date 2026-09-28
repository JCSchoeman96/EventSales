defmodule EventSales.Analytics.SourceFreshnessTest do
  use EventSales.DataCase, async: false

  import Ecto.Query

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias EventSales.Analytics.DashboardPubSub
  alias EventSales.Analytics.Resources.EventSourceFreshnessSnapshot
  alias EventSales.Analytics.SourceFreshness
  alias EventSales.Catalog.Resources.{Event, SourceSystem}
  alias EventSales.Repo
  alias EventSales.Telemetry, as: EventSalesTelemetry
  alias EventSales.TestSupport.SalesHelpers

  @upsert_opts [return_skipped_upsert?: true, domain: EventSales.Analytics]

  describe "for_event/2" do
    setup do
      source = SalesHelpers.create_source_system!()

      event =
        SalesHelpers.create_event!(source, %{name: "Freshness Event", slug: unique_slug("fresh")})

      %{event: event, source: source}
    end

    test "missing row returns missing anchor error", %{event: event} do
      assert SourceFreshness.for_event(event.id) == {:error, :missing_source_freshness_anchor}
    end

    test "row with all nil component watermarks returns missing anchor error", %{event: event} do
      refreshed = ~U[2026-05-01 10:00:00.000000Z]

      {1, _} =
        Repo.insert_all("analytics_event_source_freshness_snapshots", [
          %{
            id: Ecto.UUID.bingenerate(),
            event_id: Ecto.UUID.dump!(event.id),
            projection_refreshed_at: refreshed,
            projection_version: 1,
            inserted_at: refreshed,
            updated_at: refreshed
          }
        ])

      assert SourceFreshness.for_event(event.id, now: refreshed) ==
               {:error, :missing_source_freshness_anchor}
    end

    test "classifies using TimeRules boundaries", %{event: event} do
      handler_id = telemetry_handler_id()
      attach_clock_skew_handler(handler_id)

      anchor = ~U[2026-05-01 10:00:00.000000Z]
      now = DateTime.add(anchor, 4, :minute)

      advance_order!(event.id, anchor, ~U[2026-05-01 12:00:00.000000Z])

      assert {:ok, %{classification: :normal, anchor_at: ^anchor, age_ms: 240_000}} =
               SourceFreshness.for_event(event.id, now: now)

      refute_receive {:source_freshness_clock_skew, _, _}, 50
    end

    test "future anchor clamps to normal per TimeRules and emits clock-skew telemetry", %{
      event: event
    } do
      handler_id = telemetry_handler_id()
      attach_clock_skew_handler(handler_id)

      now = ~U[2026-05-01 10:00:00.000000Z]
      anchor = DateTime.add(now, 30, :second)

      advance_order!(event.id, anchor, now)

      assert {:ok, %{classification: :normal, anchor_at: ^anchor, age_ms: 0}} =
               SourceFreshness.for_event(event.id, now: now)

      assert_receive {:source_freshness_clock_skew,
                      [:event_sales, :source_freshness, :clock_skew], %{count: 1},
                      %{scope: :event}}
    end

    test "anchor is max of present components", %{event: event} do
      order_at = ~U[2026-05-01 10:00:00.000000Z]
      refund_at = ~U[2026-05-01 11:00:00.000000Z]
      sync_at = ~U[2026-05-01 09:00:00.000000Z]
      refreshed = ~U[2026-05-01 12:00:00.000000Z]

      advance_order!(event.id, order_at, refreshed)
      advance_refund!(event.id, refund_at, refreshed)
      advance_sync!(event.id, sync_at, refreshed)

      assert {:ok, %{anchor_at: ^refund_at}} = SourceFreshness.for_event(event.id, now: refreshed)
    end
  end

  describe "advance_order/2" do
    setup do
      source = SalesHelpers.create_source_system!()

      event =
        SalesHelpers.create_event!(source, %{
          name: "Order Freshness",
          slug: unique_slug("order-fresh")
        })

      %{event: event}
    end

    test "first and newer watermarks persist the order source clock and broadcast once", %{
      event: event
    } do
      assert :ok = DashboardPubSub.subscribe_event(event.id)

      first_watermark = ~U[2026-05-01 10:00:00.000000Z]
      newer_watermark = ~U[2026-05-01 11:00:00.000000Z]

      assert :ok = SourceFreshness.advance_order(event.id, first_watermark)

      assert_receive {:source_freshness_updated, event_id}, 500
      assert event_id == event.id

      assert {:ok, first_snapshot} = read_snapshot(event.id)
      assert first_snapshot.order_source_watermark_at == first_watermark
      assert %DateTime{} = first_snapshot.projection_refreshed_at

      assert :ok = SourceFreshness.advance_order(event.id, newer_watermark)

      assert_receive {:source_freshness_updated, event_id}, 500
      assert event_id == event.id

      assert {:ok, newer_snapshot} = read_snapshot(event.id)
      assert newer_snapshot.order_source_watermark_at == newer_watermark

      assert DateTime.compare(
               newer_snapshot.projection_refreshed_at,
               first_snapshot.projection_refreshed_at
             ) in [
               :eq,
               :gt
             ]

      refute_receive {:source_freshness_updated, _event_id}, 0
    end

    test "equal replay preserves the watermark and projection metadata without a broadcast", %{
      event: event
    } do
      event_id = event.id
      watermark = ~U[2026-05-01 10:00:00.000000Z]

      assert :ok = DashboardPubSub.subscribe_event(event_id)
      assert :ok = SourceFreshness.advance_order(event_id, watermark)
      assert_receive {:source_freshness_updated, ^event_id}, 500

      assert {:ok, first_snapshot} = read_snapshot(event_id)
      assert :ok = SourceFreshness.advance_order(event_id, watermark)
      assert {:ok, replayed_snapshot} = read_snapshot(event_id)

      assert replayed_snapshot.order_source_watermark_at ==
               first_snapshot.order_source_watermark_at

      assert replayed_snapshot.projection_refreshed_at == first_snapshot.projection_refreshed_at
      refute_receive {:source_freshness_updated, _event_id}, 0
    end

    test "older replay preserves the watermark and projection metadata without a broadcast", %{
      event: event
    } do
      event_id = event.id
      newer_watermark = ~U[2026-05-01 11:00:00.000000Z]
      older_watermark = ~U[2026-05-01 10:00:00.000000Z]

      assert :ok = DashboardPubSub.subscribe_event(event_id)
      assert :ok = SourceFreshness.advance_order(event_id, newer_watermark)
      assert_receive {:source_freshness_updated, ^event_id}, 500

      assert {:ok, first_snapshot} = read_snapshot(event_id)
      assert :ok = SourceFreshness.advance_order(event_id, older_watermark)
      assert {:ok, stale_snapshot} = read_snapshot(event_id)

      assert stale_snapshot.order_source_watermark_at == first_snapshot.order_source_watermark_at
      assert stale_snapshot.projection_refreshed_at == first_snapshot.projection_refreshed_at
      refute_receive {:source_freshness_updated, _event_id}, 0
    end

    test "database failure returns an error and does not broadcast" do
      event_id = Ecto.UUID.generate()
      watermark = ~U[2026-05-01 10:00:00.000000Z]

      assert :ok = DashboardPubSub.subscribe_event(event_id)
      assert {:error, _reason} = SourceFreshness.advance_order(event_id, watermark)
      refute_receive {:source_freshness_updated, _event_id}, 0
    end
  end

  describe "advance_refund/2" do
    setup do
      source = SalesHelpers.create_source_system!()

      event =
        SalesHelpers.create_event!(source, %{
          name: "Refund Freshness",
          slug: unique_slug("refund-fresh")
        })

      %{event: event}
    end

    test "first and newer refund watermarks persist and broadcast once per advance", %{
      event: event
    } do
      assert :ok = DashboardPubSub.subscribe_event(event.id)

      first_watermark = ~U[2026-05-01 10:00:00.000000Z]
      newer_watermark = ~U[2026-05-01 11:00:00.000000Z]

      assert :ok = SourceFreshness.advance_refund(event.id, first_watermark)
      assert_receive {:source_freshness_updated, event_id}
      assert event_id == event.id

      assert {:ok, first_snapshot} = read_snapshot(event.id)
      assert first_snapshot.refund_source_watermark_at == first_watermark
      assert %DateTime{} = first_snapshot.projection_refreshed_at

      assert :ok = SourceFreshness.advance_refund(event.id, newer_watermark)
      assert_receive {:source_freshness_updated, event_id}
      assert event_id == event.id

      assert {:ok, newer_snapshot} = read_snapshot(event.id)
      assert newer_snapshot.refund_source_watermark_at == newer_watermark
      refute_receive {:source_freshness_updated, _event_id}, 0
    end

    test "equal and older replay preserve the watermark and metadata without broadcasts", %{
      event: event
    } do
      event_id = event.id
      newer_watermark = ~U[2026-05-01 11:00:00.000000Z]

      assert :ok = DashboardPubSub.subscribe_event(event_id)
      assert :ok = SourceFreshness.advance_refund(event_id, newer_watermark)
      assert_receive {:source_freshness_updated, ^event_id}

      assert {:ok, first_snapshot} = read_snapshot(event_id)
      assert :ok = SourceFreshness.advance_refund(event_id, newer_watermark)
      assert :ok = SourceFreshness.advance_refund(event_id, ~U[2026-05-01 10:00:00.000000Z])
      assert {:ok, replayed_snapshot} = read_snapshot(event_id)

      assert replayed_snapshot.refund_source_watermark_at ==
               first_snapshot.refund_source_watermark_at

      assert replayed_snapshot.projection_refreshed_at == first_snapshot.projection_refreshed_at
      refute_receive {:source_freshness_updated, _event_id}, 0
    end

    test "refund advancement preserves order and sync components", %{event: event} do
      order_watermark = ~U[2026-05-01 09:00:00.000000Z]
      sync_observed_at = ~U[2026-05-01 08:00:00.000000Z]
      refund_watermark = ~U[2026-05-01 10:00:00.000000Z]
      refreshed_at = ~U[2026-05-01 12:00:00.000000Z]

      assert {:ok, _} = advance_order!(event.id, order_watermark, refreshed_at)
      assert {:ok, _} = advance_sync!(event.id, sync_observed_at, refreshed_at)
      assert :ok = SourceFreshness.advance_refund(event.id, refund_watermark)

      assert {:ok, snapshot} = read_snapshot(event.id)
      assert snapshot.refund_source_watermark_at == refund_watermark
      assert snapshot.order_source_watermark_at == order_watermark
      assert snapshot.sync_source_observed_at == sync_observed_at
    end

    test "rejects invalid event ids and timestamps" do
      assert {:error, :invalid_event_id} =
               SourceFreshness.advance_refund("not-a-uuid", ~U[2026-05-01 10:00:00.000000Z])

      assert {:error, _reason} = SourceFreshness.advance_refund(Ecto.UUID.generate(), nil)
    end

    test "database failure returns an error and does not broadcast" do
      event_id = Ecto.UUID.generate()
      watermark = ~U[2026-05-01 10:00:00.000000Z]

      assert :ok = DashboardPubSub.subscribe_event(event_id)
      assert {:error, _reason} = SourceFreshness.advance_refund(event_id, watermark)
      refute_receive {:source_freshness_updated, _event_id}, 0
    end
  end

  describe "advance_sync_source_observed/2" do
    setup do
      source = SalesHelpers.create_source_system!()

      event =
        SalesHelpers.create_event!(source, %{
          name: "Sync Freshness",
          slug: unique_slug("sync-fresh")
        })

      %{event: event}
    end

    test "first and newer sync observations persist and broadcast once per advance", %{
      event: event
    } do
      assert :ok = DashboardPubSub.subscribe_event(event.id)

      first_observed_at = ~U[2026-05-01 10:00:00.000000Z]
      newer_observed_at = ~U[2026-05-01 11:00:00.000000Z]

      assert :ok = SourceFreshness.advance_sync_source_observed(event.id, first_observed_at)
      assert_receive {:source_freshness_updated, event_id}
      assert event_id == event.id

      assert {:ok, first_snapshot} = read_snapshot(event.id)
      assert first_snapshot.sync_source_observed_at == first_observed_at
      assert %DateTime{} = first_snapshot.projection_refreshed_at

      assert :ok = SourceFreshness.advance_sync_source_observed(event.id, newer_observed_at)
      assert_receive {:source_freshness_updated, event_id}
      assert event_id == event.id

      assert {:ok, newer_snapshot} = read_snapshot(event.id)
      assert newer_snapshot.sync_source_observed_at == newer_observed_at

      assert DateTime.compare(
               newer_snapshot.projection_refreshed_at,
               first_snapshot.projection_refreshed_at
             ) in [:eq, :gt]

      refute_receive {:source_freshness_updated, _event_id}, 0
    end

    test "equal and older replays preserve sync watermark and projection metadata", %{
      event: event
    } do
      event_id = event.id
      newer_observed_at = ~U[2026-05-01 11:00:00.000000Z]

      assert :ok = DashboardPubSub.subscribe_event(event_id)
      assert :ok = SourceFreshness.advance_sync_source_observed(event_id, newer_observed_at)
      assert_receive {:source_freshness_updated, ^event_id}

      assert {:ok, first_snapshot} = read_snapshot(event_id)

      assert :ok = SourceFreshness.advance_sync_source_observed(event_id, newer_observed_at)

      assert :ok =
               SourceFreshness.advance_sync_source_observed(
                 event_id,
                 ~U[2026-05-01 10:00:00.000000Z]
               )

      assert {:ok, replayed_snapshot} = read_snapshot(event_id)
      assert replayed_snapshot.sync_source_observed_at == first_snapshot.sync_source_observed_at
      assert replayed_snapshot.projection_refreshed_at == first_snapshot.projection_refreshed_at
      refute_receive {:source_freshness_updated, _event_id}, 0
    end

    test "sync advancement preserves order and refund components", %{event: event} do
      order_watermark = ~U[2026-05-01 09:00:00.000000Z]
      refund_watermark = ~U[2026-05-01 10:00:00.000000Z]
      sync_observed_at = ~U[2026-05-01 11:00:00.000000Z]
      refreshed_at = ~U[2026-05-01 12:00:00.000000Z]

      assert {:ok, _} = advance_order!(event.id, order_watermark, refreshed_at)
      assert {:ok, _} = advance_refund!(event.id, refund_watermark, refreshed_at)
      assert :ok = SourceFreshness.advance_sync_source_observed(event.id, sync_observed_at)

      assert {:ok, snapshot} = read_snapshot(event.id)
      assert snapshot.order_source_watermark_at == order_watermark
      assert snapshot.refund_source_watermark_at == refund_watermark
      assert snapshot.sync_source_observed_at == sync_observed_at
    end

    test "rejects invalid event ids and timestamps" do
      assert {:error, :invalid_event_id} =
               SourceFreshness.advance_sync_source_observed(
                 "not-a-uuid",
                 ~U[2026-05-01 10:00:00.000000Z]
               )

      assert {:error, _reason} =
               SourceFreshness.advance_sync_source_observed(Ecto.UUID.generate(), nil)
    end

    test "database failure returns an error and does not broadcast" do
      event_id = Ecto.UUID.generate()
      observed_at = ~U[2026-05-01 10:00:00.000000Z]

      assert :ok = DashboardPubSub.subscribe_event(event_id)

      assert {:error, _reason} =
               SourceFreshness.advance_sync_source_observed(event_id, observed_at)

      refute_receive {:source_freshness_updated, _event_id}, 0
    end
  end

  describe "durable projection lifecycle" do
    setup do
      source = SalesHelpers.create_source_system!()

      event =
        SalesHelpers.create_event!(source, %{name: "Lifecycle Event", slug: unique_slug("life")})

      %{event: event, source: source}
    end

    test "exactly one row per event", %{event: event} do
      t1 = ~U[2026-05-01 10:00:00.000000Z]
      t2 = ~U[2026-05-01 11:00:00.000000Z]
      refreshed = ~U[2026-05-01 12:00:00.000000Z]

      assert {:ok, _} = advance_order!(event.id, t1, refreshed)
      assert {:ok, _} = advance_order!(event.id, t2, refreshed)
      assert {:ok, _} = advance_refund!(event.id, t1, refreshed)

      assert count_rows(event.id) == 1
    end

    test "first component creates projection", %{event: event} do
      watermark = ~U[2026-05-01 10:00:00.000000Z]
      refreshed = ~U[2026-05-01 10:05:00.000000Z]

      assert {:ok, snapshot} = advance_order!(event.id, watermark, refreshed)

      assert snapshot.order_source_watermark_at == watermark
      assert snapshot.projection_refreshed_at == refreshed
      assert {:ok, %{anchor_at: ^watermark}} = SourceFreshness.for_event(event.id, now: refreshed)
    end

    test "newer same-component timestamp advances", %{event: event} do
      older = ~U[2026-05-01 10:00:00.000000Z]
      newer = ~U[2026-05-01 11:00:00.000000Z]
      refreshed_old = ~U[2026-05-01 10:05:00.000000Z]
      refreshed_new = ~U[2026-05-01 11:05:00.000000Z]

      assert {:ok, _} = advance_order!(event.id, older, refreshed_old)
      assert {:ok, snapshot} = advance_order!(event.id, newer, refreshed_new)

      assert snapshot.order_source_watermark_at == newer
      assert snapshot.projection_refreshed_at == refreshed_new
    end

    test "equal replay is idempotent", %{event: event} do
      watermark = ~U[2026-05-01 10:00:00.000000Z]
      refreshed = ~U[2026-05-01 10:05:00.000000Z]

      assert {:ok, first} = advance_order!(event.id, watermark, refreshed)
      assert {:ok, second} = advance_order!(event.id, watermark, refreshed)

      assert second.order_source_watermark_at == watermark
      assert second.projection_refreshed_at == refreshed
      assert second.id == first.id
      assert Ash.Resource.get_metadata(second, :upsert_skipped) == true
    end

    test "older replay cannot regress component or projection metadata", %{event: event} do
      newer = ~U[2026-05-01 11:00:00.000000Z]
      older = ~U[2026-05-01 10:00:00.000000Z]
      refreshed_new = ~U[2026-05-01 11:05:00.000000Z]
      stale_refresh = ~U[2026-05-01 09:00:00.000000Z]

      assert {:ok, _} = advance_order!(event.id, newer, refreshed_new)
      assert {:ok, snapshot} = advance_order!(event.id, older, stale_refresh)

      assert snapshot.order_source_watermark_at == newer
      assert snapshot.projection_refreshed_at == refreshed_new
      assert Ash.Resource.get_metadata(snapshot, :upsert_skipped) == true
    end

    test "independent order refund and sync components coexist", %{event: event} do
      order_at = ~U[2026-05-01 10:00:00.000000Z]
      refund_at = ~U[2026-05-01 11:00:00.000000Z]
      sync_at = ~U[2026-05-01 12:00:00.000000Z]
      refreshed = ~U[2026-05-01 12:30:00.000000Z]

      assert {:ok, _} = advance_order!(event.id, order_at, refreshed)
      assert {:ok, _} = advance_refund!(event.id, refund_at, refreshed)
      assert {:ok, snapshot} = advance_sync!(event.id, sync_at, refreshed)

      assert snapshot.order_source_watermark_at == order_at
      assert snapshot.refund_source_watermark_at == refund_at
      assert snapshot.sync_source_observed_at == sync_at
    end

    test "different events remain isolated", %{event: event, source: source} do
      other =
        SalesHelpers.create_event!(source, %{
          name: "Other Freshness",
          slug: unique_slug("other-f")
        })

      watermark = ~U[2026-05-01 10:00:00.000000Z]
      refreshed = ~U[2026-05-01 10:05:00.000000Z]

      assert {:ok, _} = advance_order!(event.id, watermark, refreshed)
      assert SourceFreshness.for_event(other.id) == {:error, :missing_source_freshness_anchor}
    end
  end

  describe "concurrent postgres writes" do
    @tag :source_freshness_concurrency
    test "concurrent first inserts for same event resolve to one row" do
      fixture = create_committed_event!()

      try do
        watermark = ~U[2026-05-01 10:00:00.000000Z]
        refreshed = ~U[2026-05-01 10:05:00.000000Z]

        parent = self()

        tasks =
          for _ <- 1..8 do
            Task.async(fn ->
              with_unboxed_connection(fn ->
                send(parent, :race_worker_ready)

                advance_order!(fixture.event_id, watermark, refreshed)
              end)
            end)
          end

        for _ <- 1..8, do: assert_receive(:race_worker_ready, 5_000)

        results = Task.await_many(tasks, 15_000)

        assert Enum.all?(results, &match?({:ok, %EventSourceFreshnessSnapshot{}}, &1))

        assert with_unboxed_connection(fn -> count_rows(fixture.event_id) end) == 1

        assert with_unboxed_connection(fn ->
                 EventSourceFreshnessSnapshot
                 |> Ash.Query.filter(event_id == ^fixture.event_id)
                 |> Ash.read_one!(domain: EventSales.Analytics)
                 |> Map.get(:order_source_watermark_at)
               end) == watermark
      after
        cleanup_committed_event!(fixture)
      end
    end

    @tag :source_freshness_concurrency
    test "concurrent same-component writes keep maximum timestamp" do
      fixture = create_committed_event!()

      try do
        base = ~U[2026-05-01 10:00:00.000000Z]
        refreshed = ~U[2026-05-01 12:00:00.000000Z]

        candidates =
          for offset <- 1..12 do
            DateTime.add(base, offset, :second)
          end

        parent = self()

        tasks =
          for watermark <- candidates do
            Task.async(fn ->
              with_unboxed_connection(fn ->
                send(parent, :race_worker_ready)
                advance_order!(fixture.event_id, watermark, refreshed)
              end)
            end)
          end

        for _ <- candidates, do: assert_receive(:race_worker_ready, 5_000)

        assert Enum.all?(Task.await_many(tasks, 15_000), &match?({:ok, _}, &1))

        expected_max = Enum.max_by(candidates, &DateTime.to_unix(&1, :microsecond))

        persisted =
          with_unboxed_connection(fn ->
            EventSourceFreshnessSnapshot
            |> Ash.Query.filter(event_id == ^fixture.event_id)
            |> Ash.read_one!(domain: EventSales.Analytics)
          end)

        assert persisted.order_source_watermark_at == expected_max
        assert count_rows(fixture.event_id) == 1
      after
        cleanup_committed_event!(fixture)
      end
    end

    @tag :source_freshness_concurrency
    test "concurrent order and refund writes preserve both components" do
      fixture = create_committed_event!()

      try do
        order_at = ~U[2026-05-01 10:00:00.000000Z]
        refund_at = ~U[2026-05-01 11:00:00.000000Z]
        refreshed = ~U[2026-05-01 12:00:00.000000Z]

        parent = self()

        order_task =
          Task.async(fn ->
            with_unboxed_connection(fn ->
              send(parent, {:race_ready, :order})
              advance_order!(fixture.event_id, order_at, refreshed)
            end)
          end)

        refund_task =
          Task.async(fn ->
            with_unboxed_connection(fn ->
              send(parent, {:race_ready, :refund})
              advance_refund!(fixture.event_id, refund_at, refreshed)
            end)
          end)

        assert_receive {:race_ready, :order}, 5_000
        assert_receive {:race_ready, :refund}, 5_000

        assert {:ok, %EventSourceFreshnessSnapshot{}} = Task.await(order_task, 15_000)
        assert {:ok, %EventSourceFreshnessSnapshot{}} = Task.await(refund_task, 15_000)

        snapshot =
          with_unboxed_connection(fn ->
            EventSourceFreshnessSnapshot
            |> Ash.Query.filter(event_id == ^fixture.event_id)
            |> Ash.read_one!(domain: EventSales.Analytics)
          end)

        assert snapshot.order_source_watermark_at == order_at
        assert snapshot.refund_source_watermark_at == refund_at
        assert count_rows(fixture.event_id) == 1
      after
        cleanup_committed_event!(fixture)
      end
    end
  end

  defp advance_order!(event_id, watermark, refreshed_at) do
    Ash.create(
      EventSourceFreshnessSnapshot,
      %{
        event_id: event_id,
        order_source_watermark_at: watermark,
        projection_refreshed_at: refreshed_at
      },
      Keyword.merge(@upsert_opts, action: :advance_order_watermark)
    )
  end

  defp advance_refund!(event_id, watermark, refreshed_at) do
    Ash.create(
      EventSourceFreshnessSnapshot,
      %{
        event_id: event_id,
        refund_source_watermark_at: watermark,
        projection_refreshed_at: refreshed_at
      },
      Keyword.merge(@upsert_opts, action: :advance_refund_watermark)
    )
  end

  defp advance_sync!(event_id, observed_at, refreshed_at) do
    Ash.create(
      EventSourceFreshnessSnapshot,
      %{
        event_id: event_id,
        sync_source_observed_at: observed_at,
        projection_refreshed_at: refreshed_at
      },
      Keyword.merge(@upsert_opts, action: :advance_sync_source_observed)
    )
  end

  defp count_rows(event_id) do
    EventSourceFreshnessSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.count!(domain: EventSales.Analytics)
  end

  defp read_snapshot(event_id) do
    EventSourceFreshnessSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.read_one(domain: EventSales.Analytics)
  end

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp telemetry_handler_id do
    "source-freshness-telemetry-#{System.unique_integer([:positive])}"
  end

  defp attach_clock_skew_handler(handler_id) do
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        EventSalesTelemetry.source_freshness_clock_skew(),
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:source_freshness_clock_skew, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp create_committed_event! do
    suffix = System.unique_integer([:positive])

    with_unboxed_connection(fn ->
      source =
        SalesHelpers.create_source_system!(%{
          name: "Freshness race source #{suffix}",
          base_url: "https://freshness-race-#{suffix}.example.test"
        })

      event =
        SalesHelpers.create_event!(source, %{
          name: "Freshness race event #{suffix}",
          slug: "freshness-race-#{suffix}"
        })

      %{event_id: event.id, source_id: source.id}
    end)
  end

  defp cleanup_committed_event!(%{event_id: event_id, source_id: source_id}) do
    with_unboxed_connection(fn ->
      Repo.delete_all(
        from(snapshot in EventSourceFreshnessSnapshot, where: snapshot.event_id == ^event_id)
      )

      Repo.delete_all(from(event in Event, where: event.id == ^event_id))
      Repo.delete_all(from(source in SourceSystem, where: source.id == ^source_id))
    end)
  end

  defp with_unboxed_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end
end
