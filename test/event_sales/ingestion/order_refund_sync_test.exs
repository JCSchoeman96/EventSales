defmodule EventSales.Ingestion.OrderRefundSyncTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Ingestion.Clients.WooCommerceError
  alias EventSales.Ingestion.OrderRefundSync
  alias EventSales.Sales
  alias EventSales.Sales.RefundUpserter
  alias EventSales.Sales.Resources.Refund
  alias EventSales.TestSupport.SalesHelpers

  defmodule FakeClient do
    def configured_base_url(opts) do
      {:ok, Keyword.fetch!(opts, :configured_base_url)}
    end

    def list_refunds(order_id, params, opts) do
      state = Keyword.fetch!(opts, :state)

      Agent.get_and_update(state, fn current ->
        response = current.list_response
        calls = [{:list_refunds, order_id, params} | current.client_calls]
        {response, %{current | client_calls: calls}}
      end)
    end

    def fetch_refund(order_id, refund_id, opts) do
      state = Keyword.fetch!(opts, :state)

      Agent.get_and_update(state, fn current ->
        response =
          Map.get(
            current.fetch_responses,
            refund_id,
            {:error, WooCommerceError.exception(reason: :not_found)}
          )

        calls = [{:fetch_refund, order_id, refund_id} | current.client_calls]
        {response, %{current | client_calls: calls}}
      end)
    end
  end

  defmodule FakeUpserter do
    def upsert_refund(source_system_id, woo_order_id, raw_refund, opts) do
      state = Keyword.fetch!(opts, :state)

      Agent.get_and_update(state, fn current ->
        response =
          case current.upsert_responses do
            [response | rest] -> {response, rest}
            [] -> {current.default_upsert_response, []}
          end

        calls = [
          {:upsert_refund, source_system_id, woo_order_id, raw_refund}
          | current.upserter_calls
        ]

        {elem(response, 0),
         %{current | upsert_responses: elem(response, 1), upserter_calls: calls}}
      end)
    end

    def mark_source_deleted(source_system_id, woo_order_id, woo_refund_id, observed_at, opts) do
      state = Keyword.fetch!(opts, :state)

      Agent.get_and_update(state, fn current ->
        calls = [
          {:mark_source_deleted, source_system_id, woo_order_id, woo_refund_id, observed_at}
          | current.upserter_calls
        ]

        {current.default_void_response, %{current | upserter_calls: calls}}
      end)
    end
  end

  defmodule MissingClient do
  end

  defmodule RecordingUpserter do
    def upsert_refund(source_system_id, woo_order_id, raw_refund, opts) do
      state = Keyword.fetch!(opts, :state)

      Agent.update(state, fn current ->
        calls = [
          {:upsert_refund, source_system_id, woo_order_id, raw_refund}
          | current.upserter_calls
        ]

        %{current | upserter_calls: calls}
      end)

      EventSales.Sales.RefundUpserter.upsert_refund(
        source_system_id,
        woo_order_id,
        raw_refund
      )
    end

    def mark_source_deleted(
          source_system_id,
          woo_order_id,
          woo_refund_id,
          observed_at,
          opts
        ) do
      state = Keyword.fetch!(opts, :state)

      Agent.update(state, fn current ->
        calls = [
          {:mark_source_deleted, source_system_id, woo_order_id, woo_refund_id, observed_at}
          | current.upserter_calls
        ]

        %{current | upserter_calls: calls}
      end)

      EventSales.Sales.RefundUpserter.mark_source_deleted(
        source_system_id,
        woo_order_id,
        woo_refund_id,
        observed_at
      )
    end
  end

  defmodule FailingDurableUpserter do
    def upsert_refund(source_system_id, woo_order_id, raw_refund, opts) do
      state = Keyword.fetch!(opts, :state)

      call_number =
        Agent.get_and_update(state, fn current ->
          count = current.upsert_count + 1
          {count, %{current | upsert_count: count}}
        end)

      if call_number == 2 do
        {:error, :db_failed}
      else
        EventSales.Sales.RefundUpserter.upsert_refund(
          source_system_id,
          woo_order_id,
          raw_refund
        )
      end
    end

    def mark_source_deleted(
          source_system_id,
          woo_order_id,
          woo_refund_id,
          observed_at,
          _opts
        ) do
      EventSales.Sales.RefundUpserter.mark_source_deleted(
        source_system_id,
        woo_order_id,
        woo_refund_id,
        observed_at
      )
    end
  end

  setup do
    {:ok, source: SalesHelpers.create_source_system!(), state: start_state()}
  end

  test "accepts the exact active Woo SourceSystem and an empty refund list", %{
    source: source,
    state: state
  } do
    assert :ok = OrderRefundSync.sync_order(source.id, 10_001, sync_opts(source, state))
    assert client_calls(state) == [{:list_refunds, 10_001, %{}}]
  end

  test "rejects a missing SourceSystem before any source call", %{source: source, state: state} do
    opts =
      sync_opts(source, state)
      |> Keyword.put(:source_system_loader, fn _source_system_id -> {:ok, nil} end)

    assert {:error, :source_system_not_found} =
             OrderRefundSync.sync_order(source.id, 10_001, opts)

    assert client_calls(state) == []
  end

  test "rejects an inactive SourceSystem before any source call", %{source: source, state: state} do
    opts =
      sync_opts(source, state)
      |> Keyword.put(:source_system_loader, fn _source_system_id ->
        {:ok, %{source | active: false}}
      end)

    assert {:error, :source_system_inactive} =
             OrderRefundSync.sync_order(source.id, 10_001, opts)

    assert client_calls(state) == []
  end

  test "rejects a non-Woo SourceSystem before any source call", %{source: source, state: state} do
    opts =
      sync_opts(source, state)
      |> Keyword.put(:source_system_loader, fn _source_system_id ->
        {:ok, %{source | kind: :tickera}}
      end)

    assert {:error, :source_system_kind_mismatch} =
             OrderRefundSync.sync_order(source.id, 10_001, opts)

    assert client_calls(state) == []
  end

  test "rejects an invalid SourceSystem base URL before any source call", %{
    source: source,
    state: state
  } do
    opts =
      sync_opts(source, state)
      |> Keyword.put(:source_system_loader, fn _source_system_id ->
        {:ok, %{source | base_url: "not-a-url"}}
      end)

    assert {:error, :source_system_invalid} =
             OrderRefundSync.sync_order(source.id, 10_001, opts)

    assert client_calls(state) == []
  end

  test "rejects a configured Woo URL mismatch before listing refunds", %{
    source: source,
    state: state
  } do
    opts =
      sync_opts(source, state)
      |> Keyword.put(
        :woocommerce_client_opts,
        state: state,
        configured_base_url: "https://other.example.test"
      )

    assert {:error, :source_endpoint_mismatch} =
             OrderRefundSync.sync_order(source.id, 10_001, opts)

    assert client_calls(state) == []
  end

  test "rejects a misconfigured client before listing refunds", %{source: source, state: state} do
    opts = sync_opts(source, state) |> Keyword.put(:woocommerce_client, MissingClient)

    assert {:error, :source_client_misconfigured} =
             OrderRefundSync.sync_order(source.id, 10_001, opts)

    assert client_calls(state) == []
  end

  test "rejects an invalid refund list response without upserting", %{
    source: source,
    state: state
  } do
    put_state(state, list_response: {:ok, %{id: 98_001}})

    assert {:error, :invalid_refund_list_response} =
             OrderRefundSync.sync_order(source.id, 10_001, sync_opts(source, state))

    assert upserter_calls(state) == []
  end

  test "rejects invalid and duplicate refund IDs without guessing identity", %{
    source: source,
    state: state
  } do
    for invalid_response <- [
          {:ok, [%{"id" => 0}]},
          {:ok, [%{"id" => -1}]},
          {:ok, [%{"amount" => "45.00"}]},
          {:ok, [%{"id" => "not-an-id"}]}
        ] do
      put_state(state, list_response: invalid_response, upserter_calls: [])

      assert {:error, :invalid_refund_list_response} =
               OrderRefundSync.sync_order(source.id, 10_001, sync_opts(source, state))
    end

    put_state(state,
      list_response: {:ok, [%{"id" => 98_001}, %{"id" => 98_001}]},
      upserter_calls: []
    )

    assert {:error, :duplicate_refund_id} =
             OrderRefundSync.sync_order(source.id, 10_001, sync_opts(source, state))

    assert upserter_calls(state) == []
  end

  test "delegates every listed full refund object and avoids detail N+1", %{
    source: source,
    state: state
  } do
    refunds = [
      %{"id" => 98_001, "amount" => "45.00"},
      %{"id" => 98_002, "amount" => "20.00"}
    ]

    put_state(state, list_response: {:ok, refunds})

    assert :ok = OrderRefundSync.sync_order(source.id, 10_001, sync_opts(source, state))

    assert [
             {:upsert_refund, source_id, 10_001, %{"id" => 98_001, "amount" => "45.00"}},
             {:upsert_refund, source_id, 10_001, %{"id" => 98_002, "amount" => "20.00"}}
           ] = upserter_calls(state)

    assert source_id == source.id
    assert client_calls(state) == [{:list_refunds, 10_001, %{}}]
  end

  test "persists one full listed refund through RefundUpserter", %{source: source, state: state} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    raw_refund = %{
      "id" => 98_003,
      "amount" => "45.00",
      "reason" => "customer request",
      "date_created_gmt" => "2026-08-18T10:00:00",
      "line_items" => []
    }

    put_state(state, list_response: {:ok, [raw_refund]})

    opts =
      sync_opts(source, state)
      |> Keyword.put(:refund_upserter, RefundUpserter)
      |> Keyword.put(:refund_upserter_opts, [])

    assert :ok = OrderRefundSync.sync_order(source.id, order.woo_order_id, opts)

    assert [%Refund{woo_refund_id: 98_003, detail_status: :complete}] =
             Ash.read!(Refund, domain: Sales)
  end

  test "replays the same list idempotently", %{source: source, state: state} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    raw_refund = %{"id" => 98_004, "amount" => "45.00", "line_items" => []}
    put_state(state, list_response: {:ok, [raw_refund]})

    opts =
      sync_opts(source, state)
      |> Keyword.put(:refund_upserter, RefundUpserter)
      |> Keyword.put(:refund_upserter_opts, [])

    assert :ok = OrderRefundSync.sync_order(source.id, order.woo_order_id, opts)
    assert :ok = OrderRefundSync.sync_order(source.id, order.woo_order_id, opts)
    assert Ash.count!(Refund, domain: Sales) == 1
  end

  test "fails closed when a listed refund identity is already voided", %{
    source: source,
    state: state
  } do
    put_state(state,
      list_response: {:ok, [%{"id" => 98_005}]},
      default_upsert_response: {:ok, %{source_state: :voided}}
    )

    assert {:error, :voided_refund_reappeared} =
             OrderRefundSync.sync_order(source.id, 10_001, sync_opts(source, state))

    assert client_calls(state) == [{:list_refunds, 10_001, %{}}]
  end

  test "does not void an omitted active refund until exact confirmation finds it", %{
    source: source,
    state: state
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    source_id = source.id
    order_id = order.woo_order_id
    raw_refund = %{"id" => 99_001, "amount" => "45.00", "line_items" => []}
    assert {:ok, _refund} = RefundUpserter.upsert_refund(source_id, order_id, raw_refund)

    put_state(state,
      list_response: {:ok, []},
      fetch_responses: %{99_001 => {:ok, raw_refund}}
    )

    assert :ok =
             OrderRefundSync.sync_order(
               source_id,
               order_id,
               durable_sync_opts(source, state)
             )

    assert [%Refund{source_state: :active, woo_refund_id: 99_001}] =
             Ash.read!(Refund, domain: Sales)

    assert [
             {:upsert_refund, ^source_id, ^order_id, ^raw_refund}
           ] = upserter_calls(state)

    assert client_calls(state) == [
             {:list_refunds, order_id, %{}},
             {:fetch_refund, order_id, 99_001}
           ]
  end

  test "voids an omitted active refund only after exact not-found confirmation", %{
    source: source,
    state: state
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    source_id = source.id
    order_id = order.woo_order_id
    raw_refund = %{"id" => 99_002, "amount" => "45.00", "line_items" => []}
    assert {:ok, _refund} = RefundUpserter.upsert_refund(source_id, order_id, raw_refund)

    observed_at = ~U[2026-08-18 11:00:00Z]
    put_state(state, list_response: {:ok, []})

    assert :ok =
             OrderRefundSync.sync_order(
               source_id,
               order_id,
               durable_sync_opts(source, state, observed_at)
             )

    assert [%Refund{source_state: :voided, void_reason: "source_deleted"} = voided] =
             Ash.read!(Refund, domain: Sales)

    assert DateTime.compare(voided.voided_at, observed_at) == :eq

    assert [{:mark_source_deleted, ^source_id, ^order_id, 99_002, ^observed_at}] =
             upserter_calls(state)

    assert client_calls(state) == [
             {:list_refunds, order_id, %{}},
             {:fetch_refund, order_id, 99_002}
           ]
  end

  test "leaves an omitted active refund active on transient confirmation failure", %{
    source: source,
    state: state
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    raw_refund = %{"id" => 99_003, "amount" => "45.00", "line_items" => []}

    assert {:ok, _refund} =
             RefundUpserter.upsert_refund(source.id, order.woo_order_id, raw_refund)

    put_state(state,
      list_response: {:ok, []},
      fetch_responses: %{
        99_003 => {:error, WooCommerceError.exception(reason: :timeout)}
      }
    )

    assert {:error, :timeout} =
             OrderRefundSync.sync_order(
               source.id,
               order.woo_order_id,
               durable_sync_opts(source, state)
             )

    assert [%Refund{source_state: :active}] = Ash.read!(Refund, domain: Sales)
    assert upserter_calls(state) == []
  end

  test "leaves an omitted active refund active on permanent confirmation failure", %{
    source: source,
    state: state
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    raw_refund = %{"id" => 99_004, "amount" => "45.00", "line_items" => []}

    assert {:ok, _refund} =
             RefundUpserter.upsert_refund(source.id, order.woo_order_id, raw_refund)

    put_state(state,
      list_response: {:ok, []},
      fetch_responses: %{
        99_004 => {:error, WooCommerceError.exception(reason: :forbidden)}
      }
    )

    assert {:error, :forbidden} =
             OrderRefundSync.sync_order(
               source.id,
               order.woo_order_id,
               durable_sync_opts(source, state)
             )

    assert [%Refund{source_state: :active}] = Ash.read!(Refund, domain: Sales)
    assert upserter_calls(state) == []
  end

  test "rejects an exact confirmation with a different refund identity", %{
    source: source,
    state: state
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    raw_refund = %{"id" => 99_010, "amount" => "45.00", "line_items" => []}

    assert {:ok, _refund} =
             RefundUpserter.upsert_refund(source.id, order.woo_order_id, raw_refund)

    put_state(state,
      list_response: {:ok, []},
      fetch_responses: %{99_010 => {:ok, %{"id" => 99_011, "amount" => "45.00"}}}
    )

    assert {:error, :invalid_refund_detail_response} =
             OrderRefundSync.sync_order(
               source.id,
               order.woo_order_id,
               durable_sync_opts(source, state)
             )

    assert [%Refund{source_state: :active}] = Ash.read!(Refund, domain: Sales)
    assert upserter_calls(state) == []
  end

  test "does not run deletion discovery after a partial list persistence failure", %{
    source: source,
    state: state
  } do
    put_state(state,
      list_response: {:ok, [%{"id" => 99_005}, %{"id" => 99_006}]},
      upsert_responses: [{:ok, %{source_state: :active}}, {:error, :db_failed}],
      upserter_calls: []
    )

    assert {:error, :refund_upsert_failed} =
             OrderRefundSync.sync_order(source.id, 10_001, sync_opts(source, state))

    assert client_calls(state) == [{:list_refunds, 10_001, %{}}]
    assert length(upserter_calls(state)) == 2
  end

  test "replay after a partial list failure converges to one row per refund", %{
    source: source,
    state: state
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    refunds = [
      %{"id" => 99_007, "amount" => "45.00", "line_items" => []},
      %{"id" => 99_008, "amount" => "20.00", "line_items" => []}
    ]

    put_state(state, list_response: {:ok, refunds}, upsert_count: 0)

    opts =
      sync_opts(source, state)
      |> Keyword.put(:refund_upserter, FailingDurableUpserter)
      |> Keyword.put(:refund_upserter_opts, state: state)

    assert {:error, :refund_upsert_failed} =
             OrderRefundSync.sync_order(source.id, order.woo_order_id, opts)

    assert :ok = OrderRefundSync.sync_order(source.id, order.woo_order_id, opts)
    assert Ash.count!(Refund, domain: Sales) == 2

    assert client_calls(state) == [
             {:list_refunds, order.woo_order_id, %{}},
             {:list_refunds, order.woo_order_id, %{}}
           ]
  end

  test "does not reactivate a durable voided identity that reappears in the list", %{
    source: source,
    state: state
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    raw_refund = %{"id" => 99_009, "amount" => "45.00", "line_items" => []}
    assert {:ok, refund} = RefundUpserter.upsert_refund(source.id, order.woo_order_id, raw_refund)

    assert {:ok, voided} =
             RefundUpserter.mark_source_deleted(
               source.id,
               order.woo_order_id,
               refund.woo_refund_id,
               ~U[2026-08-18 11:01:00Z]
             )

    put_state(state, list_response: {:ok, [raw_refund]})

    opts =
      durable_sync_opts(source, state)
      |> Keyword.put(:observed_at, ~U[2026-08-18 11:02:00Z])

    assert {:error, :voided_refund_reappeared} =
             OrderRefundSync.sync_order(source.id, order.woo_order_id, opts)

    assert [%Refund{source_state: :voided, voided_at: voided_at}] =
             Ash.read!(Refund, domain: Sales)

    assert DateTime.compare(voided_at, voided.voided_at) == :eq
    assert client_calls(state) == [{:list_refunds, order.woo_order_id, %{}}]
  end

  defp sync_opts(source, state) do
    [
      source_system_loader: fn source_system_id ->
        if source_system_id == source.id, do: {:ok, source}, else: {:ok, nil}
      end,
      woocommerce_client: FakeClient,
      woocommerce_client_opts: [state: state, configured_base_url: source.base_url],
      refund_upserter: FakeUpserter,
      refund_upserter_opts: [state: state],
      observed_at: ~U[2026-08-18 10:00:00Z]
    ]
  end

  defp durable_sync_opts(source, state, observed_at \\ ~U[2026-08-18 10:00:00Z]) do
    sync_opts(source, state)
    |> Keyword.put(:refund_upserter, RecordingUpserter)
    |> Keyword.put(:refund_upserter_opts, state: state)
    |> Keyword.put(:observed_at, observed_at)
  end

  defp start_state do
    Agent.start_link(fn ->
      %{
        list_response: {:ok, []},
        fetch_responses: %{},
        default_upsert_response: {:ok, %{source_state: :active}},
        upsert_responses: [],
        default_void_response: {:ok, %{source_state: :voided}},
        client_calls: [],
        upserter_calls: [],
        upsert_count: 0
      }
    end)
    |> elem(1)
  end

  defp put_state(state, attrs) do
    Agent.update(state, &Map.merge(&1, Map.new(attrs)))
  end

  defp client_calls(state) do
    Agent.get(state, fn current -> Enum.reverse(current.client_calls) end)
  end

  defp upserter_calls(state) do
    Agent.get(state, fn current -> Enum.reverse(current.upserter_calls) end)
  end
end
