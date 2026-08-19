defmodule EventSales.Ingestion.HistoricalCatchupExecutionTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.HistoricalCatchupExecution
  alias EventSales.Ingestion.HistoricalEventLineSelector
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.{FixtureHelpers, SalesHelpers}

  require Ash.Query

  @source_url "https://catchup-store.example.test"
  @date_from ~U[2026-08-01 08:00:00.123456Z]
  @date_to ~U[2026-08-09 23:59:59.999999Z]
  @now ~U[2026-08-13 12:30:00.000000Z]
  @expires_at ~U[2026-08-13 13:00:00.000000Z]
  @manifest_observed_at ~U[2026-08-13 11:00:00.000000Z]
  @catchup_observed_at ~U[2026-08-13 12:00:00.000000Z]

  defmodule CatchupClient do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(_opts),
      do: Agent.start_link(fn -> %{pages: [], calls: []} end, name: __MODULE__)

    def reset!, do: Agent.update(__MODULE__, fn _ -> %{pages: [], calls: []} end)

    def enqueue!(page),
      do:
        Agent.update(__MODULE__, &Map.update!(&1, :pages, fn pages -> pages ++ [{:ok, page}] end))

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def configured_base_url(_opts), do: {:ok, "https://catchup-store.example.test"}

    def fetch_catchup_page(boundary_token, cursor, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = List.first(state.pages) || {:error, :missing_catchup_page}
        pages = if state.pages == [], do: [], else: tl(state.pages)
        {response, %{state | pages: pages, calls: [{boundary_token, cursor} | state.calls]}}
      end)
    end
  end

  defmodule WooClient do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(_opts),
      do: Agent.start_link(fn -> %{orders: %{}, calls: []} end, name: __MODULE__)

    def reset!, do: Agent.update(__MODULE__, fn _ -> %{orders: %{}, calls: []} end)

    def put_order!(id, response),
      do: Agent.update(__MODULE__, &put_in(&1, [:orders, to_string(id)], response))

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def configured_base_url(_opts), do: {:ok, "https://catchup-store.example.test"}

    def fetch_order(id, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = Map.get(state.orders, to_string(id), {:error, :not_found})
        {response, %{state | calls: [{:fetch_order, id} | state.calls]}}
      end)
    end
  end

  defmodule Selector do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(_opts),
      do: Agent.start_link(fn -> %{lines: [], calls: []} end, name: __MODULE__)

    def reset!, do: Agent.update(__MODULE__, fn _ -> %{lines: [], calls: []} end)
    def set_lines!(lines), do: Agent.update(__MODULE__, &Map.put(&1, :lines, lines))
    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def select(event, source, order) do
      Agent.get_and_update(__MODULE__, fn state ->
        result = {:ok, state.lines}
        {result, %{state | calls: [{event.id, source.id, order["id"]} | state.calls]}}
      end)
    end
  end

  defmodule Upserter do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(_opts),
      do: Agent.start_link(fn -> %{response: {:ok, :stale_noop}, calls: []} end, name: __MODULE__)

    def reset!,
      do: Agent.update(__MODULE__, fn _ -> %{response: {:ok, :stale_noop}, calls: []} end)

    def response!(response), do: Agent.update(__MODULE__, &Map.put(&1, :response, response))
    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def reconcile_event_order(source_system_id, event_id, payload, lines, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        result = state.response
        call = {source_system_id, event_id, payload, lines}
        {result, %{state | calls: [call | state.calls]}}
      end)
    end
  end

  defmodule RefundSync do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], calls: []} end, name: __MODULE__)

    def reset!, do: Agent.update(__MODULE__, fn _ -> %{responses: [], calls: []} end)

    def enqueue!(response),
      do: Agent.update(__MODULE__, &Map.update!(&1, :responses, fn xs -> xs ++ [response] end))

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def sync_order(source_system_id, woo_order_id, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = List.first(state.responses) || :ok
        responses = if state.responses == [], do: [], else: tl(state.responses)

        call = %{
          source_system_id: source_system_id,
          woo_order_id: woo_order_id,
          opts: opts,
          order_calls_at_sync: length(Upserter.calls())
        }

        {response, %{state | responses: responses, calls: [call | state.calls]}}
      end)
    end
  end

  setup do
    start_supervised!(CatchupClient)
    start_supervised!(WooClient)
    start_supervised!(Selector)
    start_supervised!(Upserter)
    start_supervised!(RefundSync)
    CatchupClient.reset!()
    WooClient.reset!()
    Selector.reset!()
    Upserter.reset!()
    RefundSync.reset!()

    source = SalesHelpers.create_source_system!(%{base_url: @source_url})

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 805_001,
        external_event_kind: :tickera_event
      })

    event =
      Ash.update!(event, %{source_created_at: @date_from},
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
      |> Ash.update!(%{}, action: :start, domain: Ingestion)

    cursor = create_cursor!(run)

    {:ok, source: source, event: event, run: run, cursor: cursor}
  end

  test "pending U replays cursor nil, fetches exact IDs, and checkpoints without M counter changes",
       %{
         run: run,
         cursor: cursor
       } do
    CatchupClient.enqueue!(page(["42"], has_more: true, next_cursor: "u-next.cursor"))
    WooClient.put_order!(42, {:ok, order_payload(42)})
    Selector.set_lines!([])

    assert {:continue, _updated_run, updated_cursor} = run_step(run, cursor)
    assert CatchupClient.calls() == [{"catchup-token", nil}]
    assert WooClient.calls() == [{:fetch_order, "42"}]
    assert length(Upserter.calls()) == 1
    assert [%{woo_order_id: "42", order_calls_at_sync: 1}] = RefundSync.calls()
    assert updated_cursor.page == 2
    assert updated_cursor.status == :active
    assert updated_cursor.metadata["historical_catchup"]["state"] == "catchup_in_progress"
    assert updated_cursor.metadata["historical_catchup"]["next_cursor"] == "u-next.cursor"
    assert updated_cursor.metadata["historical_manifest"]["state"] == "manifest_terminal"
    assert counts(run) == %{seen: 0, matched: 0, upserted: 0, stale: 0}

    persisted_run = current_run(run)
    assert persisted_run.status == :running
    assert persisted_run.order_coverage_status == :incomplete
    assert persisted_run.refund_coverage_status == :not_started
    assert is_nil(persisted_run.coverage_certified_at)
  end

  test "in-progress U uses the exact opaque cursor", %{run: run, cursor: cursor} do
    replace_cursor!(cursor, 4, catchup_in_progress_metadata())
    CatchupClient.enqueue!(page(["43"], has_more: false, terminal_evidence: "u-proof"))
    WooClient.put_order!(43, {:ok, order_payload(43)})

    assert :ok = run_step(run, current_cursor(cursor))
    assert CatchupClient.calls() == [{"catchup-token", "u-next.cursor"}]
    assert WooClient.calls() == [{:fetch_order, "43"}]
    assert [%{woo_order_id: "43", order_calls_at_sync: 1}] = RefundSync.calls()
    assert current_cursor(cursor).status == :done
    assert current_run(run).status == :completed
  end

  test "empty explicit terminal page completes without a Woo order GET", %{
    event: event,
    run: run,
    cursor: cursor
  } do
    CatchupClient.enqueue!(page([], has_more: false, terminal_evidence: "u-empty-proof"))

    assert :ok = run_step(run, cursor)
    assert CatchupClient.calls() == [{"catchup-token", nil}]
    assert WooClient.calls() == []
    assert current_cursor(cursor).status == :done
    assert current_cursor(cursor).page == 2
    assert current_run(run).status == :completed
    assert current_run(run).finished_at
    assert current_cursor(cursor).metadata["historical_catchup"]["state"] == "catchup_terminal"

    completed_run = current_run(run)
    assert completed_run.order_coverage_status == :complete
    assert completed_run.refund_coverage_status == :complete
    assert completed_run.coverage_start == event.source_created_at
    assert completed_run.sales_covered_through == run.date_to
    assert completed_run.refunds_covered_through == @catchup_observed_at
    assert DateTime.compare(completed_run.refunds_covered_through, run.date_to) == :gt
    assert %DateTime{} = completed_run.coverage_certified_at

    terminal_cursor = current_cursor(cursor)
    assert terminal_cursor.metadata["historical_manifest"]["state"] == "manifest_terminal"

    assert terminal_cursor.metadata["historical_manifest"]["terminal_evidence"] ==
             "m-terminal-proof"

    assert terminal_cursor.metadata["historical_catchup"]["state"] == "catchup_terminal"
    assert terminal_cursor.metadata["historical_catchup"]["terminal_evidence"] == "u-empty-proof"
  end

  test "terminal coverage certification is not repeated by a stale terminal replay", %{
    run: run,
    cursor: cursor
  } do
    CatchupClient.enqueue!(page([], has_more: false, terminal_evidence: "u-replay-proof"))

    assert :ok = run_step(run, cursor)

    certified = current_run(run)
    certificate = certified.coverage_certified_at

    assert {:error, :sync_run_not_running} = run_step(run, cursor)

    persisted = current_run(run)
    assert persisted.status == :completed
    assert persisted.coverage_certified_at == certificate
    assert persisted.sales_covered_through == run.date_to
    assert current_cursor(cursor).status == :done
  end

  test "certifier failure is propagated and prevents terminal completion", %{
    run: run,
    cursor: cursor
  } do
    certified =
      Ash.update!(
        run,
        %{
          coverage_start: @date_from,
          sales_covered_through: @date_to,
          refunds_covered_through: @catchup_observed_at
        },
        action: :record_coverage_certification,
        domain: Ingestion
      )

    CatchupClient.enqueue!(page([], has_more: false, terminal_evidence: "u-certifier-failure"))

    assert {:error, :coverage_already_certified} =
             run_step(certified, current_cursor(cursor))

    persisted = current_run(run)
    assert persisted.status == :running
    assert persisted.coverage_certified_at == certified.coverage_certified_at
    assert current_cursor(cursor).status == :active
    assert current_cursor(cursor).page == 1
  end

  test "recovered transient diagnostic does not block terminal completion", %{
    run: run,
    cursor: cursor
  } do
    paused =
      Ash.update!(
        current_run(run),
        %{
          paused_until: DateTime.add(@now, 30, :second),
          pause_reason: :rate_limited,
          last_error: "rate_limited"
        },
        action: :pause,
        domain: Ingestion
      )

    resumed = Ash.update!(paused, %{}, action: :resume, domain: Ingestion)
    assert resumed.status == :running
    assert resumed.last_error == "rate_limited"

    CatchupClient.enqueue!(page([], has_more: false, terminal_evidence: "u-recovered-proof"))

    assert :ok = run_step(resumed, current_cursor(cursor))
    assert current_cursor(cursor).status == :done
    assert current_run(run).status == :completed
  end

  test "orders_failed_count blocks terminal completion", %{run: run, cursor: cursor} do
    record_failure_counts!(run, orders_failed_count: 1)
    assert_terminal_authority_rejected(run, cursor, "u-failed-count-proof")
  end

  test "errors_count blocks terminal completion", %{run: run, cursor: cursor} do
    record_failure_counts!(run, errors_count: 1)
    assert_terminal_authority_rejected(run, cursor, "u-error-count-proof")
  end

  test "persisted cursor failure summary blocks terminal completion", %{
    run: run,
    cursor: cursor
  } do
    Ash.update!(
      cursor,
      %{metadata: Map.put(cursor.metadata, "failure", "rate_limited")},
      action: :record_catchup_evidence,
      domain: Ingestion
    )

    assert_terminal_authority_rejected(run, cursor, "u-cursor-failure-proof")
  end

  test "stale_noop is accepted and the empty selected subset is still written", %{
    run: run,
    cursor: cursor
  } do
    CatchupClient.enqueue!(page(["44"], has_more: false, terminal_evidence: "u-stale-proof"))
    WooClient.put_order!(44, {:ok, order_payload(44)})
    Selector.set_lines!([])
    Upserter.response!({:ok, :stale_noop})

    assert :ok = run_step(run, cursor)
    assert [{_source_id, _event_id, %{"id" => 44}, []}] = Upserter.calls()
    assert [%{woo_order_id: "44", order_calls_at_sync: 1}] = RefundSync.calls()
  end

  test "a persisted F4C1 Order is reconciled before refund synchronization", %{
    run: run,
    cursor: cursor
  } do
    CatchupClient.enqueue!(page(["46"], has_more: false, terminal_evidence: "u-order-proof"))
    WooClient.put_order!(46, {:ok, order_payload(46)})
    Upserter.response!({:ok, %Order{}})

    assert :ok = run_step(run, cursor)
    assert [%{woo_order_id: "46", order_calls_at_sync: 1}] = RefundSync.calls()
  end

  test "an F4C1 failure prevents refund synchronization", %{run: run, cursor: cursor} do
    CatchupClient.enqueue!(page(["47"], has_more: false, terminal_evidence: "u-order-error"))
    WooClient.put_order!(47, {:ok, order_payload(47)})
    Upserter.response!({:error, :order_writer_failed})

    assert {:error, :order_writer_failed} = run_step(run, cursor)
    assert RefundSync.calls() == []
    assert current_cursor(cursor).page == 1
  end

  test "terminal U refund failure blocks completion and checkpointing", %{
    run: run,
    cursor: cursor
  } do
    CatchupClient.enqueue!(page(["48"], has_more: false, terminal_evidence: "u-refund-error"))
    WooClient.put_order!(48, {:ok, order_payload(48)})
    RefundSync.enqueue!({:error, :timeout})

    assert {:error, :timeout} = run_step(run, cursor)
    assert current_cursor(cursor).status == :active
    assert current_cursor(cursor).page == 1
    assert current_run(run).status == :running
    assert [%{woo_order_id: "48", order_calls_at_sync: 1}] = RefundSync.calls()
  end

  test "a later U refund failure prevents the whole page checkpoint", %{run: run, cursor: cursor} do
    CatchupClient.enqueue!(
      page(["49", "50"], has_more: false, terminal_evidence: "u-page-refund-error")
    )

    WooClient.put_order!(49, {:ok, order_payload(49)})
    WooClient.put_order!(50, {:ok, order_payload(50)})
    RefundSync.enqueue!(:ok)
    RefundSync.enqueue!({:error, :refund_void_failed})

    assert {:error, :refund_void_failed} = run_step(run, cursor)
    assert Enum.map(RefundSync.calls(), & &1.woo_order_id) == ["49", "50"]
    assert current_cursor(cursor).page == 1
    assert current_run(run).status == :running
  end

  test "sales write before checkpoint failure replays the same U page safely", %{
    run: run,
    cursor: cursor
  } do
    page = page(["45"], has_more: false, terminal_evidence: "u-replay-proof")
    CatchupClient.enqueue!(page)
    CatchupClient.enqueue!(page)
    WooClient.put_order!(45, {:ok, order_payload(45)})

    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    before_checkpoint = fn ->
      Agent.get_and_update(attempts, fn
        0 -> {{:error, :injected_checkpoint_failure}, 1}
        _ -> {:ok, 1}
      end)
    end

    assert {:error, :injected_checkpoint_failure} =
             run_step(run, cursor, before_checkpoint: before_checkpoint)

    assert current_cursor(cursor).status == :active
    assert current_run(run).status == :running
    assert length(Upserter.calls()) == 1

    assert :ok = run_step(current_run(run), current_cursor(cursor))
    assert length(Upserter.calls()) == 2
    assert length(RefundSync.calls()) == 2
    assert current_cursor(cursor).status == :done
    assert current_run(run).status == :completed
  end

  test "continuity mismatch fails before any exact-order GET or sales write", %{
    run: run,
    cursor: cursor
  } do
    CatchupClient.enqueue!(page(["46"], manifest_hash: String.duplicate("c", 64)))

    assert {:error, :catchup_continuity_mismatch} = run_step(run, cursor)
    assert WooClient.calls() == []
    assert Upserter.calls() == []
    assert current_cursor(cursor).page == 1
  end

  test "terminal continuity mismatch fails before any exact-order GET or sales write", %{
    run: run,
    cursor: cursor
  } do
    CatchupClient.enqueue!(
      page([],
        has_more: false,
        terminal_evidence: "u-mismatch-proof",
        manifest_hash: String.duplicate("c", 64)
      )
    )

    assert {:error, :catchup_continuity_mismatch} = run_step(run, cursor)
    assert WooClient.calls() == []
    assert Upserter.calls() == []
    assert current_cursor(cursor).page == 1
  end

  test "current durable run authority is re-read before any U GET", %{
    run: run,
    cursor: cursor
  } do
    current = current_run(run)

    Ash.update!(
      current,
      %{
        paused_until: DateTime.add(@now, 60, :second),
        pause_reason: :timeout,
        last_error: "paused_for_test"
      },
      action: :pause,
      domain: Ingestion
    )

    assert {:error, :sync_run_not_running} = run_step(run, cursor)
    assert CatchupClient.calls() == []
    assert WooClient.calls() == []
  end

  test "returned Woo order ID must exactly match the immutable U identity", %{
    run: run,
    cursor: cursor
  } do
    CatchupClient.enqueue!(page(["46"], has_more: false, terminal_evidence: "u-id-proof"))
    WooClient.put_order!(46, {:ok, Map.put(order_payload(999), "id", 999)})

    assert {:error, :source_order_id_mismatch} = run_step(run, cursor)
    assert length(WooClient.calls()) == 1
    assert Upserter.calls() == []
    assert current_cursor(cursor).page == 1
  end

  test "processes the current exact-ID payload even when it changed after H", %{
    run: run,
    cursor: cursor
  } do
    CatchupClient.enqueue!(page(["47"], has_more: false, terminal_evidence: "u-after-h-proof"))

    current_payload =
      order_payload(47)
      |> Map.put("date_created_gmt", "2026-08-20T10:00:00Z")
      |> Map.put("date_modified_gmt", "2026-08-20T10:05:00Z")

    WooClient.put_order!(47, {:ok, current_payload})

    assert :ok = run_step(run, cursor)
    assert [{_source_id, _event_id, ^current_payload, []}] = Upserter.calls()
  end

  test "passes the real current raw subset through the real F4C1 writer", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    SalesHelpers.create_variation_ticket_type!(event, 501, 601)

    current_event = Ash.get!(Event, event.id, domain: Catalog)

    if current_event.analytics_onboarding_state == :unverified do
      Ash.update!(current_event, %{}, action: :mark_backfill_pending, domain: Catalog)
    end

    payload =
      FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)
      |> put_in(
        ["line_items", Access.at(0), "meta_data"],
        [%{"key" => "tickera_event_id", "value" => "805001"}]
      )

    CatchupClient.enqueue!(page(["10001"], has_more: false, terminal_evidence: "u-real-proof"))
    WooClient.put_order!(10_001, {:ok, payload})

    assert :ok =
             run_step(
               run,
               cursor,
               event_line_selector: HistoricalEventLineSelector,
               order_upserter: OrderUpserter
             )

    order =
      Order
      |> Ash.Query.filter(source_system_id == ^source.id and woo_order_id == 10_001)
      |> Ash.read_one!(domain: EventSales.Sales)

    assert %Order{} = order
    assert [%OrderItem{event_id: event_id, woo_line_item_id: 70_001}] = order_items(order.id)
    assert event_id == event.id
  end

  test "Event invalidation before completion rolls back cursor and run completion", %{
    event: event,
    run: run,
    cursor: cursor
  } do
    CatchupClient.enqueue!(page([], has_more: false, terminal_evidence: "u-invalidated-proof"))

    before_checkpoint = fn ->
      event = Ash.get!(Event, event.id, domain: Catalog)
      Ash.update!(event, %{}, action: :invalidate_onboarding, domain: Catalog)
      :ok
    end

    assert {:error, {:historical_event_not_backfill_pending, :unverified}} =
             run_step(run, cursor, before_checkpoint: before_checkpoint)

    assert current_cursor(cursor).status == :active
    assert current_run(run).status == :running
    assert current_cursor(cursor).metadata["historical_catchup"]["state"] == "pending_first_page"
  end

  test "M terminal evidence survives three U pages for 205 identities", %{
    run: run,
    cursor: cursor
  } do
    seed_m_counters!(run)

    first = Enum.map(1..100, &to_string/1)
    second = Enum.map(101..200, &to_string/1)
    third = Enum.map(201..205, &to_string/1)

    CatchupClient.enqueue!(page(first, has_more: true, next_cursor: "page-a.cursor"))
    CatchupClient.enqueue!(page(second, has_more: true, next_cursor: "page-b.cursor"))
    CatchupClient.enqueue!(page(third, has_more: false, terminal_evidence: "u-205-proof"))

    Enum.each(1..205, fn id -> WooClient.put_order!(id, {:ok, order_payload(id)}) end)

    assert {:continue, _, cursor_a} = run_step(run, cursor)
    assert cursor_a.page == 2
    assert {:continue, _, cursor_b} = run_step(current_run(run), current_cursor(cursor))
    assert cursor_b.page == 3
    assert :ok = run_step(current_run(run), current_cursor(cursor))

    assert length(WooClient.calls()) == 205
    assert current_cursor(cursor).status == :done
    assert current_run(run).status == :completed
    assert current_cursor(cursor).metadata["historical_manifest"]["state"] == "manifest_terminal"

    assert current_cursor(cursor).metadata["historical_manifest"]["terminal_evidence"] ==
             "m-terminal-proof"

    assert counts(run) == %{seen: 3, matched: 2, upserted: 1, stale: 4}
  end

  test "invalidated Event blocks source work before the first U GET", %{
    event: event,
    run: run,
    cursor: cursor
  } do
    Ash.update!(event, %{}, action: :invalidate_onboarding, domain: Catalog)

    assert {:error, {:historical_event_not_backfill_pending, :unverified}} = run_step(run, cursor)
    assert CatchupClient.calls() == []
    assert WooClient.calls() == []
  end

  defp run_step(run, cursor, opts \\ []) do
    HistoricalCatchupExecution.run_step(run, cursor, Keyword.merge(base_opts(), opts))
  end

  defp base_opts do
    [
      catchup_client: CatchupClient,
      woocommerce_client: WooClient,
      event_line_selector: Selector,
      order_upserter: Upserter,
      order_refund_sync: RefundSync,
      now: fn -> @now end
    ]
  end

  defp page(order_ids, overrides) do
    base = %{
      "schema_version" => "2026-08-13.catchup.v1",
      "phase" => "catch_up",
      "boundary_token" => "catchup-token",
      "manifest_hash" => String.duplicate("b", 64),
      "manifest_expires_at_gmt" => DateTime.to_iso8601(@expires_at),
      "source_observed_at_gmt" => DateTime.to_iso8601(@catchup_observed_at),
      "items" => Enum.map(order_ids, &u_item/1),
      "has_more" => true,
      "next_cursor" => "default.cursor"
    }

    Enum.reduce(overrides, base, fn
      {:has_more, false}, acc ->
        acc |> Map.put("has_more", false) |> Map.delete("next_cursor")

      {:has_more, true}, acc ->
        Map.put(acc, "has_more", true)

      {:next_cursor, value}, acc ->
        Map.put(acc, "next_cursor", value)

      {:terminal_evidence, value}, acc ->
        acc |> Map.put("terminal_evidence", value) |> Map.delete("next_cursor")

      {key, value}, acc ->
        Map.put(acc, to_string(key), value)
    end)
  end

  defp u_item(id) do
    %{
      "source_order_id" => id,
      "source_created_at_gmt" => "2026-08-04T10:00:00Z",
      "source_modified_at_gmt" => "2026-08-04T10:00:00Z"
    }
  end

  defp order_payload(id) do
    %{
      "id" => id,
      "date_created_gmt" => "2026-08-04T10:00:00Z",
      "date_modified_gmt" => "2026-08-04T10:00:00Z",
      "line_items" => []
    }
  end

  defp parent_metadata do
    %{
      "historical_manifest" => %{
        "schema_version" => "2026-08-12.v1",
        "phase" => "manifest_enumerate",
        "boundary_token" => "manifest-token",
        "manifest_hash" => String.duplicate("a", 64),
        "manifest_expires_at_gmt" => DateTime.to_iso8601(@expires_at),
        "source_observed_at_gmt" => DateTime.to_iso8601(@manifest_observed_at),
        "state" => "manifest_terminal",
        "terminal_evidence" => "m-terminal-proof"
      }
    }
  end

  defp catchup_metadata do
    {:ok, parent} = HistoricalManifestEvidence.from_metadata(parent_metadata())

    {:ok, child} =
      HistoricalCatchupEvidence.from_page(
        page([], has_more: false, terminal_evidence: "post-proof"),
        parent
      )

    Map.merge(parent_metadata(), HistoricalCatchupEvidence.metadata(child))
  end

  defp catchup_in_progress_metadata do
    {:ok, child} = HistoricalCatchupEvidence.from_metadata(catchup_metadata())

    Map.merge(
      parent_metadata(),
      HistoricalCatchupEvidence.in_progress_metadata(child, "u-next.cursor")
    )
  end

  defp create_cursor!(run) do
    SyncCursor
    |> Ash.Changeset.for_create(:upsert_active, %{
      sync_run_id: run.id,
      page: 1,
      modified_after: run.date_from,
      modified_before: run.date_to,
      last_seen_order_id: nil,
      metadata: catchup_metadata()
    })
    |> Ash.create!(domain: Ingestion)
  end

  defp replace_cursor!(cursor, page, metadata) do
    SyncCursor
    |> Ash.Changeset.for_create(:upsert_active, %{
      sync_run_id: cursor.sync_run_id,
      page: page,
      modified_after: cursor.modified_after,
      modified_before: cursor.modified_before,
      last_seen_order_id: nil,
      metadata: metadata
    })
    |> Ash.create!(domain: Ingestion)
  end

  defp current_cursor(cursor), do: Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
  defp current_run(run), do: Ash.get!(SyncRun, run.id, domain: Ingestion)

  defp record_failure_counts!(run, attrs) do
    Ash.update!(current_run(run), attrs, action: :record_counts, domain: Ingestion)
  end

  defp assert_terminal_authority_rejected(run, cursor, terminal_evidence) do
    CatchupClient.enqueue!(page([], has_more: false, terminal_evidence: terminal_evidence))

    assert {:error, :historical_completion_authority_invalid} =
             run_step(current_run(run), current_cursor(cursor))

    assert current_cursor(cursor).status == :active
    assert current_run(run).status == :running
    assert current_run(run).order_coverage_status == :incomplete
    assert current_run(run).refund_coverage_status == :not_started
    assert is_nil(current_run(run).coverage_certified_at)
  end

  defp seed_m_counters!(run) do
    Ash.update!(
      current_run(run),
      %{
        orders_seen_count: 3,
        orders_matched_count: 2,
        orders_upserted_count: 1,
        orders_stale_count: 4
      },
      action: :record_counts,
      domain: Ingestion
    )
  end

  defp order_items(order_id) do
    OrderItem
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.read!(domain: EventSales.Sales)
  end

  defp counts(run) do
    current = current_run(run)

    %{
      seen: current.orders_seen_count,
      matched: current.orders_matched_count,
      upserted: current.orders_upserted_count,
      stale: current.orders_stale_count
    }
  end
end
