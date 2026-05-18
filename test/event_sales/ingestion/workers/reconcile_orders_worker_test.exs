defmodule EventSales.Ingestion.Workers.ReconcileOrdersWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Ingestion.Workers.ReconcileOrdersWorker
  alias EventSales.TestSupport.SalesHelpers

  defmodule FakeTransport do
    @behaviour EventSales.Ingestion.Clients.WooCommerceTransport

    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], requests: []} end, name: __MODULE__)

    def reset!(responses) do
      Agent.update(__MODULE__, fn _ -> %{responses: responses, requests: []} end)
    end

    def requests do
      Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    end

    @impl true
    def request(method, url, headers, body, opts) do
      Agent.get_and_update(__MODULE__, fn %{responses: [response | rest], requests: requests} =
                                            state ->
        request = %{method: method, url: url, headers: headers, body: body, opts: opts}
        {response, %{state | responses: rest, requests: [request | requests]}}
      end)
    end
  end

  @off_peak ~U[2026-05-16 12:00:00.000000Z]

  setup do
    start_supervised!(FakeTransport)

    original_rest = Application.get_env(:event_sales, :woocommerce_rest)
    original_env = Application.get_env(:event_sales, :env)

    Application.put_env(:event_sales, :env, :test)

    Application.put_env(
      :event_sales,
      :woocommerce_rest,
      Keyword.merge(original_rest || [],
        base_url: "https://woo.test",
        consumer_key: "ck_test",
        consumer_secret: "cs_test",
        transport: FakeTransport,
        max_pages: 50,
        per_page: 100
      )
    )

    on_exit(fn ->
      Application.put_env(:event_sales, :env, original_env)

      if original_rest do
        Application.put_env(:event_sales, :woocommerce_rest, original_rest)
      else
        Application.delete_env(:event_sales, :woocommerce_rest)
      end
    end)

    :ok
  end

  test "paused run with future paused_until snoozes without WooCommerce requests" do
    run = create_run!() |> start_run!()

    paused_until = DateTime.add(DateTime.utc_now(), 120, :second)

    {:ok, paused} =
      Ash.update(
        run,
        %{paused_until: paused_until, pause_reason: :rate_limited, last_error: "429"},
        action: :pause,
        domain: Ingestion
      )

    FakeTransport.reset!([{:ok, 200, [], "[]"}])

    assert {:snooze, seconds} = perform(%{"sync_run_id" => paused.id})
    assert seconds > 0
    assert [] = FakeTransport.requests()
    assert Ash.get!(SyncRun, paused.id, domain: Ingestion).status == :paused
  end

  test "elapsed paused_until resumes and calls WooCommerce" do
    run = create_run!() |> start_run!()
    paused_until = DateTime.add(DateTime.utc_now(), -5, :second)

    {:ok, paused} =
      Ash.update(
        run,
        %{paused_until: paused_until, pause_reason: :rate_limited, last_error: "429"},
        action: :pause,
        domain: Ingestion
      )

    FakeTransport.reset!([{:ok, 200, [], "[]"}])

    assert :ok = perform(%{"sync_run_id" => paused.id})
    assert [_request] = FakeTransport.requests()
    assert Ash.get!(SyncRun, paused.id, domain: Ingestion).status == :completed
  end

  test "retryable WooCommerce error pauses run and returns snooze" do
    run = create_run!()

    FakeTransport.reset!([{:ok, 429, [], ~s({"message":"rate limited"})}])

    assert {:snooze, _seconds} = perform(%{"sync_run_id" => run.id})

    reloaded = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :paused
    assert reloaded.pause_reason == :rate_limited
    assert %DateTime{} = reloaded.paused_until
  end

  test "completed run discards further jobs" do
    run = create_run!() |> start_run!()
    {:ok, completed} = Ash.update(run, %{}, action: :complete, domain: Ingestion)

    assert :discard = perform(%{"sync_run_id" => completed.id})
  end

  defp perform(args) do
    ReconcileOrdersWorker.perform(%Oban.Job{args: args})
  end

  defp create_run! do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Worker", slug: unique_slug("worker")})

    {:ok, run} =
      SyncRun
      |> Ash.Changeset.for_create(:queue_manual_scoped, %{
        source_system_id: source.id,
        event_id: event.id,
        date_from: ~U[2026-05-01 00:00:00Z],
        date_to: ~U[2026-05-02 00:00:00Z],
        sync_mode: :shallow
      })
      |> Ash.create(domain: Ingestion, context: %{scoped_manual_sync_now: @off_peak})

    run
  end

  defp start_run!(run), do: Ash.update!(run, %{}, action: :start, domain: Ingestion)

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
