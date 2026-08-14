defmodule EventSales.Ingestion.HistoricalCatchupBootstrapTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCatchupBootstrap
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.TestSupport.SalesHelpers

  @source_url "https://store.example.test"
  @date_from ~U[2026-08-01 08:00:00.123456Z]
  @date_to ~U[2026-08-09 23:59:59.999999Z]
  @now ~U[2026-08-13 12:00:00.000000Z]
  @parent_observed_at ~U[2026-08-13 11:00:00.000000Z]

  defmodule Client do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(_opts),
      do:
        Agent.start_link(
          fn -> %{calls: [], response: {:ok, catchup_page()}, after_create: nil} end,
          name: __MODULE__
        )

    def reset!, do: reset!({:ok, catchup_page()})

    def reset!(response),
      do:
        Agent.update(__MODULE__, fn _ -> %{calls: [], response: response, after_create: nil} end)

    def after_create!(callback),
      do: Agent.update(__MODULE__, &Map.put(&1, :after_create, callback))

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def configured_base_url(_opts), do: {:ok, "https://store.example.test"}

    def create_catchup_manifest(parent_token, source_system_id, limit, _opts) do
      {response, callback} =
        Agent.get_and_update(__MODULE__, fn state ->
          {
            {state.response, state.after_create},
            Map.update!(state, :calls, fn calls ->
              [{parent_token, source_system_id, limit} | calls]
            end)
          }
        end)

      if is_function(callback, 0), do: callback.()

      response
    end

    defp catchup_page do
      %{
        "schema_version" => "2026-08-13.catchup.v1",
        "phase" => "catch_up",
        "boundary_token" => "child-manifest-token",
        "manifest_hash" => String.duplicate("b", 64),
        "manifest_expires_at_gmt" => "2026-08-13T13:00:00.000000Z",
        "source_observed_at_gmt" => "2026-08-13T12:00:00.000000Z",
        "items" => [],
        "has_more" => false,
        "terminal_evidence" => "child-terminal-proof"
      }
    end
  end

  setup do
    start_supervised!(Client)
    Client.reset!()

    source = SalesHelpers.create_source_system!(%{base_url: @source_url})

    event =
      SalesHelpers.create_event!(source, %{
        name: "Historical Catchup",
        slug: "historical-catchup-#{System.unique_integer([:positive])}",
        external_event_id: 81_500 + System.unique_integer([:positive]),
        external_event_kind: :tickera_event
      })

    event =
      Ash.update!(
        event,
        %{source_created_at: @date_from},
        action: :capture_source_created_at,
        domain: Catalog,
        context: %{event_sales_backfill_start_capture_authority: {Event, :verified}}
      )

    event = Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    run =
      SyncRun
      |> Ash.Changeset.for_create(:queue_historical_backfill, %{
        event_id: event.id,
        date_to: @date_to
      })
      |> Ash.Changeset.force_change_attribute(:source_system_id, source.id)
      |> Ash.Changeset.force_change_attribute(:date_from, @date_from)
      |> Ash.create!(domain: Ingestion)

    run = Ash.update!(run, %{}, action: :start, domain: Ingestion)

    cursor =
      SyncCursor
      |> Ash.Changeset.for_create(:upsert_active, %{
        sync_run_id: run.id,
        page: 1,
        modified_after: run.date_from,
        modified_before: run.date_to,
        last_seen_order_id: nil,
        metadata: parent_metadata()
      })
      |> Ash.create!(domain: Ingestion)

    {:ok, run: run, cursor: cursor, source: source, event: event}
  end

  test "terminal M authorizes one U and persists only pending child evidence", %{
    run: run,
    cursor: cursor,
    source: source
  } do
    assert {:ok, evidence} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id,
               client: Client,
               now: @now
             )

    assert evidence.state == "pending_first_page"
    assert Client.calls() == [{"parent-manifest-token", source.id, 100}]

    persisted = Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
    assert persisted.metadata["historical_manifest"] == parent_metadata()["historical_manifest"]
    assert persisted.metadata["historical_catchup"]["state"] == "pending_first_page"
    refute Map.has_key?(persisted.metadata["historical_catchup"], "next_cursor")
    refute inspect(persisted.metadata) =~ "child-terminal-proof"
    assert persisted.page == 1
    assert persisted.last_seen_order_id == nil
    assert persisted.status == :active
    assert Ash.get!(SyncRun, run.id, domain: Ingestion).status == :running
  end

  test "valid pending child evidence is reused without another POST", %{run: run} do
    assert {:ok, first} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)

    Client.reset!({:error, :unexpected_second_post})

    assert {:ok, second} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)

    assert second == first
    assert Client.calls() == []
  end

  test "an existing create claim is in doubt and cannot be rebuilt", %{run: run, cursor: cursor} do
    Ash.update!(
      cursor,
      %{metadata: Map.merge(parent_metadata(), HistoricalCatchupEvidence.claim_metadata())},
      action: :claim_catchup_create,
      domain: Ingestion
    )

    Client.reset!({:ok, catchup_page()})

    assert {:error, :catchup_create_in_doubt} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)

    assert Client.calls() == []
  end

  test "M must be terminal and unexpired before a catch-up claim", %{run: run, cursor: cursor} do
    in_progress =
      Map.put(parent_metadata(), "historical_manifest", %{
        parent_metadata()["historical_manifest"]
        | "state" => "manifest_in_progress"
      })

    Ash.update!(cursor, %{metadata: in_progress},
      action: :claim_catchup_create,
      domain: Ingestion
    )

    Client.reset!()

    assert {:error, :manifest_not_terminal} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)

    assert Client.calls() == []

    expired =
      put_in(
        parent_metadata()["historical_manifest"]["manifest_expires_at_gmt"],
        "2026-08-13T11:59:59.000000Z"
      )

    Ash.update!(cursor, %{metadata: expired}, action: :claim_catchup_create, domain: Ingestion)

    assert {:error, :manifest_expired} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)

    assert Client.calls() == []
  end

  test "high-water before D retains the claim and never retries", %{run: run, cursor: cursor} do
    Client.reset!({
      :ok,
      Map.put(catchup_page(), "source_observed_at_gmt", "2026-08-13T10:59:59.000000Z")
    })

    assert {:error, :catchup_high_water_before_parent} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)

    assert length(Client.calls()) == 1

    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata[
             "historical_catchup"
           ] == %{"state" => "create_claimed"}

    Client.reset!()

    assert {:error, :catchup_create_in_doubt} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)

    assert Client.calls() == []
  end

  test "source failure retains the claim and is not retried", %{run: run, cursor: cursor} do
    Client.reset!({
      :error,
      %EventSales.Ingestion.Clients.WooOrderIndexError{reason: :busy}
    })

    assert {:error, :busy} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)

    assert length(Client.calls()) == 1

    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata[
             "historical_catchup"
           ] == %{"state" => "create_claimed"}
  end

  test "local evidence persistence failure retains the claim", %{run: run, cursor: cursor} do
    assert {:error, :catchup_evidence_persist_failed} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id,
               client: Client,
               now: @now,
               test_evidence_persister: fn _cursor, _metadata -> {:error, :database_failure} end
             )

    assert length(Client.calls()) == 1

    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata[
             "historical_catchup"
           ] == %{"state" => "create_claimed"}
  end

  test "event invalidation after POST fails closed without child evidence", %{
    run: run,
    cursor: cursor,
    event: event
  } do
    Client.after_create!(fn ->
      Ash.update!(event, %{}, action: :invalidate_onboarding, domain: Catalog)
    end)

    assert {:error, {:historical_event_not_backfill_pending, :unverified}} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)

    persisted = Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
    assert persisted.metadata["historical_catchup"] == %{"state" => "create_claimed"}
    assert length(Client.calls()) == 1
  end

  test "concurrent callers authorize at most one catch-up POST", %{run: run, cursor: cursor} do
    parent = self()

    Client.after_create!(fn ->
      send(parent, {:catchup_post_started, self()})

      receive do
        :release_catchup_post -> :ok
      after
        5_000 -> :ok
      end
    end)

    tasks =
      for _caller <- 1..2 do
        Task.async(fn ->
          HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)
        end)
      end

    assert_receive {:catchup_post_started, post_pid}, 5_000

    assert Ash.get!(SyncCursor, cursor.id, domain: Ingestion).metadata[
             "historical_catchup"
           ] == %{"state" => "create_claimed"}

    send(post_pid, :release_catchup_post)
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.all?(results, fn
             {:ok, _evidence} -> true
             {:error, :catchup_create_in_doubt} -> true
           end)

    assert Enum.any?(results, &match?({:ok, _evidence}, &1))
    assert length(Client.calls()) == 1
  end

  test "corrupt and expired child evidence fail closed without rebuilding", %{
    run: run,
    cursor: cursor
  } do
    corrupt = Map.put(parent_metadata(), "historical_catchup", %{"state" => "pending_first_page"})
    Ash.update!(cursor, %{metadata: corrupt}, action: :record_catchup_evidence, domain: Ingestion)

    Client.reset!()

    assert {:error, :corrupt_catchup_evidence} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)

    assert Client.calls() == []

    expired_child = %{
      "historical_catchup" => %{
        "schema_version" => "2026-08-13.catchup.v1",
        "phase" => "catch_up",
        "boundary_token" => "child-manifest-token",
        "manifest_hash" => String.duplicate("b", 64),
        "manifest_expires_at_gmt" => "2026-08-13T11:59:59.000000Z",
        "source_observed_at_gmt" => "2026-08-13T12:00:00.000000Z",
        "state" => "pending_first_page"
      }
    }

    Ash.update!(
      cursor,
      %{metadata: Map.merge(parent_metadata(), expired_child)},
      action: :record_catchup_evidence,
      domain: Ingestion
    )

    assert {:error, :catchup_manifest_expired} =
             HistoricalCatchupBootstrap.ensure_catchup(run.id, client: Client, now: @now)

    assert Client.calls() == []
  end

  test "catch-up cursor actions change only metadata", %{run: run, cursor: cursor} do
    claim = HistoricalCatchupEvidence.claim_metadata()

    assert {:ok, claimed} =
             Ash.update(cursor, %{metadata: Map.merge(parent_metadata(), claim)},
               action: :claim_catchup_create,
               domain: Ingestion
             )

    assert claimed.page == cursor.page
    assert claimed.modified_after == cursor.modified_after
    assert claimed.modified_before == cursor.modified_before
    assert claimed.last_seen_order_id == cursor.last_seen_order_id
    assert claimed.status == cursor.status
    assert claimed.sync_run_id == run.id
  end

  defp catchup_page do
    %{
      "schema_version" => "2026-08-13.catchup.v1",
      "phase" => "catch_up",
      "boundary_token" => "child-manifest-token",
      "manifest_hash" => String.duplicate("b", 64),
      "manifest_expires_at_gmt" => "2026-08-13T13:00:00.000000Z",
      "source_observed_at_gmt" => "2026-08-13T12:00:00.000000Z",
      "items" => [],
      "has_more" => false,
      "terminal_evidence" => "child-terminal-proof"
    }
  end

  defp parent_metadata do
    %{
      "historical_manifest" => %{
        "schema_version" => "2026-08-12.v1",
        "phase" => "manifest_enumerate",
        "boundary_token" => "parent-manifest-token",
        "manifest_hash" => String.duplicate("a", 64),
        "manifest_expires_at_gmt" => "2026-08-13T13:00:00.000000Z",
        "source_observed_at_gmt" => DateTime.to_iso8601(@parent_observed_at),
        "state" => "manifest_terminal",
        "terminal_evidence" => "parent-terminal-proof"
      }
    }
  end
end
