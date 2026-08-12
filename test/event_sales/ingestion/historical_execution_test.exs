defmodule EventSales.Ingestion.HistoricalExecutionTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.OrderReconciliation
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Sales
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Sales.Resources.Order
  alias EventSales.TestSupport.{FixtureHelpers, SalesHelpers}

  defmodule FakeClient do
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], requests: []} end, name: __MODULE__)

    def reset!(responses) do
      Agent.update(__MODULE__, fn _ -> %{responses: responses, requests: []} end)
    end

    def requests do
      Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    end

    def list_orders_page(params, opts) do
      Agent.get_and_update(__MODULE__, fn %{responses: [response | rest], requests: requests} =
                                            state ->
        {response, %{state | responses: rest, requests: [{params, opts} | requests]}}
      end)
    end
  end

  defmodule WooSourceContractClient do
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{orders: [], requests: []} end, name: __MODULE__)

    def reset!(orders) do
      Agent.update(__MODULE__, fn _ -> %{orders: orders, requests: []} end)
    end

    def requests do
      Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    end

    def list_orders_page(params, opts) do
      Agent.get_and_update(__MODULE__, fn %{orders: orders, requests: requests} = state ->
        result = source_page(orders, params)
        {result, %{state | requests: [{params, opts} | requests]}}
      end)
    end

    defp source_page(orders, params) do
      with :ok <- require_gmt_filter(params),
           {:ok, after_bound} <- parse_datetime(params["modified_after"]),
           {:ok, before_bound} <- parse_datetime(params["modified_before"]),
           {:ok, page} <- parse_positive_integer(params["page"]),
           {:ok, per_page} <- parse_positive_integer(params["per_page"]) do
        page_orders =
          orders
          |> Enum.filter(fn order ->
            {:ok, modified_at} = parse_datetime(order["date_modified_gmt"])

            DateTime.compare(modified_at, after_bound) == :gt and
              DateTime.compare(modified_at, before_bound) == :lt
          end)
          |> Enum.sort_by(fn order ->
            {:ok, modified_at} = parse_datetime(order["date_modified_gmt"])
            {DateTime.to_unix(modified_at, :microsecond), order["id"]}
          end)
          |> Enum.drop((page - 1) * per_page)
          |> Enum.take(per_page)

        {:ok, page_orders}
      end
    end

    defp require_gmt_filter(%{
           "dates_are_gmt" => "true",
           "orderby" => "modified",
           "order" => "asc"
         }),
         do: :ok

    defp require_gmt_filter(_params),
      do: {:error, {:source_contract_violation, :gmt_tuple_query_required}}

    defp parse_positive_integer(value) when is_binary(value) do
      case Integer.parse(value) do
        {integer, ""} when integer > 0 -> {:ok, integer}
        _other -> {:error, {:source_contract_violation, :invalid_pagination}}
      end
    end

    defp parse_positive_integer(_value),
      do: {:error, {:source_contract_violation, :invalid_pagination}}

    defp parse_datetime(value) when is_binary(value) do
      case DateTime.from_iso8601(value) do
        {:ok, datetime, _offset} ->
          {:ok, datetime}

        {:error, _reason} ->
          with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
               {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
            {:ok, datetime}
          else
            _error -> {:error, {:source_contract_violation, :invalid_date}}
          end
      end
    end

    defp parse_datetime(_value),
      do: {:error, {:source_contract_violation, :invalid_date}}
  end

  defmodule MutableWooSourceContractClient do
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{orders: [], requests: [], mutation: nil} end, name: __MODULE__)

    def reset!(orders) do
      Agent.update(__MODULE__, fn _state ->
        %{
          orders: orders,
          requests: [],
          mutation: %{order_id: 10, modified_at: "2026-05-01T08:11:00"}
        }
      end)
    end

    def fetched_ids do
      Agent.get(__MODULE__, fn state ->
        state.requests
        |> Enum.reverse()
        |> Enum.flat_map(fn {_params, ids} -> ids end)
      end)
    end

    def list_orders_page(params, _opts) do
      Agent.get_and_update(__MODULE__, fn %{
                                            orders: orders,
                                            requests: requests,
                                            mutation: mutation
                                          } = state ->
        {:ok, page_orders} = source_page(orders, params)

        next_orders =
          if requests == [] do
            mutate_order(orders, mutation)
          else
            orders
          end

        request = {params, Enum.map(page_orders, & &1["id"])}
        {{:ok, page_orders}, %{state | orders: next_orders, requests: [request | requests]}}
      end)
    end

    defp source_page(orders, params) do
      with :ok <- require_gmt_filter(params),
           {:ok, after_bound} <- parse_datetime(params["modified_after"]),
           {:ok, before_bound} <- parse_datetime(params["modified_before"]),
           {:ok, page} <- parse_positive_integer(params["page"]),
           {:ok, per_page} <- parse_positive_integer(params["per_page"]) do
        page_orders =
          orders
          |> Enum.filter(fn order ->
            {:ok, modified_at} = parse_datetime(order["date_modified_gmt"])

            DateTime.compare(modified_at, after_bound) == :gt and
              DateTime.compare(modified_at, before_bound) == :lt
          end)
          |> Enum.sort_by(fn order ->
            {:ok, modified_at} = parse_datetime(order["date_modified_gmt"])
            {DateTime.to_unix(modified_at, :microsecond), order["id"]}
          end)
          |> Enum.drop((page - 1) * per_page)
          |> Enum.take(per_page)

        {:ok, page_orders}
      end
    end

    defp mutate_order(orders, %{order_id: order_id, modified_at: modified_at}) do
      Enum.map(orders, fn
        %{"id" => ^order_id} = order -> Map.put(order, "date_modified_gmt", modified_at)
        order -> order
      end)
    end

    defp require_gmt_filter(%{
           "dates_are_gmt" => "true",
           "orderby" => "modified",
           "order" => "asc"
         }),
         do: :ok

    defp require_gmt_filter(_params),
      do: {:error, {:source_contract_violation, :gmt_tuple_query_required}}

    defp parse_positive_integer(value) when is_binary(value) do
      case Integer.parse(value) do
        {integer, ""} when integer > 0 -> {:ok, integer}
        _other -> {:error, {:source_contract_violation, :invalid_pagination}}
      end
    end

    defp parse_positive_integer(_value),
      do: {:error, {:source_contract_violation, :invalid_pagination}}

    defp parse_datetime(value) when is_binary(value) do
      case DateTime.from_iso8601(value) do
        {:ok, datetime, _offset} ->
          {:ok, datetime}

        {:error, _reason} ->
          with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
               {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
            {:ok, datetime}
          else
            _error -> {:error, {:source_contract_violation, :invalid_date}}
          end
      end
    end

    defp parse_datetime(_value),
      do: {:error, {:source_contract_violation, :invalid_date}}
  end

  defmodule FakeUpserter do
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], calls: []} end, name: __MODULE__)

    def reset!(responses) do
      Agent.update(__MODULE__, fn _ -> %{responses: responses, calls: []} end)
    end

    def calls do
      Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    end

    def upsert_order(source_system_id, payload) do
      Agent.get_and_update(__MODULE__, fn %{responses: [response | rest], calls: calls} = state ->
        result = response.(source_system_id, payload)
        {result, %{state | responses: rest, calls: [payload | calls]}}
      end)
    end
  end

  defmodule FakeNotifier do
    def notify_order_reconciled(_order, _run, _event_id, _opts \\ []), do: :ok
  end

  @from ~U[2026-05-01 08:00:00Z]
  @to ~U[2026-05-01 08:10:00Z]
  @tie_time "2026-05-01T08:05:00"

  setup do
    start_supervised!(FakeClient)
    start_supervised!(WooSourceContractClient)
    start_supervised!(MutableWooSourceContractClient)
    start_supervised!(FakeUpserter)

    original_rest = Application.get_env(:event_sales, :woocommerce_rest)

    Application.put_env(
      :event_sales,
      :woocommerce_rest,
      Keyword.merge(original_rest || [], per_page: 2, max_pages: 1)
    )

    on_exit(fn ->
      if original_rest do
        Application.put_env(:event_sales, :woocommerce_rest, original_rest)
      else
        Application.delete_env(:event_sales, :woocommerce_rest)
      end
    end)

    :ok
  end

  test "one historical step fetches at most one raw source page" do
    context = historical_context!()

    FakeClient.reset!([
      {:ok,
       [unmatched_order(1, "2026-05-01T08:01:00"), unmatched_order(2, "2026-05-01T08:02:00")]}
    ])

    assert {:continue, _run} = run_step(context)
    assert [{params, _opts}] = FakeClient.requests()

    assert params == %{
             "modified_after" => "2026-05-01T07:59:59Z",
             "modified_before" => "2026-05-01T08:10:01Z",
             "dates_are_gmt" => "true",
             "orderby" => "modified",
             "order" => "asc",
             "page" => "1",
             "per_page" => "2"
           }
  end

  test "historical source filters use strict UTC overlap and retain exact boundary seconds" do
    date_to = ~U[2026-05-01 08:10:00.500000Z]
    context = historical_context!(mapped: true, date_to: date_to)

    orders = [
      mapped_order(1, "2026-05-01T08:00:00"),
      mapped_order(2, "2026-05-01T08:10:00"),
      mapped_order(3, "2026-05-01T08:10:01")
    ]

    WooSourceContractClient.reset!(orders)

    FakeUpserter.reset!([
      fn _source, payload -> {:ok, %{id: payload["id"]}} end,
      fn _source, payload -> {:ok, %{id: payload["id"]}} end
    ])

    assert {:continue, _run} = run_step(context, woocommerce_client: WooSourceContractClient)
    assert {:complete, _run} = run_step(context, woocommerce_client: WooSourceContractClient)
    assert Enum.map(FakeUpserter.calls(), & &1["id"]) == [1, 2]

    assert [{first_params, _}, {second_params, _}] = WooSourceContractClient.requests()
    assert first_params["dates_are_gmt"] == "true"
    assert first_params["modified_after"] == "2026-05-01T07:59:59Z"
    assert first_params["modified_before"] == "2026-05-01T08:10:01Z"
    assert second_params["page"] == "1"
  end

  test "Woo's modified-plus-ID source order carries a same-timestamp bucket across pages" do
    context =
      historical_context!(
        mapped: true,
        cursor: %{modified_after: ~U[2026-05-01 08:05:00Z]}
      )

    WooSourceContractClient.reset!(Enum.map([10, 20, 30, 40], &mapped_order(&1, @tie_time)))

    FakeUpserter.reset!(
      Enum.map(1..4, fn _ -> fn _source, payload -> {:ok, %{id: payload["id"]}} end end)
    )

    assert {:continue, _run} = run_step(context, woocommerce_client: WooSourceContractClient)
    assert reloaded_cursor(context.run).last_seen_order_id == 20

    assert {:continue, _run} = run_step(context, woocommerce_client: WooSourceContractClient)
    assert reloaded_cursor(context.run).last_seen_order_id == 40

    assert {:complete, _run} = run_step(context, woocommerce_client: WooSourceContractClient)
    assert Enum.map(FakeUpserter.calls(), & &1["id"]) == [10, 20, 30, 40]

    assert [{first_params, _}, {second_params, _}, {third_params, _}] =
             WooSourceContractClient.requests()

    assert first_params["page"] == "1"
    assert second_params["page"] == "2"
    assert third_params["page"] == "3"
  end

  test "mutable source offset drift cannot complete before an unseen tie row is fetched" do
    context =
      historical_context!(
        cursor: %{modified_after: ~U[2026-05-01 08:05:00Z], last_seen_order_id: nil}
      )

    MutableWooSourceContractClient.reset!(
      Enum.map([10, 20, 30, 40], &unmatched_order(&1, @tie_time))
    )

    assert {:continue, _run} =
             run_step(context, woocommerce_client: MutableWooSourceContractClient)

    second_result =
      run_step(context, woocommerce_client: MutableWooSourceContractClient)

    fetched_ids = MutableWooSourceContractClient.fetched_ids()
    run = reloaded_run(context.run)
    cursor = reloaded_cursor(context.run)

    assert 10 in fetched_ids
    assert 20 in fetched_ids
    refute 30 in fetched_ids
    assert 40 in fetched_ids

    refute run.status == :completed and cursor.status == :done and 30 not in fetched_ids
    assert 30 in fetched_ids or match?({:error, _reason}, second_result)
  end

  test "a lower-ID same-timestamp page is rejected instead of silently skipping a tie row" do
    context =
      historical_context!(cursor: %{modified_after: ~U[2026-05-01 08:05:00Z]})

    FakeClient.reset!([
      {:ok, [unmatched_order(30, @tie_time), unmatched_order(40, @tie_time)]},
      {:ok, [unmatched_order(10, @tie_time), unmatched_order(20, @tie_time)]}
    ])

    assert {:continue, _run} = run_step(context)
    assert reloaded_cursor(context.run).last_seen_order_id == 40

    assert {:error, {:historical_source_order_regressed, _details}} = run_step(context)
    cursor = reloaded_cursor(context.run)
    assert cursor.last_seen_order_id == 40
    assert cursor.page == 2
    assert reloaded_run(context.run).status == :running
  end

  test "a full raw page does not complete a historical run" do
    context = historical_context!()

    FakeClient.reset!([
      {:ok,
       [unmatched_order(1, "2026-05-01T08:01:00"), unmatched_order(2, "2026-05-01T08:02:00")]}
    ])

    assert {:continue, result} = run_step(context)
    assert result.status == :running
    assert reloaded_run(context.run).status == :running
    assert reloaded_cursor(context.run).status == :active
  end

  test "configured max_pages does not establish historical completion" do
    context = historical_context!()

    FakeClient.reset!([
      {:ok,
       [unmatched_order(1, "2026-05-01T08:01:00"), unmatched_order(2, "2026-05-01T08:02:00")]}
    ])

    assert {:continue, _run} = run_step(context)
    assert reloaded_run(context.run).status == :running
  end

  test "a short raw page establishes terminal transport completion" do
    context = historical_context!()
    FakeClient.reset!([{:ok, [unmatched_order(1, "2026-05-01T08:01:00")]}])

    assert {:complete, result} = run_step(context)
    assert result.status == :completed
    assert reloaded_run(context.run).status == :completed
    assert reloaded_cursor(context.run).status == :done
  end

  test "an empty raw page establishes terminal transport completion" do
    context = historical_context!()
    FakeClient.reset!([{:ok, []}])

    assert {:complete, result} = run_step(context)
    assert result.status == :completed
    assert reloaded_cursor(context.run).status == :done
  end

  test "a full raw page with zero Event matches still advances raw-page progress" do
    context = historical_context!()

    FakeClient.reset!([
      {:ok,
       [unmatched_order(1, "2026-05-01T08:01:00"), unmatched_order(2, "2026-05-01T08:02:00")]}
    ])

    assert {:continue, _run} = run_step(context)
    cursor = reloaded_cursor(context.run)
    assert cursor.page == 1
    assert cursor.last_seen_order_id == 2
    assert DateTime.compare(cursor.modified_after, ~U[2026-05-01 08:02:00Z]) == :eq
  end

  test "same-timestamp rows are sorted by ID before high-water progression" do
    context = historical_context!()
    FakeClient.reset!([{:ok, [unmatched_order(30, @tie_time), unmatched_order(10, @tie_time)]}])

    assert {:continue, _run} = run_step(context)
    cursor = reloaded_cursor(context.run)
    assert DateTime.compare(cursor.modified_after, ~U[2026-05-01 08:05:00Z]) == :eq
    assert cursor.last_seen_order_id == 30
    assert cursor.page == 1
  end

  test "last_seen_order_id participates in same-timestamp overlap handling" do
    context =
      historical_context!(
        cursor: %{modified_after: ~U[2026-05-01 08:05:00Z], last_seen_order_id: 10}
      )

    FakeClient.reset!([{:ok, [unmatched_order(10, @tie_time), unmatched_order(11, @tie_time)]}])

    assert {:continue, _run} = run_step(context)
    cursor = reloaded_cursor(context.run)
    assert cursor.last_seen_order_id == 11
    assert cursor.status == :active
  end

  test "same-timestamp orders across pages are not skipped" do
    context = historical_context!()
    tie_page = [unmatched_order(10, @tie_time), unmatched_order(20, @tie_time)]
    overlap_page = [unmatched_order(20, @tie_time), unmatched_order(30, @tie_time)]
    FakeClient.reset!([{:ok, tie_page}, {:ok, overlap_page}, {:ok, []}])

    assert {:continue, _run} = run_step(context)
    assert reloaded_cursor(context.run).last_seen_order_id == 20

    assert {:continue, _run} = run_step(context)
    assert reloaded_cursor(context.run).last_seen_order_id == 30

    assert {:complete, _run} = run_step(context)
    assert reloaded_cursor(context.run).status == :done
  end

  test "a full overlap page is not mistaken for completion" do
    context =
      historical_context!(
        cursor: %{modified_after: ~U[2026-05-01 08:05:00Z], last_seen_order_id: 99}
      )

    FakeClient.reset!([{:ok, [unmatched_order(10, @tie_time), unmatched_order(11, @tie_time)]}])

    assert {:continue, _run} = run_step(context)
    assert reloaded_run(context.run).status == :running
    assert reloaded_cursor(context.run).page == 2
  end

  test "missing order ID fails closed before any durable write" do
    context = historical_context!()
    order = unmatched_order(1, "2026-05-01T08:01:00") |> Map.delete("id")
    FakeClient.reset!([{:ok, [order]}])

    assert {:error, {:invalid_historical_source_order, :id}} = run_step(context)
    assert FakeUpserter.calls() == []
    assert reloaded_cursor(context.run).status == :active
    assert reloaded_run(context.run).status == :running
  end

  test "invalid date_modified_gmt fails closed before any durable write" do
    context = historical_context!()
    order = unmatched_order(1, "not-a-date")
    FakeClient.reset!([{:ok, [order]}])

    assert {:error, {:invalid_historical_source_order, :date_modified_gmt}} = run_step(context)
    assert FakeUpserter.calls() == []
    assert reloaded_cursor(context.run).status == :active
  end

  test "an order exactly at the logical lower bound is eligible" do
    context = historical_context!(mapped: true)
    order = mapped_order(1, "2026-05-01T08:00:00")
    FakeClient.reset!([{:ok, [order]}])
    FakeUpserter.reset!([fn _source, payload -> {:ok, %{id: payload["id"]}} end])

    assert {:complete, _run} = run_step(context)
    assert [%{"id" => 1}] = FakeUpserter.calls()
  end

  test "an order outside the logical upper bound is not accepted" do
    context = historical_context!(mapped: true)
    order = mapped_order(1, "2026-05-01T08:11:00")
    FakeClient.reset!([{:ok, [order]}])
    FakeUpserter.reset!([fn _source, payload -> {:ok, %{id: payload["id"]}} end])

    assert {:complete, _run} = run_step(context)
    assert FakeUpserter.calls() == []
  end

  test "a historical upsert failure does not advance or complete the page" do
    context = historical_context!(mapped: true)

    FakeClient.reset!([
      {:ok, [mapped_order(1, "2026-05-01T08:01:00"), mapped_order(2, "2026-05-01T08:02:00")]}
    ])

    FakeUpserter.reset!([
      fn _source, _payload -> {:ok, %{id: "first"}} end,
      fn _source, _payload -> {:error, :database_unavailable} end
    ])

    assert {:error, {:historical_order_upsert_failed, :database_unavailable}} =
             run_step(context)

    cursor = reloaded_cursor(context.run)
    run = reloaded_run(context.run)
    assert cursor.status == :active
    assert cursor.page == 1
    assert cursor.last_seen_order_id == nil
    assert run.status == :running
    assert run.orders_seen_count == 0
    assert run.orders_failed_count == 0
  end

  test "partial successful writes replay safely after a later page failure" do
    context = historical_context!(mapped: true)
    page = [mapped_order(1, "2026-05-01T08:01:00"), mapped_order(2, "2026-05-01T08:02:00")]
    FakeClient.reset!([{:ok, page}, {:ok, page}])

    FakeUpserter.reset!([
      fn _source, _payload -> {:ok, %{id: "first"}} end,
      fn _source, _payload -> {:error, :temporary_failure} end
    ])

    assert {:error, {:historical_order_upsert_failed, :temporary_failure}} = run_step(context)

    FakeUpserter.reset!([
      fn _source, _payload -> {:ok, %{id: "replayed-first"}} end,
      fn _source, _payload -> {:ok, %{id: "second"}} end
    ])

    assert {:continue, continued} = run_step(context)
    assert continued.orders_seen_count == 2
    assert continued.orders_upserted_count == 2
    assert reloaded_cursor(context.run).last_seen_order_id == 2
  end

  test "checkpoint failure after a durable write replays without duplicate orders" do
    context = historical_context!(mapped: true)
    order = mapped_order(1, "2026-05-01T08:01:00")
    FakeClient.reset!([{:ok, [order]}, {:ok, [order]}])

    assert {:error, :checkpoint_unavailable} =
             run_step(context,
               order_upserter: OrderUpserter,
               checkpoint_fun: fn -> {:error, :checkpoint_unavailable} end
             )

    assert Ash.count!(Order, domain: Sales) == 1
    assert reloaded_cursor(context.run).status == :active
    assert reloaded_run(context.run).status == :running

    assert {:complete, completed} = run_step(context, order_upserter: OrderUpserter)
    assert completed.orders_upserted_count == 1
    assert Ash.count!(Order, domain: Sales) == 1
    assert reloaded_cursor(context.run).status == :done
    assert reloaded_run(context.run).status == :completed
  end

  test "historical execution requires the pre-created cursor" do
    context = historical_context!()

    assert {:error, :historical_cursor_required} =
             OrderReconciliation.run_historical_step(
               reloaded_run(context.run),
               nil,
               woocommerce_client: FakeClient
             )

    assert FakeClient.requests() == []
  end

  defp run_step(context, opts \\ []) do
    base_opts = [
      woocommerce_client: FakeClient,
      order_upserter: FakeUpserter,
      notifier: FakeNotifier
    ]

    OrderReconciliation.run_historical_step(
      reloaded_run(context.run),
      reloaded_cursor(context.run),
      Keyword.merge(base_opts, opts)
    )
  end

  defp historical_context!(opts \\ []) do
    source = SalesHelpers.create_source_system!()
    date_from = Keyword.get(opts, :date_from, @from)
    date_to = Keyword.get(opts, :date_to, @to)
    event = historical_event!(source, date_from)
    mapped = Keyword.get(opts, :mapped, false)

    if mapped do
      ticket = SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{name: "Mapped"})

      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: event.id,
          ticket_type_id: ticket.id,
          woo_product_id: 501,
          woo_variation_id: 601,
          original_label: "Mapped",
          current_label: "Mapped",
          active: true
        },
        action: :create,
        domain: Catalog
      )

      pending_event = Ash.get!(Event, event.id, domain: Catalog)

      if pending_event.analytics_onboarding_state == :unverified do
        Ash.update!(pending_event, %{}, action: :mark_backfill_pending, domain: Catalog)
      end
    end

    run = create_historical_run!(source, event, date_from, date_to)

    cursor_attrs = Keyword.get(opts, :cursor, %{})
    cursor = create_cursor!(run, cursor_attrs)
    %{run: run, cursor: cursor, source: source, event: event}
  end

  defp create_historical_run!(source, event, date_from, date_to) do
    {:ok, run} =
      SyncRun
      |> Ash.Changeset.for_create(:queue_historical_backfill, %{
        event_id: event.id,
        date_to: date_to
      })
      |> Ash.Changeset.force_change_attribute(:source_system_id, source.id)
      |> Ash.Changeset.force_change_attribute(:date_from, date_from)
      |> Ash.create(domain: Ingestion)

    Ash.update!(run, %{}, action: :start, domain: Ingestion)
  end

  defp create_cursor!(run, attrs) do
    defaults = %{
      sync_run_id: run.id,
      page: 1,
      modified_after: run.date_from,
      modified_before: run.date_to,
      last_seen_order_id: nil,
      metadata: %{}
    }

    {:ok, cursor} =
      SyncCursor
      |> Ash.Changeset.for_create(:upsert_active, Map.merge(defaults, attrs))
      |> Ash.create(domain: Ingestion)

    cursor
  end

  defp reloaded_run(run), do: Ash.get!(SyncRun, run.id, domain: Ingestion)

  defp reloaded_cursor(run) do
    SyncCursor
    |> Ash.Query.filter(sync_run_id == ^run.id)
    |> Ash.read_one!(domain: Ingestion)
  end

  defp mapped_order(id, modified_at) do
    FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)
    |> Map.put("id", id)
    |> Map.put("date_modified_gmt", modified_at)
  end

  defp unmatched_order(id, modified_at) do
    mapped_order(id, modified_at)
    |> update_in(["line_items", Access.at(0)], fn line_item ->
      Map.merge(line_item, %{"product_id" => 999_001, "variation_id" => 999_002})
    end)
  end

  defp historical_event!(source, source_created_at) do
    external_event_id = 70_500 + System.unique_integer([:positive])

    event =
      SalesHelpers.create_event!(source, %{
        name: "Historical execution #{external_event_id}",
        slug: unique_slug("historical-execution"),
        external_event_id: external_event_id,
        external_event_kind: :tickera_event
      })

    event = Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    Ash.update!(
      event,
      %{source_created_at: source_created_at},
      action: :capture_source_created_at,
      domain: Catalog,
      context: %{
        event_sales_backfill_start_capture_authority: {Catalog.Resources.Event, :verified}
      }
    )
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
