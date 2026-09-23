defmodule EventSales.Analytics.EventAggregateSnapshotConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias EventSales.Analytics.Resources.EventAggregateSnapshot
  alias EventSales.Catalog.Resources.{Event, SourceSystem}
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  @unique_index "analytics_event_aggregate_snapshots_unique_event_currency_index"

  @tag :snapshot_unique_race
  test "independent PostgreSQL transactions arbitrate duplicate event and currency creates" do
    fixture = create_committed_event!()

    on_exit(fn -> cleanup_committed_event!(fixture) end)

    parent = self()

    winner =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          backend_pid = backend_pid!()
          send(parent, {:snapshot_race_ready, :winner, self(), backend_pid})

          receive do
            :create ->
              Repo.transaction(fn ->
                case create_event_snapshot(fixture.event_id) do
                  {:ok, snapshot} ->
                    send(parent, {:snapshot_race_inserted, self(), snapshot})

                    receive do
                      :commit -> snapshot
                    after
                      15_000 -> Repo.rollback(:snapshot_race_commit_timeout)
                    end

                  {:error, reason} ->
                    Repo.rollback(reason)
                end
              end)
          after
            15_000 -> {:error, :snapshot_race_insert_timeout}
          end
        end)
      end)

    contender =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          backend_pid = backend_pid!()
          send(parent, {:snapshot_race_ready, :contender, self(), backend_pid})

          receive do
            :create -> create_event_snapshot(fixture.event_id)
          after
            15_000 -> {:error, :snapshot_race_insert_timeout}
          end
        end)
      end)

    assert_receive {:snapshot_race_ready, :winner, winner_pid, winner_backend}, 5_000

    assert_receive {:snapshot_race_ready, :contender, contender_pid, contender_backend},
                   5_000

    refute winner_backend == contender_backend

    send(winner_pid, :create)
    assert_receive {:snapshot_race_inserted, ^winner_pid, %EventAggregateSnapshot{}}, 5_000

    send(contender_pid, :create)
    assert_backend_waiting_on_lock!(contender_backend)
    send(winner_pid, :commit)

    assert {:ok, %EventAggregateSnapshot{}} = Task.await(winner, 15_000)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Task.await(contender, 15_000)

    assert Enum.any?(errors, fn
             %Ash.Error.Changes.InvalidAttribute{private_vars: vars} ->
               Keyword.get(vars, :constraint) == @unique_index

             _other ->
               false
           end)

    durable_row_count =
      with_unboxed_connection(fn ->
        EventAggregateSnapshot
        |> Ash.Query.filter(event_id == ^fixture.event_id and currency == "ZAR")
        |> Ash.count!(domain: EventSales.Analytics)
      end)

    assert durable_row_count == 1
  end

  defp create_committed_event! do
    suffix = System.unique_integer([:positive])

    with_unboxed_connection(fn ->
      source =
        SalesHelpers.create_source_system!(%{
          name: "Snapshot race source #{suffix}",
          base_url: "https://snapshot-race-#{suffix}.example.test"
        })

      event =
        SalesHelpers.create_event!(source, %{
          name: "Snapshot race event #{suffix}",
          slug: "snapshot-race-#{suffix}"
        })

      %{event_id: event.id, source_id: source.id}
    end)
  end

  defp create_event_snapshot(event_id) do
    Ash.create(
      EventAggregateSnapshot,
      %{
        event_id: event_id,
        total_sold: 0,
        total_revenue: Decimal.new("0"),
        today_sold: 0,
        today_revenue: Decimal.new("0"),
        currency: "ZAR",
        business_timezone: "Africa/Johannesburg",
        refreshed_at: ~U[2026-05-18 08:00:00.000000Z],
        source_row_count: 0,
        snapshot_version: 1
      },
      action: :create_snapshot,
      domain: EventSales.Analytics
    )
  end

  defp cleanup_committed_event!(%{event_id: event_id, source_id: source_id}) do
    with_unboxed_connection(fn ->
      Repo.delete_all(
        from(snapshot in EventAggregateSnapshot, where: snapshot.event_id == ^event_id)
      )

      Repo.delete_all(from(event in Event, where: event.id == ^event_id))
      Repo.delete_all(from(source in SourceSystem, where: source.id == ^source_id))
    end)
  end

  defp assert_backend_waiting_on_lock!(backend_pid, attempts \\ 80)

  defp assert_backend_waiting_on_lock!(_backend_pid, 0),
    do: flunk("contending PostgreSQL transaction did not wait on the unique identity")

  defp assert_backend_waiting_on_lock!(backend_pid, attempts) do
    waiting? =
      with_unboxed_connection(fn ->
        %{rows: [[wait_event_type]]} =
          Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid])

        wait_event_type == "Lock"
      end)

    if waiting? do
      :ok
    else
      receive do
      after
        25 -> assert_backend_waiting_on_lock!(backend_pid, attempts - 1)
      end
    end
  end

  defp with_unboxed_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    backend_pid
  end
end
