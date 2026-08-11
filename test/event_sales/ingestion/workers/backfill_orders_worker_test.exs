defmodule EventSales.Ingestion.Workers.BackfillOrdersWorkerTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Ingestion.Workers.{BackfillOrdersWorker, ReconcileOrdersWorker}
  alias EventSales.TestSupport.{FixtureHelpers, SalesHelpers}

  defmodule FakeClient do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], requests: []} end, name: __MODULE__)

    def reset!(responses),
      do: Agent.update(__MODULE__, fn _ -> %{responses: responses, requests: []} end)

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    def list_orders_page(params, opts) do
      Agent.get_and_update(__MODULE__, fn %{responses: [response | rest], requests: requests} =
                                            state ->
        {response, %{state | responses: rest, requests: [{params, opts} | requests]}}
      end)
    end
  end

  defmodule FakeNotifier do
    def notify_order_reconciled(_order, _run, _event_id, _opts \\ []), do: :ok
  end

  @from ~U[2026-05-01 08:00:00.000000Z]
  @to ~U[2026-05-01 08:10:00.000000Z]

  setup do
    start_supervised!(FakeClient)

    original_client = Application.get_env(:event_sales, :woocommerce_client)
    original_notifier = Application.get_env(:event_sales, :order_processed_notifier)
    original_rest = Application.get_env(:event_sales, :woocommerce_rest)

    Application.put_env(:event_sales, :woocommerce_client, FakeClient)
    Application.put_env(:event_sales, :order_processed_notifier, FakeNotifier)

    Application.put_env(
      :event_sales,
      :woocommerce_rest,
      Keyword.merge(original_rest || [], per_page: 2, max_pages: 1)
    )

    on_exit(fn ->
      restore_env(:woocommerce_client, original_client)
      restore_env(:order_processed_notifier, original_notifier)
      restore_env(:woocommerce_rest, original_rest)
    end)

    :ok
  end

  test "historical worker rejects a reconciliation run" do
    run = reconciliation_run!()

    assert :discard = perform(%{"sync_run_id" => run.id})
    assert FakeClient.requests() == []
    assert Ash.get!(SyncRun, run.id, domain: Ingestion).status == :queued
  end

  test "reconciliation worker rejects a historical run" do
    run = historical_run!()

    assert :discard = ReconcileOrdersWorker.perform(%Oban.Job{args: %{"sync_run_id" => run.id}})
    assert FakeClient.requests() == []
    assert Ash.get!(SyncRun, run.id, domain: Ingestion).status == :queued
  end

  test "historical worker requires the pre-created cursor" do
    run = historical_run!()
    FakeClient.reset!([{:ok, [unmatched_order(1, "2026-05-01T08:01:00")]}])

    assert {:discard, :historical_cursor_required} = perform(%{"sync_run_id" => run.id})
    assert FakeClient.requests() == []
    assert Ash.get!(SyncRun, run.id, domain: Ingestion).status == :failed
  end

  test "one worker execution fetches at most one raw source page" do
    {run, _cursor} = historical_run_with_cursor!()

    FakeClient.reset!([
      {:ok,
       [unmatched_order(1, "2026-05-01T08:01:00"), unmatched_order(2, "2026-05-01T08:02:00")]},
      {:ok, []}
    ])

    assert {:snooze, 1} = perform(%{"sync_run_id" => run.id})
    assert [{_params, _opts}] = FakeClient.requests()
    assert reloaded_run(run).status == :running
    assert reloaded_cursor(run).status == :active
  end

  test "event invalidation blocks a subsequent historical page" do
    {run, _cursor} = historical_run_with_cursor!()
    event = Ash.get!(Event, run.event_id, domain: Catalog)
    Ash.update!(event, %{}, action: :invalidate_onboarding, domain: Catalog)
    FakeClient.reset!([{:ok, [unmatched_order(1, "2026-05-01T08:01:00")]}])

    assert {:discard, {:historical_event_not_backfill_pending, :unverified}} =
             perform(%{"sync_run_id" => run.id})

    assert FakeClient.requests() == []
    assert reloaded_run(run).status == :failed
    assert reloaded_cursor(run).status == :failed
  end

  test "final retry exhaustion leaves the historical run and cursor failed" do
    {run, _cursor} = historical_run_with_cursor!()
    FakeClient.reset!([{:ok, [%{"id" => 1, "date_modified_gmt" => "invalid"}]}])

    job = %Oban.Job{args: %{"sync_run_id" => run.id}, attempt: 25, max_attempts: 25}

    assert {:discard, {:invalid_historical_source_order, :date_modified_gmt}} =
             BackfillOrdersWorker.perform(job)

    assert reloaded_run(run).status == :failed
    assert reloaded_cursor(run).status == :failed
  end

  test "backfill worker and reconciliation worker have distinct queue names" do
    assert BackfillOrdersWorker.__opts__()[:queue] == :historical_backfill
    assert ReconcileOrdersWorker.__opts__()[:queue] == :reconciliation

    assert BackfillOrdersWorker.__opts__()[:unique][:keys] == [:sync_run_id]
  end

  defp perform(args), do: BackfillOrdersWorker.perform(%Oban.Job{args: args})

  defp historical_run! do
    {source, event} = historical_event!()

    {:ok, run} =
      SyncRun
      |> Ash.Changeset.for_create(:queue_historical_backfill, %{event_id: event.id, date_to: @to})
      |> Ash.Changeset.force_change_attribute(:source_system_id, source.id)
      |> Ash.Changeset.force_change_attribute(:date_from, @from)
      |> Ash.create(domain: Ingestion)

    run
  end

  defp historical_run_with_cursor! do
    run = historical_run!()

    {:ok, cursor} =
      SyncCursor
      |> Ash.Changeset.for_create(:upsert_active, %{
        sync_run_id: run.id,
        page: 1,
        modified_after: @from,
        modified_before: @to,
        metadata: %{}
      })
      |> Ash.create(domain: Ingestion)

    {run, cursor}
  end

  defp reconciliation_run! do
    {source, event} = historical_event!()

    {:ok, run} =
      SyncRun
      |> Ash.Changeset.for_create(:queue_manual_scoped, %{
        source_system_id: source.id,
        event_id: event.id,
        date_from: @from,
        date_to: @to,
        sync_mode: :shallow
      })
      |> Ash.create(domain: Ingestion, context: %{scoped_manual_sync_now: @from})

    run
  end

  defp historical_event! do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Historical worker #{System.unique_integer([:positive])}",
        slug: "historical-worker-#{System.unique_integer([:positive])}",
        external_event_id: 80_500 + System.unique_integer([:positive]),
        external_event_kind: :tickera_event
      })

    event = Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    event =
      Ash.update!(
        event,
        %{source_created_at: @from},
        action: :capture_source_created_at,
        domain: Catalog,
        context: %{event_sales_backfill_start_capture_authority: {Event, :verified}}
      )

    {source, event}
  end

  defp unmatched_order(id, modified_at) do
    FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)
    |> Map.put("id", id)
    |> Map.put("date_modified_gmt", modified_at)
    |> update_in(["line_items", Access.at(0)], fn line_item ->
      Map.merge(line_item, %{"product_id" => 999_001, "variation_id" => 999_002})
    end)
  end

  defp reloaded_run(run), do: Ash.get!(SyncRun, run.id, domain: Ingestion)

  defp reloaded_cursor(run) do
    SyncCursor
    |> Ash.Query.filter(sync_run_id == ^run.id)
    |> Ash.read_one!(domain: Ingestion)
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
