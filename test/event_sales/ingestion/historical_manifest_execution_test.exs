defmodule EventSales.Ingestion.HistoricalManifestExecutionTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.HistoricalManifestExecution
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.TestSupport.SalesHelpers

  @source_url "https://store.example.test"
  @date_from ~U[2026-08-01 08:00:00.123456Z]
  @date_to ~U[2026-08-09 23:59:59.999999Z]
  @now ~U[2026-08-13 12:00:00.000000Z]
  @manifest_expires_at ~U[2026-08-13 13:00:00.000000Z]
  @source_observed_at ~U[2026-08-13 11:00:00.000000Z]

  defmodule ManifestClient do
    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], calls: []} end, name: __MODULE__)

    def reset!, do: Agent.update(__MODULE__, fn _ -> %{responses: [], calls: []} end)

    def enqueue!(response),
      do: Agent.update(__MODULE__, &Map.update!(&1, :responses, fn xs -> xs ++ [response] end))

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def configured_base_url(_opts), do: {:ok, "https://store.example.test"}

    def fetch_manifest_page(boundary_token, cursor, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = List.first(state.responses) || {:error, :missing_manifest_response}
        responses = if state.responses == [], do: [], else: tl(state.responses)

        {response,
         %{
           state
           | responses: responses,
             calls: [{:fetch_manifest_page, boundary_token, cursor} | state.calls]
         }}
      end)
    end
  end

  defmodule WooClient do
    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{orders: %{}, calls: []} end, name: __MODULE__)

    def reset!, do: Agent.update(__MODULE__, fn _ -> %{orders: %{}, calls: []} end)

    def put_order!(id, response),
      do: Agent.update(__MODULE__, &put_in(&1, [:orders, to_string(id)], response))

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def configured_base_url(_opts), do: {:ok, "https://store.example.test"}

    def fetch_order(id, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = Map.get(state.orders, to_string(id), {:error, :not_found})
        {response, %{state | calls: [{:fetch_order, id} | state.calls]}}
      end)
    end

    def list_orders(params \\ %{}, _opts \\ []) do
      Agent.update(
        __MODULE__,
        &Map.update!(&1, :calls, fn calls -> [{:list_orders, params} | calls] end)
      )

      {:error, :historical_list_orders_called}
    end

    def list_orders_page(params \\ %{}, _opts \\ []), do: list_orders(params, [])
  end

  defmodule Upserter do
    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: %{}, calls: [], durable: %{}} end, name: __MODULE__)

    def reset!,
      do: Agent.update(__MODULE__, fn _ -> %{responses: %{}, calls: [], durable: %{}} end)

    def put_response!(id, response),
      do: Agent.update(__MODULE__, &put_in(&1, [:responses, to_string(id)], response))

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def durable, do: Agent.get(__MODULE__, & &1.durable)

    def upsert_order(source_system_id, payload, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        id = payload["id"] || payload[:id]
        result = upsert_result(state, source_system_id, id)
        durable = durable_after_result(state.durable, id, payload, result)

        {result, %{state | calls: [{source_system_id, payload} | state.calls], durable: durable}}
      end)
    end

    defp upsert_result(state, source_system_id, id) do
      Map.get(
        state.responses,
        to_string(id),
        {:ok, %{source_system_id: source_system_id, id: id}}
      )
    end

    defp durable_after_result(durable, id, payload, {:ok, _result}),
      do: Map.put(durable, to_string(id), payload)

    defp durable_after_result(durable, _id, _payload, _result), do: durable
  end

  defmodule RefundSync do
    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

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
    start_supervised!(ManifestClient)
    start_supervised!(WooClient)
    start_supervised!(Upserter)
    start_supervised!(RefundSync)
    ManifestClient.reset!()
    WooClient.reset!()
    Upserter.reset!()
    RefundSync.reset!()

    source = SalesHelpers.create_source_system!(%{base_url: @source_url})

    event =
      SalesHelpers.create_event!(source, %{
        name: "Historical Execution",
        slug: "historical-execution-#{System.unique_integer([:positive])}",
        external_event_id: 80_500 + System.unique_integer([:positive]),
        external_event_kind: :tickera_event
      })

    event =
      Ash.update!(
        event,
        %{source_created_at: @date_from},
        action: :capture_source_created_at,
        domain: Catalog,
        context: %{
          event_sales_backfill_start_capture_authority:
            {EventSales.Catalog.Resources.Event, :verified}
        }
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

    cursor = create_cursor!(run, pending_metadata())

    {:ok, source: source, event: event, run: run, cursor: cursor}
  end

  test "pending_first_page requests exactly one manifest page with nil cursor", %{
    run: run,
    cursor: cursor
  } do
    enqueue_page(page())
    WooClient.put_order!(42, {:ok, order_payload(42)})

    assert {:continue, _run, _cursor} = run_step(run, cursor)
    assert ManifestClient.calls() == [{:fetch_manifest_page, "manifest-token", nil}]
  end

  test "manifest_in_progress uses the exact persisted opaque cursor", %{run: run, cursor: cursor} do
    replace_cursor!(cursor, 2, in_progress_metadata())
    enqueue_page(page(%{source_order_id: "43"}))
    WooClient.put_order!(43, {:ok, order_payload(43)})

    progressed_cursor = Ash.get!(SyncCursor, cursor.id, domain: Ingestion)
    assert {:continue, _run, _cursor} = run_step(run, progressed_cursor)
    assert ManifestClient.calls() == [{:fetch_manifest_page, "manifest-token", "opaque.next"}]
  end

  test "one execution step fetches one page and never uses historical list traversal", %{
    run: run,
    cursor: cursor
  } do
    enqueue_page(page(%{source_order_id: "42"}))
    WooClient.put_order!(42, {:ok, order_payload(42)})

    assert {:continue, _run, _cursor} = run_step(run, cursor)
    assert length(ManifestClient.calls()) == 1
    assert Enum.map(WooClient.calls(), &elem(&1, 0)) == [:fetch_order]
    refute Enum.any?(WooClient.calls(), &match?({:list_orders, _}, &1))
  end

  test "continuity mismatch fails before any order fetch or checkpoint", %{
    run: run,
    cursor: cursor
  } do
    enqueue_page(page(%{manifest_hash: String.duplicate("b", 64)}))
    WooClient.put_order!(42, {:ok, order_payload(42)})

    assert {:error, :manifest_continuity_mismatch} = run_step(run, cursor)
    assert WooClient.calls() == []
    assert Upserter.calls() == []
    assert cursor_unchanged?(cursor)
  end

  test "expired manifest is rejected before the manifest GET", %{run: run, cursor: cursor} do
    replace_cursor!(cursor, 1, pending_metadata(@now |> DateTime.add(-1, :second)))
    assert {:error, :manifest_expired} = run_step(run, current_cursor(cursor), now: @now)
    assert ManifestClient.calls() == []
    assert WooClient.calls() == []
  end

  test "expiry after the manifest GET rejects the page before order processing", %{
    run: run,
    cursor: cursor
  } do
    enqueue_page(page())
    WooClient.put_order!(42, {:ok, order_payload(42)})

    {:ok, now_values} = Agent.start_link(fn -> [@now, DateTime.add(@now, 2, :hour)] end)
    now = fn -> Agent.get_and_update(now_values, fn [value | rest] -> {value, rest} end) end

    assert {:error, :manifest_expired} = run_step(run, cursor, now: now)
    assert WooClient.calls() == []
    assert Upserter.calls() == []
    assert cursor_unchanged?(cursor)
  end

  test "each manifest identity is fetched by exact order ID", %{run: run, cursor: cursor} do
    enqueue_page(page(%{source_order_id: "42"}, %{source_order_id: "43"}))
    WooClient.put_order!(42, {:ok, order_payload(42)})
    WooClient.put_order!(43, {:ok, order_payload(43)})

    assert {:continue, _run, _cursor} = run_step(run, cursor)
    assert Enum.map(WooClient.calls(), &elem(&1, 1)) == ["42", "43"]
  end

  test "returned order ID must exactly match the manifest identity", %{run: run, cursor: cursor} do
    enqueue_page(page())
    WooClient.put_order!(42, {:ok, order_payload(99)})

    assert {:error, :source_order_id_mismatch} = run_step(run, cursor)
    assert cursor_unchanged?(cursor)
    assert Upserter.calls() == []
  end

  test "missing order prevents the page checkpoint", %{run: run, cursor: cursor} do
    enqueue_page(page())
    WooClient.put_order!(42, {:error, :not_found})

    assert {:error, :source_order_not_found} = run_step(run, cursor)
    assert cursor_unchanged?(cursor)
  end

  test "manifest member modified after the cutoff is still processed", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    mapping = mapping(source, event, 42, 7)
    enqueue_page(page())

    WooClient.put_order!(
      42,
      {:ok,
       order_payload(42, [%{"product_id" => 42, "variation_id" => 7}], "2026-08-14T10:00:00Z")}
    )

    assert {:continue, _run, _cursor} = run_step(run, cursor, mappings: [mapping])
    assert length(Upserter.calls()) == 1
    assert current_cursor(cursor).page == 2
  end

  test "non-event orders are fully fetched and resolved without a Sales write", %{
    run: run,
    cursor: cursor
  } do
    enqueue_page(page())

    WooClient.put_order!(
      42,
      {:ok, order_payload(42, [%{"product_id" => 999, "variation_id" => nil}])}
    )

    assert {:continue, _run, _cursor} = run_step(run, cursor, mappings: [])
    assert WooClient.calls() == [{:fetch_order, "42"}]
    assert Upserter.calls() == []
    assert run_counts(run) == %{seen: 1, matched: 0, upserted: 0, stale: 0}
  end

  test "exact product and variation identities control the filtered payload", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    mapping = mapping(source, event, 42, 7)
    enqueue_page(page())

    WooClient.put_order!(
      42,
      {:ok,
       order_payload(42, [
         %{"product_id" => 42, "variation_id" => 7, "name" => "mapped by exact identity"},
         %{"product_id" => 42, "variation_id" => 8, "name" => "wrong variation"},
         %{"product_id" => 999, "variation_id" => 7, "name" => "wrong product"}
       ])}
    )

    assert {:continue, _run, _cursor} = run_step(run, cursor, mappings: [mapping])

    assert [{_source_id, %{"id" => 42, "line_items" => [%{"variation_id" => 7}]}}] =
             Upserter.calls()

    assert run_counts(run) == %{seen: 1, matched: 1, upserted: 1, stale: 0}
  end

  test "a matching M Order is written before refund synchronization", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    mapping = mapping(source, event, 42, 7)
    enqueue_page(page())

    WooClient.put_order!(
      42,
      {:ok, order_payload(42, [%{"product_id" => 42, "variation_id" => 7}])}
    )

    assert {:continue, _run, _cursor} = run_step(run, cursor, mappings: [mapping])

    assert [
             %{
               source_system_id: source_id,
               woo_order_id: "42",
               order_calls_at_sync: 1,
               opts: opts
             }
           ] =
             RefundSync.calls()

    assert source_id == source.id
    assert Keyword.get(opts, :woocommerce_client) == WooClient
    loader = Keyword.fetch!(opts, :source_system_loader)
    assert {:ok, loaded_source} = loader.(source.id)
    assert loaded_source.id == source.id
    assert loaded_source.base_url == source.base_url
    assert loaded_source.kind == source.kind
    assert {:error, :source_system_mismatch} = loader.(Ecto.UUID.generate())
  end

  test "a stale M Order still runs refund synchronization", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    mapping = mapping(source, event, 42, 7)
    enqueue_page(page())

    WooClient.put_order!(
      42,
      {:ok, order_payload(42, [%{"product_id" => 42, "variation_id" => 7}])}
    )

    Upserter.put_response!(42, {:ok, :stale_noop})

    assert {:continue, _run, _cursor} = run_step(run, cursor, mappings: [mapping])
    assert [%{woo_order_id: "42", order_calls_at_sync: 1}] = RefundSync.calls()
    assert run_counts(run) == %{seen: 1, matched: 1, upserted: 0, stale: 1}
  end

  test "an empty M Event subset still runs refund synchronization without an Order write", %{
    run: run,
    cursor: cursor
  } do
    enqueue_page(page())

    WooClient.put_order!(
      42,
      {:ok, order_payload(42, [%{"product_id" => 999, "variation_id" => nil}])}
    )

    assert {:continue, _run, _cursor} = run_step(run, cursor, mappings: [])
    assert Upserter.calls() == []
    assert [%{woo_order_id: "42", order_calls_at_sync: 0}] = RefundSync.calls()
    assert run_counts(run) == %{seen: 1, matched: 0, upserted: 0, stale: 0}
  end

  test "a transient refund failure after an M Order write blocks the checkpoint", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    mapping = mapping(source, event, 42, 7)
    enqueue_page(page())

    WooClient.put_order!(
      42,
      {:ok, order_payload(42, [%{"product_id" => 42, "variation_id" => 7}])}
    )

    RefundSync.enqueue!({:error, :timeout})

    assert {:error, :timeout} = run_step(run, cursor, mappings: [mapping])
    assert length(Upserter.calls()) == 1
    assert cursor_unchanged?(cursor)
    assert run_counts(run) == %{seen: 0, matched: 0, upserted: 0, stale: 0}
  end

  test "a permanent refund failure after an M Order write propagates unchanged", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    mapping = mapping(source, event, 42, 7)
    enqueue_page(page())

    WooClient.put_order!(
      42,
      {:ok, order_payload(42, [%{"product_id" => 42, "variation_id" => 7}])}
    )

    RefundSync.enqueue!({:error, :invalid_refund_list_response})

    assert {:error, :invalid_refund_list_response} =
             run_step(run, cursor, mappings: [mapping])

    assert cursor_unchanged?(cursor)
  end

  test "upserter errors prevent the page checkpoint", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    mapping = mapping(source, event, 42, 7)
    enqueue_page(page())

    WooClient.put_order!(
      42,
      {:ok, order_payload(42, [%{"product_id" => 42, "variation_id" => 7}])}
    )

    Upserter.put_response!(42, {:error, :writer_failed})

    assert {:error, :order_upsert_failed} = run_step(run, cursor, mappings: [mapping])
    assert cursor_unchanged?(cursor)
    assert RefundSync.calls() == []
  end

  test "a later M refund failure prevents the whole page checkpoint", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    mapping = mapping(source, event, 42, 7)
    enqueue_page(page(%{source_order_id: "42"}, %{source_order_id: "43"}))

    WooClient.put_order!(
      42,
      {:ok, order_payload(42, [%{"product_id" => 42, "variation_id" => 7}])}
    )

    WooClient.put_order!(
      43,
      {:ok, order_payload(43, [%{"product_id" => 42, "variation_id" => 7}])}
    )

    RefundSync.enqueue!(:ok)
    RefundSync.enqueue!({:error, :refund_void_failed})

    assert {:error, :refund_void_failed} = run_step(run, cursor, mappings: [mapping])
    assert Enum.map(RefundSync.calls(), & &1.woo_order_id) == ["42", "43"]
    assert cursor_unchanged?(cursor)
    assert run_counts(run) == %{seen: 0, matched: 0, upserted: 0, stale: 0}
  end

  test "a pre-checkpoint failure replays the same page and checkpoints counts once", %{
    source: source,
    event: event,
    run: run,
    cursor: cursor
  } do
    mapping = mapping(source, event, 42, 7)
    page = page()
    enqueue_page(page)
    enqueue_page(page)

    WooClient.put_order!(
      42,
      {:ok, order_payload(42, [%{"product_id" => 42, "variation_id" => 7}])}
    )

    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    before_checkpoint = fn ->
      Agent.get_and_update(attempts, fn
        0 -> {{:error, :injected_checkpoint_failure}, 1}
        _ -> {:ok, 1}
      end)
    end

    assert {:error, :injected_checkpoint_failure} =
             run_step(run, cursor, mappings: [mapping], before_checkpoint: before_checkpoint)

    assert cursor_unchanged?(cursor)
    assert run_counts(run) == %{seen: 0, matched: 0, upserted: 0, stale: 0}

    assert {:continue, _run, _cursor} =
             run_step(current_run(run), current_cursor(cursor), mappings: [mapping])

    assert map_size(Upserter.durable()) == 1
    assert length(Upserter.calls()) == 2
    assert run_counts(run) == %{seen: 1, matched: 1, upserted: 1, stale: 0}
  end

  test "a short nonterminal page continues from source authority", %{run: run, cursor: cursor} do
    enqueue_page(page(%{has_more: true, next_cursor: "short.next"}))
    WooClient.put_order!(42, {:ok, order_payload(42)})

    assert {:continue, _run, updated_cursor} = run_step(run, cursor)
    assert updated_cursor.metadata["historical_manifest"]["state"] == "manifest_in_progress"
    assert updated_cursor.metadata["historical_manifest"]["next_cursor"] == "short.next"
    refute Map.has_key?(updated_cursor.metadata["historical_manifest"], "terminal_evidence")
  end

  test "terminal page records source terminal evidence and leaves the run incomplete", %{
    run: run,
    cursor: cursor
  } do
    enqueue_page(page(%{items: [], has_more: false, terminal_evidence: "terminal-proof"}))

    assert {:manifest_terminal, updated_run, updated_cursor} = run_step(run, cursor)
    assert updated_cursor.page == 2
    assert updated_cursor.status == :active
    assert updated_cursor.metadata["historical_manifest"]["state"] == "manifest_terminal"
    assert updated_cursor.metadata["historical_manifest"]["terminal_evidence"] == "terminal-proof"
    refute Map.has_key?(updated_cursor.metadata["historical_manifest"], "next_cursor")
    assert updated_run.status == :queued
    assert is_nil(updated_run.finished_at)
  end

  test "terminal evidence, not a short or empty page, is terminal authority", %{
    run: run,
    cursor: cursor
  } do
    enqueue_page(page(%{items: [], has_more: true, next_cursor: "empty.next"}))

    assert {:continue, _run, updated_cursor} = run_step(run, cursor)
    assert updated_cursor.metadata["historical_manifest"]["state"] == "manifest_in_progress"
  end

  test "event source mismatch blocks source work", %{run: run, cursor: cursor} do
    mismatched_run = %{run | source_system_id: Ecto.UUID.generate()}

    assert {:error, :historical_event_source_mismatch} = run_step(mismatched_run, cursor)
    assert ManifestClient.calls() == []
    assert WooClient.calls() == []
    assert Upserter.calls() == []
  end

  test "event backfill start must equal the SyncRun date_from", %{run: run, cursor: cursor} do
    mismatched_date_from = DateTime.add(run.date_from, 1, :second)
    mismatched_run = %{run | date_from: mismatched_date_from}
    mismatched_cursor = %{cursor | modified_after: mismatched_date_from}

    assert {:error, :historical_event_backfill_start_mismatch} =
             run_step(mismatched_run, mismatched_cursor)

    assert ManifestClient.calls() == []
    assert WooClient.calls() == []
    assert Upserter.calls() == []
  end

  test "missing event blocks source work", %{run: run, cursor: cursor} do
    missing_event_run = %{run | event_id: Ecto.UUID.generate()}

    assert {:error, :historical_event_missing} = run_step(missing_event_run, cursor)
    assert ManifestClient.calls() == []
    assert WooClient.calls() == []
    assert Upserter.calls() == []
  end

  test "event invalidation before checkpoint prevents counts and cursor progress", %{
    event: event,
    source: source,
    run: run,
    cursor: cursor
  } do
    mapping = mapping(source, event, 42, 7)
    enqueue_page(page())

    WooClient.put_order!(
      42,
      {:ok, order_payload(42, [%{"product_id" => 42, "variation_id" => 7}])}
    )

    before_checkpoint = fn ->
      pending = Ash.get!(EventSales.Catalog.Resources.Event, event.id, domain: Catalog)
      Ash.update!(pending, %{}, action: :invalidate_onboarding, domain: Catalog)
      :ok
    end

    assert {:error, {:historical_event_not_backfill_pending, :unverified}} =
             run_step(run, cursor, mappings: [mapping], before_checkpoint: before_checkpoint)

    assert length(Upserter.calls()) == 1
    assert cursor_unchanged?(cursor)
    assert run_counts(run) == %{seen: 0, matched: 0, upserted: 0, stale: 0}
    assert Ash.get!(SyncRun, run.id, domain: Ingestion).status == :queued

    assert Ash.get!(EventSales.Catalog.Resources.Event, event.id, domain: Catalog).analytics_onboarding_state ==
             :unverified
  end

  test "create_claimed blocks execution without a manifest GET", %{run: run, cursor: cursor} do
    replace_cursor!(cursor, 1, HistoricalManifestEvidence.claim_metadata())

    assert {:error, :manifest_create_in_doubt} = run_step(run, current_cursor(cursor))
    assert ManifestClient.calls() == []
    assert WooClient.calls() == []
  end

  test "an invalidated Event blocks all source work before execution", %{
    event: event,
    run: run,
    cursor: cursor
  } do
    Ash.update!(event, %{}, action: :invalidate_onboarding, domain: Catalog)

    assert {:error, {:historical_event_not_backfill_pending, :unverified}} =
             run_step(run, cursor)

    assert ManifestClient.calls() == []
    assert WooClient.calls() == []
    assert Upserter.calls() == []
    assert cursor_unchanged?(cursor)
  end

  defp run_step(run, cursor, opts \\ []) do
    HistoricalManifestExecution.run_step(run, cursor, Keyword.merge(base_opts(), opts))
  end

  defp base_opts do
    [
      manifest_client: ManifestClient,
      woocommerce_client: WooClient,
      order_upserter: Upserter,
      order_refund_sync: RefundSync,
      now: fn -> @now end
    ]
  end

  defp enqueue_page(page), do: ManifestClient.enqueue!({:ok, page})

  defp page(overrides \\ %{}, second_item \\ nil) do
    items =
      [
        Map.merge(
          %{"source_order_id" => "42"},
          if(Map.has_key?(overrides, :source_order_id),
            do: %{"source_order_id" => overrides.source_order_id},
            else: %{}
          )
        )
      ]
      |> maybe_add_second_item(second_item)

    base = %{
      "schema_version" => "2026-08-12.v1",
      "phase" => "manifest_enumerate",
      "boundary_token" => "manifest-token",
      "manifest_hash" => String.duplicate("a", 64),
      "manifest_expires_at_gmt" => DateTime.to_iso8601(@manifest_expires_at),
      "source_observed_at_gmt" => DateTime.to_iso8601(@source_observed_at),
      "items" =>
        Enum.map(items, fn item ->
          Map.merge(
            %{
              "source_created_at_gmt" => "2026-08-04T10:00:00Z",
              "source_modified_at_gmt" => "2026-08-04T10:00:00Z"
            },
            item
          )
        end),
      "has_more" => true,
      "next_cursor" => "cursor1234567890.next"
    }

    Enum.reduce(overrides, base, fn
      {:source_order_id, _value}, acc -> acc
      {:has_more, false}, acc -> acc |> Map.put("has_more", false) |> Map.delete("next_cursor")
      {key, value}, acc -> Map.put(acc, to_string(key), value)
    end)
  end

  defp maybe_add_second_item(items, nil), do: items

  defp maybe_add_second_item(items, overrides),
    do:
      items ++
        [
          Map.merge(
            %{"source_order_id" => "43"},
            if(Map.has_key?(overrides, :source_order_id),
              do: %{"source_order_id" => overrides.source_order_id},
              else: %{}
            )
          )
        ]

  defp order_payload(id, line_items \\ [], modified_at \\ "2026-08-04T10:00:00Z") do
    %{
      "id" => id,
      "date_created_gmt" => "2026-08-04T10:00:00Z",
      "date_modified_gmt" => modified_at,
      "line_items" => line_items
    }
  end

  defp pending_metadata(expires_at \\ @manifest_expires_at) do
    %{
      "historical_manifest" => %{
        "schema_version" => "2026-08-12.v1",
        "phase" => "manifest_enumerate",
        "boundary_token" => "manifest-token",
        "manifest_hash" => String.duplicate("a", 64),
        "manifest_expires_at_gmt" => DateTime.to_iso8601(expires_at),
        "source_observed_at_gmt" => DateTime.to_iso8601(@source_observed_at),
        "state" => "pending_first_page"
      }
    }
  end

  defp in_progress_metadata do
    {:ok, evidence} = HistoricalManifestEvidence.from_metadata(pending_metadata())
    HistoricalManifestEvidence.in_progress_metadata(evidence, "opaque.next")
  end

  defp mapping(source, event, product_id, variation_id) do
    %ProductMapping{
      source_system_id: source.id,
      event_id: event.id,
      active: true,
      woo_product_id: product_id,
      woo_variation_id: variation_id
    }
  end

  defp create_cursor!(run, metadata) do
    SyncCursor
    |> Ash.Changeset.for_create(:upsert_active, %{
      sync_run_id: run.id,
      page: 1,
      modified_after: run.date_from,
      modified_before: run.date_to,
      last_seen_order_id: nil,
      metadata: metadata
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

  defp cursor_unchanged?(cursor) do
    current = current_cursor(cursor)

    current.page == cursor.page and current.metadata == cursor.metadata and
      current.status == cursor.status
  end

  defp run_counts(run) do
    current = current_run(run)

    %{
      seen: current.orders_seen_count,
      matched: current.orders_matched_count,
      upserted: current.orders_upserted_count,
      stale: current.orders_stale_count
    }
  end
end
