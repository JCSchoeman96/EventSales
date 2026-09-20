defmodule EventSales.Ingestion.FinancialReconciliation.SourceExtractorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.FinancialReconciliation.SourceExtractor

  alias EventSales.Ingestion.Resources.{
    HistoricalOrderMembership,
    HistoricalRefundObservation,
    HistoricalRefundReference,
    SyncRun
  }

  alias EventSales.Repo
  alias EventSales.TestSupport.{HistoricalCoverageHelpers, SalesHelpers}

  require Ash.Query

  @source_url "https://m4-source.example.test"
  @coverage_start ~U[2026-08-01 08:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @refunds_covered_through ~U[2026-08-13 12:00:00.000000Z]
  @modified_at ~U[2026-08-04 10:00:00.000000Z]
  @observed_at ~U[2026-08-13 11:00:00.000000Z]
  @now ~U[2026-08-13 12:30:00.000000Z]
  @certified_at ~U[2026-08-10 10:00:00.000000Z]
  @newer_certified_at ~U[2026-08-11 10:00:00.000000Z]

  defmodule WooClient do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(_opts),
      do: Agent.start_link(fn -> %{orders: %{}, refunds: %{}, calls: []} end, name: __MODULE__)

    def reset!, do: Agent.update(__MODULE__, fn _ -> %{orders: %{}, refunds: %{}, calls: []} end)

    def put_order!(id, response),
      do: Agent.update(__MODULE__, &put_in(&1, [:orders, to_string(id)], {:ok, response}))

    def put_refund!(order_id, refund_id, response),
      do:
        Agent.update(
          __MODULE__,
          &put_in(&1, [:refunds, {to_string(order_id), refund_id}], {:ok, response})
        )

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def configured_base_url(_opts), do: {:ok, "https://m4-source.example.test"}

    def fetch_order(id, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        response = Map.get(state.orders, to_string(id), {:error, :not_found})
        {response, %{state | calls: [{:fetch_order, id} | state.calls]}}
      end)
    end

    def fetch_refund(order_id, refund_id, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        response =
          Map.get(state.refunds, {to_string(order_id), refund_id}, {:error, :not_found})

        {response, %{state | calls: [{:fetch_refund, order_id, refund_id} | state.calls]}}
      end)
    end
  end

  defmodule Selector do
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def start_link(_opts),
      do: Agent.start_link(fn -> %{lines_by_order: %{}, calls: []} end, name: __MODULE__)

    def reset!, do: Agent.update(__MODULE__, fn _ -> %{lines_by_order: %{}, calls: []} end)

    def set_lines!(order_id, lines),
      do: Agent.update(__MODULE__, &put_in(&1, [:lines_by_order, order_id], lines))

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def select(_event, _source, order) do
      Agent.get_and_update(__MODULE__, fn state ->
        lines = Map.get(state.lines_by_order, order["id"], [])
        {{:ok, lines}, %{state | calls: [{order["id"]} | state.calls]}}
      end)
    end
  end

  setup do
    start_supervised!(WooClient)
    start_supervised!(Selector)
    WooClient.reset!()
    Selector.reset!()

    source = SalesHelpers.create_source_system!(%{base_url: @source_url})

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 901_001,
        external_event_kind: :tickera_event
      })

    event =
      Ash.update!(event, %{source_created_at: @coverage_start},
        action: :capture_source_created_at,
        domain: Catalog,
        context: %{event_sales_backfill_start_capture_authority: {Event, :verified}}
      )

    run = certified_run!(event)

    %{source: source, event: event, run: run}
  end

  test "extracts gross and refund primitives for manifest-resolved target members", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_001, :target, :manifest, [701])

    Selector.set_lines!(10_001, [
      %{"id" => 501, "quantity" => 2, "total" => "80.00", "total_tax" => "12.00"}
    ])

    WooClient.put_order!(
      10_001,
      order_payload(10_001,
        status: "completed",
        line_items: [%{"id" => 501}],
        refunds: [%{"id" => 701, "total" => "-46.00"}]
      )
    )

    WooClient.put_refund!(
      10_001,
      701,
      refund_payload(701, 501, qty: 1, total: "40.00", tax: "6.00")
    )

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3,
               now: @now
             )

    assert result.sync_run_id == run.id
    assert result.source_orders_fetched == 1
    assert result.source_refunds_fetched == 1
    assert result.source_observed_at == @now

    totals = result.currencies["ZAR"]

    assert Decimal.equal?(totals.gross_ticket_quantity, Decimal.new("2"))
    assert Decimal.equal?(totals.gross_ticket_value, Decimal.new("92.00"))
    assert Decimal.equal?(totals.refund_ticket_quantity, Decimal.new("1"))
    assert Decimal.equal?(totals.refund_ticket_value, Decimal.new("46.00"))
    assert Decimal.equal?(totals.net_ticket_quantity, Decimal.new("1"))
    assert Decimal.equal?(totals.net_ticket_value, Decimal.new("46.00"))
  end

  test "includes catchup-resolved target members without filtering on resolution_state", %{
    source: source,
    event: event,
    run: run
  } do
    membership = create_membership!(run, 10_002, :target, :manifest, [])

    Ash.update!(
      membership,
      %{last_source_modified_at: @modified_at, event_match_state: :target},
      action: :resolve_catchup,
      domain: Ingestion
    )

    Selector.set_lines!(10_002, [
      %{"id" => 502, "quantity" => 1, "total" => "50.00", "total_tax" => "7.50"}
    ])

    WooClient.put_order!(10_002, order_payload(10_002, status: "completed"))

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    totals = result.currencies["ZAR"]
    assert Decimal.equal?(totals.gross_ticket_quantity, Decimal.new("1"))
    assert Decimal.equal?(totals.gross_ticket_value, Decimal.new("57.50"))
  end

  test "ignores non-target membership rows", %{source: source, event: event, run: run} do
    create_membership!(run, 10_003, :non_target, :manifest, [])
    create_membership!(run, 10_004, :target, :manifest, [])

    Selector.set_lines!(10_004, [
      %{"id" => 504, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(10_004, order_payload(10_004, status: "completed"))

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    assert result.source_orders_fetched == 1
    assert [{:fetch_order, 10_004}] = WooClient.calls()
  end

  test "returns source_snapshot_stale when Woo modified timestamp drifts", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_005, :target, :manifest, [])

    WooClient.put_order!(
      10_005,
      order_payload(10_005,
        modified_at: ~U[2026-08-05 10:00:00.000000Z],
        status: "completed"
      )
    )

    assert {:error, {:source_snapshot_stale, details}} =
             SourceExtractor.extract_for_run(run, event, source, woo_client: WooClient)

    assert details.source_order_id == 10_005
  end

  test "returns refund_identity_drift when Woo refund ids differ from M3 references", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_006, :target, :manifest, [801])

    WooClient.put_order!(
      10_006,
      order_payload(10_006,
        status: "completed",
        refunds: [%{"id" => 802, "total" => "-10.00"}]
      )
    )

    assert {:error, {:refund_identity_drift, details}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    assert details.source_order_id == 10_006
    assert 802 in details.woo_refund_ids
    assert 801 in details.expected_refund_ids
  end

  test "returns missing_source_fact for missing Woo order", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_007, :target, :manifest, [])

    assert {:error, {:missing_source_fact, %{kind: :order, source_order_id: 10_007}}} =
             SourceExtractor.extract_for_run(run, event, source, woo_client: WooClient)
  end

  test "returns missing_source_fact for missing Woo refund", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_008, :target, :manifest, [901])

    Selector.set_lines!(10_008, [
      %{"id" => 508, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(
      10_008,
      order_payload(10_008,
        status: "completed",
        refunds: [%{"id" => 901, "total" => "-10.00"}]
      )
    )

    assert {:error, {:missing_source_fact, details}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    assert details.kind == :refund
    assert details.woo_refund_id == 901
  end

  test "returns historical_recognition_unproven for refunded order without completion evidence",
       %{
         source: source,
         event: event,
         run: run
       } do
    create_membership!(run, 10_009, :target, :manifest, [911])

    WooClient.put_order!(
      10_009,
      order_payload(10_009,
        status: "refunded",
        completed_at: nil,
        refunds: [%{"id" => 911, "total" => "-10.00"}]
      )
    )

    assert {:error, {:historical_recognition_unproven, details}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    assert details.woo_order_id == 10_009
    assert details.status == "refunded"
  end

  test "recognises gross from completion timestamp even when status is not completed", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_010, :target, :manifest, [])

    Selector.set_lines!(10_010, [
      %{"id" => 510, "quantity" => 1, "total" => "25.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(
      10_010,
      order_payload(10_010,
        status: "processing",
        completed_at: ~U[2026-08-04 11:00:00.000000Z]
      )
    )

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    totals = result.currencies["ZAR"]
    assert Decimal.equal?(totals.gross_ticket_quantity, Decimal.new("1"))
  end

  test "accumulates totals per currency across multiple target members", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_011, :target, :manifest, [])
    create_membership!(run, 10_012, :target, :manifest, [])

    Selector.set_lines!(10_011, [
      %{"id" => 511, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    Selector.set_lines!(10_012, [
      %{"id" => 512, "quantity" => 1, "total" => "20.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(10_011, order_payload(10_011, status: "completed", currency: "ZAR"))
    WooClient.put_order!(10_012, order_payload(10_012, status: "completed", currency: "USD"))

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    assert Decimal.equal?(result.currencies["ZAR"].gross_ticket_value, Decimal.new("10.00"))
    assert Decimal.equal?(result.currencies["USD"].gross_ticket_value, Decimal.new("20.00"))
    assert result.source_orders_fetched == 2
  end

  test "extract resolves the current certified run for an event", %{
    event: event,
    source: source,
    run: run
  } do
    create_membership!(run, 10_013, :target, :manifest, [])

    Selector.set_lines!(10_013, [
      %{"id" => 513, "quantity" => 1, "total" => "5.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(10_013, order_payload(10_013, status: "completed"))

    assert {:ok, result} =
             SourceExtractor.extract(event.id,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    assert result.sync_run_id == run.id
    assert result.event_id == event.id
    assert result.source_system_id == source.id
  end

  test "returns http_under_lock when called inside a database transaction", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_014, :target, :manifest, [])

    WooClient.put_order!(10_014, order_payload(10_014, status: "completed"))

    assert {:ok, {:error, {:http_under_lock, %{source_order_id: 10_014}}}} =
             Repo.transaction(fn ->
               SourceExtractor.extract_for_run(run, event, source, woo_client: WooClient)
             end)
  end

  test "returns empty currency totals when no target memberships exist", %{
    source: source,
    event: event,
    run: run
  } do
    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source, woo_client: WooClient)

    assert result.currencies == %{}
    assert result.source_orders_fetched == 0
    assert result.source_refunds_fetched == 0
  end

  test "processes memberships in bounded batches", %{source: source, event: event, run: run} do
    Enum.each(10_020..10_022, fn order_id ->
      create_membership!(run, order_id, :target, :manifest, [])

      Selector.set_lines!(order_id, [
        %{"id" => order_id + 100, "quantity" => 1, "total" => "1.00", "total_tax" => "0.00"}
      ])

      WooClient.put_order!(order_id, order_payload(order_id, status: "completed"))
    end)

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3,
               batch_size: 2
             )

    assert result.source_orders_fetched == 3
    assert Decimal.equal?(result.currencies["ZAR"].gross_ticket_quantity, Decimal.new("3"))
  end

  test "accepts only the current exact M3 certificate", %{source: source, event: event, run: run} do
    create_membership!(run, 10_030, :target, :manifest, [])

    Selector.set_lines!(10_030, [
      %{"id" => 530, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(10_030, order_payload(10_030, status: "completed"))

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    assert result.sync_run_id == run.id
  end

  test "blocks an older certified run when a newer current certificate exists", %{
    source: source,
    event: event,
    run: setup_run
  } do
    older = setup_run |> set_certified_at!(@certified_at)
    _newer = certified_run!(event) |> set_certified_at!(@newer_certified_at)

    create_membership!(older, 10_031, :target, :manifest, [])
    WooClient.put_order!(10_031, order_payload(10_031, status: "completed"))

    assert {:error, {:invalid_scope, %{reason: :historical_certificate_not_current}}} =
             SourceExtractor.extract_for_run(older, event, source, woo_client: WooClient)

    refute Enum.any?(WooClient.calls(), &match?({:fetch_order, _}, &1))
  end

  test "blocks an invalidated supplied certificate", %{source: source, event: event, run: run} do
    create_membership!(run, 10_032, :target, :manifest, [])
    WooClient.put_order!(10_032, order_payload(10_032, status: "completed"))

    assert {:ok, invalidated} =
             Ash.update(
               run,
               %{coverage_invalidation_reason: :historical_order_changed},
               action: :invalidate_order_coverage,
               domain: Ingestion
             )

    assert {:error, {:invalid_scope, %{reason: :historical_certificate_not_current}}} =
             SourceExtractor.extract_for_run(invalidated, event, source, woo_client: WooClient)

    refute Enum.any?(WooClient.calls(), &match?({:fetch_order, _}, &1))
  end

  test "blocks missing gross total", %{source: source, event: event, run: run} do
    create_membership!(run, 10_040, :target, :manifest, [])

    Selector.set_lines!(10_040, [
      %{"id" => 540, "quantity" => 1, "total_tax" => "0.00"}
    ])

    WooClient.put_order!(10_040, order_payload(10_040, status: "completed"))

    assert {:error, {:financial_primitive_incomplete, %{field: :total}}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )
  end

  test "blocks invalid gross total", %{source: source, event: event, run: run} do
    create_membership!(run, 10_041, :target, :manifest, [])

    Selector.set_lines!(10_041, [
      %{"id" => 541, "quantity" => 1, "total" => "not-money", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(10_041, order_payload(10_041, status: "completed"))

    assert {:error, {:financial_primitive_incomplete, %{field: :total, reason: :invalid}}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )
  end

  test "blocks missing gross total_tax", %{source: source, event: event, run: run} do
    create_membership!(run, 10_042, :target, :manifest, [])

    Selector.set_lines!(10_042, [
      %{"id" => 542, "quantity" => 1, "total" => "10.00"}
    ])

    WooClient.put_order!(10_042, order_payload(10_042, status: "completed"))

    assert {:error, {:financial_primitive_incomplete, %{field: :total_tax}}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )
  end

  test "blocks invalid gross total_tax", %{source: source, event: event, run: run} do
    create_membership!(run, 10_043, :target, :manifest, [])

    Selector.set_lines!(10_043, [
      %{"id" => 543, "quantity" => 1, "total" => "10.00", "total_tax" => "bad"}
    ])

    WooClient.put_order!(10_043, order_payload(10_043, status: "completed"))

    assert {:error, {:financial_primitive_incomplete, %{field: :total_tax, reason: :invalid}}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )
  end

  test "accepts explicit zero gross total_tax", %{source: source, event: event, run: run} do
    create_membership!(run, 10_044, :target, :manifest, [])

    Selector.set_lines!(10_044, [
      %{"id" => 544, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(10_044, order_payload(10_044, status: "completed"))

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    assert Decimal.equal?(result.currencies["ZAR"].gross_ticket_value, Decimal.new("10.00"))
  end

  test "excludes refund lines bound to another real parent order line", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_050, :target, :manifest, [750])

    Selector.set_lines!(10_050, [
      %{"id" => 550, "quantity" => 1, "total" => "50.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(
      10_050,
      order_payload(10_050,
        status: "completed",
        line_items: [%{"id" => 550}, %{"id" => 551}],
        refunds: [%{"id" => 750, "total" => "-10.00"}]
      )
    )

    WooClient.put_refund!(
      10_050,
      750,
      refund_payload(750, 551, qty: 1, total: "10.00", tax: "0.00")
    )

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    assert Decimal.equal?(result.currencies["ZAR"].refund_ticket_quantity, Decimal.new("0"))
  end

  test "blocks missing refund binder", %{source: source, event: event, run: run} do
    create_membership!(run, 10_051, :target, :manifest, [751])

    Selector.set_lines!(10_051, [
      %{"id" => 551, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(
      10_051,
      order_payload(10_051,
        status: "completed",
        line_items: [%{"id" => 551}],
        refunds: [%{"id" => 751, "total" => "-10.00"}]
      )
    )

    WooClient.put_refund!(10_051, 751, refund_payload(751, 551, meta_data: []))

    assert {:error, {:unresolved_attribution, %{reason: "missing_refunded_item_id"}}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )
  end

  test "blocks invalid refund binder", %{source: source, event: event, run: run} do
    create_membership!(run, 10_052, :target, :manifest, [752])

    Selector.set_lines!(10_052, [
      %{"id" => 552, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(
      10_052,
      order_payload(10_052,
        status: "completed",
        line_items: [%{"id" => 552}],
        refunds: [%{"id" => 752, "total" => "-10.00"}]
      )
    )

    WooClient.put_refund!(
      10_052,
      752,
      refund_payload(752, 552, meta_data: [%{"key" => "_refunded_item_id", "value" => "bad"}])
    )

    assert {:error, {:unresolved_attribution, %{reason: "invalid_refunded_item_id"}}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )
  end

  test "blocks conflicting refund binder", %{source: source, event: event, run: run} do
    create_membership!(run, 10_053, :target, :manifest, [753])

    Selector.set_lines!(10_053, [
      %{"id" => 553, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(
      10_053,
      order_payload(10_053,
        status: "completed",
        line_items: [%{"id" => 553}, %{"id" => 554}],
        refunds: [%{"id" => 753, "total" => "-10.00"}]
      )
    )

    WooClient.put_refund!(
      10_053,
      753,
      refund_payload(753, 553,
        meta_data: [
          %{"key" => "_refunded_item_id", "value" => "553"},
          %{"key" => "_refunded_item_id", "value" => "554"}
        ]
      )
    )

    assert {:error, {:unresolved_attribution, %{reason: "conflicting_refunded_item_id"}}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )
  end

  test "blocks unknown parent line binder", %{source: source, event: event, run: run} do
    create_membership!(run, 10_054, :target, :manifest, [754])

    Selector.set_lines!(10_054, [
      %{"id" => 554, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(
      10_054,
      order_payload(10_054,
        status: "completed",
        line_items: [%{"id" => 554}],
        refunds: [%{"id" => 754, "total" => "-10.00"}]
      )
    )

    WooClient.put_refund!(10_054, 754, refund_payload(754, 99_999))

    assert {:error, {:unresolved_attribution, %{reason: :unknown_parent_line_binder}}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )
  end

  test "blocks missing date_modified_gmt", %{source: source, event: event, run: run} do
    create_membership!(run, 10_060, :target, :manifest, [])

    payload = order_payload(10_060, status: "completed") |> Map.delete("date_modified_gmt")
    WooClient.put_order!(10_060, payload)

    assert {:error, {:timestamp_incomplete, %{field: "date_modified_gmt", reason: :missing}}} =
             SourceExtractor.extract_for_run(run, event, source, woo_client: WooClient)
  end

  test "blocks blank date_modified_gmt", %{source: source, event: event, run: run} do
    create_membership!(run, 10_061, :target, :manifest, [])

    WooClient.put_order!(
      10_061,
      order_payload(10_061, status: "completed", modified_at: "")
    )

    assert {:error, {:timestamp_incomplete, %{field: "date_modified_gmt", reason: :blank}}} =
             SourceExtractor.extract_for_run(run, event, source, woo_client: WooClient)
  end

  test "blocks malformed date_modified_gmt", %{source: source, event: event, run: run} do
    create_membership!(run, 10_062, :target, :manifest, [])

    WooClient.put_order!(
      10_062,
      Map.put(order_payload(10_062, status: "completed"), "date_modified_gmt", "not-a-timestamp")
    )

    assert {:error, {:timestamp_incomplete, %{field: "date_modified_gmt", reason: :invalid}}} =
             SourceExtractor.extract_for_run(run, event, source, woo_client: WooClient)
  end

  test "accepts explicit zero refund observation", %{source: source, event: event, run: run} do
    create_membership!(run, 10_070, :target, :manifest, [])

    Selector.set_lines!(10_070, [
      %{"id" => 570, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(10_070, order_payload(10_070, status: "completed"))

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    assert result.source_refunds_fetched == 0
  end

  test "blocks selected ticket refund line missing total", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_080, :target, :manifest, [780])

    Selector.set_lines!(10_080, [
      %{"id" => 580, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(
      10_080,
      order_payload(10_080,
        status: "completed",
        line_items: [%{"id" => 580}],
        refunds: [%{"id" => 780, "total" => "-10.00"}]
      )
    )

    WooClient.put_refund!(10_080, 780, refund_payload(780, 580, include_total: false))

    assert {:error, {:financial_primitive_incomplete, %{field: :refund_total_amount}}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )
  end

  test "blocks selected ticket refund line missing total_tax", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_081, :target, :manifest, [781])

    Selector.set_lines!(10_081, [
      %{"id" => 581, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(
      10_081,
      order_payload(10_081,
        status: "completed",
        line_items: [%{"id" => 581}],
        refunds: [%{"id" => 781, "total" => "-10.00"}]
      )
    )

    WooClient.put_refund!(10_081, 781, refund_payload(781, 581, include_tax: false))

    assert {:error, {:financial_primitive_incomplete, %{field: :refund_total_tax}}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )
  end

  test "accepts selected ticket refund line with explicit zero total_tax", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_082, :target, :manifest, [782])

    Selector.set_lines!(10_082, [
      %{"id" => 582, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(
      10_082,
      order_payload(10_082,
        status: "completed",
        line_items: [%{"id" => 582}],
        refunds: [%{"id" => 782, "total" => "-10.00"}]
      )
    )

    WooClient.put_refund!(10_082, 782, refund_payload(782, 582, tax: "0.00"))

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    assert Decimal.equal?(result.currencies["ZAR"].refund_ticket_value, Decimal.new("10.00"))
  end

  test "accepts value-only selected ticket refund with complete money and zero quantity", %{
    source: source,
    event: event,
    run: run
  } do
    create_membership!(run, 10_083, :target, :manifest, [783])

    Selector.set_lines!(10_083, [
      %{"id" => 583, "quantity" => 1, "total" => "20.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(
      10_083,
      order_payload(10_083,
        status: "completed",
        line_items: [%{"id" => 583}],
        refunds: [%{"id" => 783, "total" => "-15.00"}]
      )
    )

    WooClient.put_refund!(
      10_083,
      783,
      refund_payload(783, 583, qty: 0, total: "15.00", tax: "0.00", include_quantity: false)
    )

    assert {:ok, result} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )

    totals = result.currencies["ZAR"]
    assert Decimal.equal?(totals.refund_ticket_quantity, Decimal.new("0"))
    assert Decimal.equal?(totals.refund_ticket_value, Decimal.new("15.00"))
  end

  test "blocks missing refund observation", %{source: source, event: event, run: run} do
    create_membership_without_observation!(run, 10_071, :target)

    Selector.set_lines!(10_071, [
      %{"id" => 571, "quantity" => 1, "total" => "10.00", "total_tax" => "0.00"}
    ])

    WooClient.put_order!(10_071, order_payload(10_071, status: "completed"))

    assert {:error, {:missing_source_fact, %{kind: :refund_observation, source_order_id: 10_071}}} =
             SourceExtractor.extract_for_run(run, event, source,
               woo_client: WooClient,
               line_selector: &Selector.select/3
             )
  end

  defp certified_run!(event) do
    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: @sales_covered_through
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, event.source_system_id)
    |> Ash.Changeset.force_change_attribute(:date_from, @coverage_start)
    |> Ash.create!(domain: Ingestion)
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
    |> Ash.update!(
      %{
        coverage_start: @coverage_start,
        sales_covered_through: @sales_covered_through,
        refunds_covered_through: @refunds_covered_through,
        coverage_evidence: HistoricalCoverageHelpers.certified_evidence()
      },
      action: :record_coverage_certification,
      domain: Ingestion
    )
    |> Ash.update!(%{}, action: :complete, domain: Ingestion)
  end

  defp create_membership!(run, source_order_id, event_match_state, phase, refund_ids) do
    membership =
      Ash.create!(
        HistoricalOrderMembership,
        %{
          sync_run_id: run.id,
          source_order_id: source_order_id,
          manifest_source_created_at: @modified_at,
          manifest_source_modified_at: @modified_at,
          last_source_modified_at: @modified_at,
          event_match_state: event_match_state
        },
        action: :resolve_manifest,
        domain: Ingestion
      )

    membership =
      if phase == :catchup do
        Ash.update!(
          membership,
          %{last_source_modified_at: @modified_at, event_match_state: event_match_state},
          action: :resolve_catchup,
          domain: Ingestion
        )
      else
        membership
      end

    Ash.create!(
      HistoricalRefundObservation,
      %{
        historical_order_membership_id: membership.id,
        reference_count: length(refund_ids),
        observed_at: @observed_at
      },
      action: :resolve_manifest,
      domain: Ingestion
    )

    observation =
      HistoricalRefundObservation
      |> Ash.Query.filter(historical_order_membership_id == ^membership.id)
      |> Ash.read_one!(domain: Ingestion)

    Enum.each(refund_ids, fn refund_id ->
      Ash.create!(
        HistoricalRefundReference,
        %{
          historical_refund_observation_id: observation.id,
          woo_refund_id: refund_id,
          last_observed_at: @observed_at
        },
        action: :observe_present,
        domain: Ingestion
      )
    end)

    membership
  end

  defp create_membership_without_observation!(run, source_order_id, event_match_state) do
    Ash.create!(
      HistoricalOrderMembership,
      %{
        sync_run_id: run.id,
        source_order_id: source_order_id,
        manifest_source_created_at: @modified_at,
        manifest_source_modified_at: @modified_at,
        last_source_modified_at: @modified_at,
        event_match_state: event_match_state
      },
      action: :resolve_manifest,
      domain: Ingestion
    )
  end

  defp set_certified_at!(run, certified_at) do
    EventSales.Repo.query!(
      "UPDATE ingestion_sync_runs SET coverage_certified_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(run.id), certified_at]
    )

    Ash.get!(SyncRun, run.id, domain: Ingestion)
  end

  defp order_payload(order_id, opts) do
    status = Keyword.get(opts, :status, "completed")
    currency = Keyword.get(opts, :currency, "ZAR")
    modified_at = Keyword.get(opts, :modified_at, @modified_at)
    completed_at = Keyword.get(opts, :completed_at, @modified_at)

    refunds =
      case Keyword.fetch(opts, :refunds) do
        {:ok, value} -> value
        :error -> []
      end

    line_items =
      case Keyword.fetch(opts, :line_items) do
        {:ok, value} -> value
        :error -> []
      end

    payload = %{
      "id" => order_id,
      "status" => status,
      "currency" => currency,
      "date_completed_gmt" => if(completed_at, do: woo_datetime(completed_at), else: ""),
      "refunds" => refunds,
      "line_items" => line_items
    }

    if Keyword.has_key?(opts, :modified_at) and opts[:modified_at] == "" do
      Map.put(payload, "date_modified_gmt", "")
    else
      Map.put(payload, "date_modified_gmt", woo_datetime(modified_at))
    end
  end

  defp refund_payload(refund_id, line_item_id, opts \\ []) do
    qty = Keyword.get(opts, :qty, 1)
    total = Keyword.get(opts, :total, "10.00")
    tax = Keyword.get(opts, :tax, "0.00")
    include_total? = Keyword.get(opts, :include_total, true)
    include_tax? = Keyword.get(opts, :include_tax, true)
    include_quantity? = Keyword.get(opts, :include_quantity, true)

    meta_data =
      case Keyword.fetch(opts, :meta_data) do
        {:ok, value} ->
          value

        :error ->
          [%{"key" => "_refunded_item_id", "value" => to_string(line_item_id)}]
      end

    line_item =
      %{
        "id" => refund_id * 10,
        "product_id" => "1",
        "variation_id" => nil,
        "subtotal" => "-#{total}",
        "meta_data" => meta_data
      }
      |> maybe_put_refund_field(include_quantity?, "quantity", "-#{qty}")
      |> maybe_put_refund_field(include_total?, "total", "-#{total}")
      |> maybe_put_refund_field(include_tax?, "total_tax", "-#{tax}")

    %{
      "id" => refund_id,
      "amount" =>
        "-#{Decimal.add(Decimal.new(total), Decimal.new(tax)) |> Decimal.to_string(:normal)}",
      "date_created_gmt" => woo_datetime(~U[2026-08-05 10:00:00.000000Z]),
      "line_items" => [line_item],
      "shipping_lines" => [],
      "fee_lines" => [],
      "tax_lines" => []
    }
  end

  defp maybe_put_refund_field(line_item, true, key, value), do: Map.put(line_item, key, value)
  defp maybe_put_refund_field(line_item, false, _key, _value), do: line_item

  defp woo_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace("Z", "")
  end
end
