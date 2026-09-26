defmodule EventSales.Analytics.SourceFreshnessTest do
  use EventSales.DataCase, async: false

  import Ecto.Query

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias EventSales.Analytics.Resources.EventSourceFreshnessSnapshot
  alias EventSales.Analytics.SourceFreshness
  alias EventSales.Catalog.Resources.{Event, SourceSystem}
  alias EventSales.Repo
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

    test "classifies using TimeRules boundaries", %{event: event} do
      anchor = ~U[2026-05-01 10:00:00.000000Z]
      now = DateTime.add(anchor, 4, :minute)

      advance_order!(event.id, anchor, ~U[2026-05-01 12:00:00.000000Z])

      assert {:ok, %{classification: :normal, anchor_at: ^anchor, age_ms: 240_000}} =
               SourceFreshness.for_event(event.id, now: now)
    end

    test "future anchor clamps to normal per TimeRules", %{event: event} do
      now = ~U[2026-05-01 10:00:00.000000Z]
      anchor = DateTime.add(now, 30, :second)

      advance_order!(event.id, anchor, now)

      assert {:ok, %{classification: :normal, anchor_at: ^anchor, age_ms: 0}} =
               SourceFreshness.for_event(event.id, now: now)
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

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
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
