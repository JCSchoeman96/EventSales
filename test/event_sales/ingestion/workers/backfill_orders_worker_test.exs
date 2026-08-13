defmodule EventSales.Ingestion.Workers.BackfillOrdersWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Ingestion.Workers.BackfillOrdersWorker
  alias EventSales.TestSupport.SalesHelpers

  @date_from ~U[2026-08-01 08:00:00.123456Z]
  @date_to ~U[2026-08-09 23:59:59.999999Z]
  @now ~U[2026-08-13 12:00:00.000000Z]

  defmodule BootstrapFake do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], calls: []} end, name: __MODULE__)

    def reset!, do: Agent.update(__MODULE__, fn _ -> %{responses: [], calls: []} end)

    def put_response!(response),
      do: Agent.update(__MODULE__, &Map.update!(&1, :responses, fn xs -> xs ++ [response] end))

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def ensure_manifest(run_id, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = List.first(state.responses) || {:ok, :evidence}
        responses = if state.responses == [], do: [], else: tl(state.responses)
        {response, %{state | responses: responses, calls: [run_id | state.calls]}}
      end)
    end
  end

  defmodule ExecutionFake do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], calls: []} end, name: __MODULE__)

    def reset!, do: Agent.update(__MODULE__, fn _ -> %{responses: [], calls: []} end)

    def put_response!(response),
      do: Agent.update(__MODULE__, &Map.update!(&1, :responses, fn xs -> xs ++ [response] end))

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def run_step(run, cursor, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = List.first(state.responses) || :continue
        responses = if state.responses == [], do: [], else: tl(state.responses)

        result =
          case response do
            :continue -> {:continue, run, cursor}
            :terminal -> {:manifest_terminal, run, cursor}
            {:error, reason} -> {:error, reason}
          end

        {result, %{state | responses: responses, calls: [{run.id, cursor.page} | state.calls]}}
      end)
    end
  end

  setup do
    start_supervised!(BootstrapFake)
    start_supervised!(ExecutionFake)
    BootstrapFake.reset!()
    ExecutionFake.reset!()

    original_bootstrap = Application.get_env(:event_sales, :historical_manifest_bootstrap)
    original_execution = Application.get_env(:event_sales, :historical_manifest_execution)

    original_execution_opts =
      Application.get_env(:event_sales, :historical_manifest_execution_opts)

    Application.put_env(:event_sales, :historical_manifest_bootstrap, BootstrapFake)
    Application.put_env(:event_sales, :historical_manifest_execution, ExecutionFake)
    Application.put_env(:event_sales, :historical_manifest_execution_opts, now: fn -> @now end)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "Backfill Worker", slug: unique_slug("worker")})

    run = create_run!(source, event)
    cursor = create_cursor!(run)

    on_exit(fn ->
      restore_env(:historical_manifest_bootstrap, original_bootstrap)
      restore_env(:historical_manifest_execution, original_execution)
      restore_env(:historical_manifest_execution_opts, original_execution_opts)
    end)

    {:ok, source: source, event: event, run: run, cursor: cursor}
  end

  test "worker metadata and queue topology are bounded", do: assert_worker_configuration()

  test "one perform bootstraps and executes at most one page, then snoozes", %{run: run} do
    BootstrapFake.put_response!({:ok, :evidence})
    ExecutionFake.put_response!(:continue)

    assert {:snooze, 1} = perform(run.id)
    assert BootstrapFake.calls() == [run.id]
    assert ExecutionFake.calls() == [{run.id, 1}]
    assert Ash.get!(SyncRun, run.id, domain: Ingestion).status == :running
  end

  test "terminal manifest result stops the worker without completing the run", %{
    run: run,
    cursor: cursor
  } do
    BootstrapFake.put_response!({:ok, :evidence})
    ExecutionFake.put_response!(:terminal)

    assert :ok = perform(run.id)
    updated_run = Ash.get!(SyncRun, run.id, domain: Ingestion)
    updated_cursor = Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
    assert updated_run.status == :running
    assert is_nil(updated_run.finished_at)
    assert updated_cursor.status == :active
  end

  test "create claim uncertainty blocks execution and never calls the page executor", %{run: run} do
    BootstrapFake.put_response!({:error, :manifest_create_in_doubt})

    assert {:discard, :manifest_create_in_doubt} = perform(run.id)
    assert ExecutionFake.calls() == []
  end

  test "retryable source failures pause the run and snooze", %{run: run} do
    BootstrapFake.put_response!({:ok, :evidence})
    ExecutionFake.put_response!({:error, :rate_limited})

    assert {:snooze, seconds} = perform(run.id)
    assert seconds > 0
    paused = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert paused.status == :paused
    assert paused.pause_reason == :rate_limited
    assert %DateTime{} = paused.paused_until
  end

  test "final invariant failure marks run and cursor failed while preserving manifest evidence",
       %{
         run: run,
         cursor: cursor
       } do
    BootstrapFake.put_response!({:ok, :evidence})
    ExecutionFake.put_response!({:error, :manifest_continuity_mismatch})

    assert {:discard, :manifest_continuity_mismatch} =
             perform(run.id, attempt: 25, max_attempts: 25)

    failed_run = Ash.get!(SyncRun, run.id, domain: Ingestion)
    failed_cursor = Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
    assert failed_run.status == :failed
    assert %DateTime{} = failed_run.finished_at
    assert failed_cursor.status == :failed
    assert failed_cursor.metadata["historical_manifest"]["state"] == "pending_first_page"
    assert failed_cursor.metadata["failure"] == "manifest_continuity_mismatch"
  end

  test "Event authority failure is permanent and preserves manifest evidence", %{
    run: run,
    cursor: cursor
  } do
    BootstrapFake.put_response!({:ok, :evidence})
    ExecutionFake.put_response!({:error, :historical_event_source_mismatch})

    assert {:discard, :historical_event_source_mismatch} = perform(run.id)

    failed_run = Ash.get!(SyncRun, run.id, domain: Ingestion)
    failed_cursor = Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
    assert failed_run.status == :failed
    assert failed_cursor.status == :failed
    assert failed_cursor.metadata["historical_manifest"]["state"] == "pending_first_page"
    assert failed_cursor.metadata["failure"] == "historical_event_source_mismatch"
  end

  test "future paused runs snooze without bootstrap or execution", %{run: run} do
    paused_until = DateTime.add(DateTime.utc_now(), 120, :second)
    running = Ash.update!(run, %{}, action: :start, domain: Ingestion)

    paused =
      Ash.update!(running, %{paused_until: paused_until, pause_reason: :timeout},
        action: :pause,
        domain: Ingestion
      )

    assert {:snooze, seconds} = perform(paused.id)
    assert seconds > 0
    assert BootstrapFake.calls() == []
    assert ExecutionFake.calls() == []
  end

  defp assert_worker_configuration do
    changeset = BackfillOrdersWorker.new(%{"sync_run_id" => "sync-run"})
    unique = Ecto.Changeset.get_change(changeset, :unique)

    assert Ecto.Changeset.get_change(changeset, :queue) == "historical_backfill"
    assert Ecto.Changeset.get_change(changeset, :max_attempts) == 25
    assert unique[:period] == :infinity
    assert unique[:fields] == [:args]
    assert unique[:keys] == [:sync_run_id]
    assert unique[:states] == [:available, :scheduled, :executing, :retryable]
    assert Application.fetch_env!(:event_sales, Oban)[:queues][:historical_backfill] == 1
  end

  defp perform(run_id, opts \\ []) do
    BackfillOrdersWorker.perform(%Oban.Job{
      args: %{"sync_run_id" => run_id},
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: Keyword.get(opts, :max_attempts, 25)
    })
  end

  defp create_run!(source, event) do
    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: @date_to
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, source.id)
    |> Ash.Changeset.force_change_attribute(:date_from, @date_from)
    |> Ash.create!(domain: Ingestion)
  end

  defp create_cursor!(run) do
    {:ok, evidence} =
      HistoricalManifestEvidence.from_metadata(%{
        "historical_manifest" => %{
          "schema_version" => "2026-08-12.v1",
          "phase" => "manifest_enumerate",
          "boundary_token" => "manifest-token",
          "manifest_hash" => String.duplicate("a", 64),
          "manifest_expires_at_gmt" => "2026-08-13T13:00:00.000000Z",
          "source_observed_at_gmt" => "2026-08-13T11:00:00.000000Z",
          "state" => "pending_first_page"
        }
      })

    Ash.create!(
      SyncCursor,
      %{
        sync_run_id: run.id,
        page: 1,
        modified_after: run.date_from,
        modified_before: run.date_to,
        last_seen_order_id: nil,
        metadata: HistoricalManifestEvidence.metadata(evidence)
      },
      action: :upsert_active,
      domain: Ingestion
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
