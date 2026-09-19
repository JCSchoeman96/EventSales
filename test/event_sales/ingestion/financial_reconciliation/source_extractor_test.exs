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
      order_payload(10_001, status: "completed", refunds: [%{"id" => 701, "total" => "-46.00"}])
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

    %{
      "id" => order_id,
      "status" => status,
      "currency" => currency,
      "date_modified_gmt" => woo_datetime(modified_at),
      "date_completed_gmt" => if(completed_at, do: woo_datetime(completed_at), else: ""),
      "refunds" => refunds
    }
  end

  defp refund_payload(refund_id, line_item_id, opts) do
    qty = Keyword.get(opts, :qty, 1)
    total = Keyword.get(opts, :total, "10.00")
    tax = Keyword.get(opts, :tax, "0.00")

    %{
      "id" => refund_id,
      "amount" =>
        "-#{Decimal.add(Decimal.new(total), Decimal.new(tax)) |> Decimal.to_string(:normal)}",
      "date_created_gmt" => woo_datetime(~U[2026-08-05 10:00:00.000000Z]),
      "line_items" => [
        %{
          "id" => refund_id * 10,
          "product_id" => "1",
          "variation_id" => nil,
          "quantity" => "-#{qty}",
          "subtotal" => "-#{total}",
          "total" => "-#{total}",
          "total_tax" => "-#{tax}",
          "meta_data" => [
            %{"key" => "_refunded_item_id", "value" => to_string(line_item_id)}
          ]
        }
      ],
      "shipping_lines" => [],
      "fee_lines" => [],
      "tax_lines" => []
    }
  end

  defp woo_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace("Z", "")
  end
end
