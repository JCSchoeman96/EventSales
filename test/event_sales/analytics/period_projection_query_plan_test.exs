defmodule EventSales.Analytics.PeriodProjectionQueryPlanTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.PeriodBucketRules
  alias EventSales.Analytics.PeriodProjectionRefresh
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Repo
  alias EventSales.TestSupport.Analytics.EventAggregatorQueryPlanFixture

  @event_first_indexes [
    "sales_order_items_event_id_idx",
    "sales_order_items_event_mapping_status_idx"
  ]

  test "sale and refund source query plans use bounded indexed paths" do
    fixture = EventAggregatorQueryPlanFixture.seed!()
    windows = [period_window(fixture)]

    sale_plan =
      fixture.target_event.id
      |> PeriodProjectionRefresh.sale_population_query(windows)
      |> explain_plan()

    refund_plan =
      fixture.target_event.id
      |> PeriodProjectionRefresh.refund_population_query(windows)
      |> explain_plan()

    sale_items = relation_nodes(sale_plan, "sales_order_items")
    assert Enum.any?(sale_items, &(&1["Index Name"] in @event_first_indexes))
    assert_no_seq_scan!(sale_plan, "sales_orders")

    refund_items = relation_nodes(refund_plan, "sales_order_items")
    assert Enum.any?(refund_items, &(&1["Index Name"] in @event_first_indexes))
    assert Enum.any?(relation_nodes(refund_plan, "sales_refund_lines"), &refund_line_index?/1)
    assert Enum.any?(relation_nodes(refund_plan, "sales_refunds"), &refund_header_index?/1)
    assert_no_seq_scan!(refund_plan, "sales_orders")
  end

  test "source query count stays fixed as affected contribution rows grow" do
    fixture = EventAggregatorQueryPlanFixture.seed!(noise_line_count: 800)
    event_id = fixture.target_event.id
    windows = [period_window(fixture)]
    seed_pending_buckets!(event_id, windows)

    {first_result, first_sql} = capture_sql(fn -> refresh_event!(event_id) end)
    assert first_result == :ok
    assert population_query_counts(first_sql) == %{sale: 1, refund: 1, facts: 1}

    add_target_sales!(fixture, 20)

    Repo.query!(
      "UPDATE analytics_event_period_aggregate_snapshots SET projection_state = 'refresh_pending' WHERE event_id = $1",
      [Ecto.UUID.dump!(event_id)]
    )

    {second_result, second_sql} = capture_sql(fn -> refresh_event!(event_id) end)
    assert second_result == :ok
    assert population_query_counts(second_sql) == %{sale: 1, refund: 1, facts: 1}

    assert length(fact_ids(event_id)) == 22
  end

  defp period_window(fixture) do
    %{
      currency: "ZAR",
      start_utc: fixture.target_period.start_utc,
      end_utc: fixture.target_period.end_utc
    }
  end

  defp seed_pending_buckets!(event_id, [window]) do
    sale_at = DateTime.add(window.start_utc, 4, :hour)
    refund_at = DateTime.add(window.start_utc, 6, :hour)

    [sale_at, refund_at]
    |> Enum.flat_map(fn instant ->
      {:ok, buckets} = PeriodBucketRules.for_instant(instant)
      buckets
    end)
    |> Enum.uniq_by(fn bucket ->
      {bucket.bucket_kind, bucket.bucket_start_utc, bucket.bucket_end_utc}
    end)
    |> Enum.each(fn bucket ->
      Ash.create!(
        EventPeriodAggregateSnapshot,
        Map.merge(bucket, %{
          event_id: event_id,
          currency: window.currency,
          generation_id: Ecto.UUID.generate(),
          semantic_version: 1,
          coverage_identity: "m5_04d:test_pending",
          projection_state: :refresh_pending,
          refreshed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        }),
        action: :create_snapshot,
        domain: EventSales.Analytics
      )
    end)
  end

  defp add_target_sales!(fixture, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    sale_at = DateTime.add(fixture.target_period.start_utc, 4, :hour)
    source_id = Ecto.UUID.dump!(fixture.source.id)
    event_id = Ecto.UUID.dump!(fixture.target_event.id)
    ticket_id = Ecto.UUID.dump!(fixture.target_ticket.id)

    orders =
      for offset <- 1..count do
        order_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

        {%{
           id: order_id,
           source_system_id: source_id,
           woo_order_id: 1_000_000 + offset,
           order_number: "period-plan-added-#{offset}",
           status: "completed",
           currency: "ZAR",
           paid_at: sale_at,
           completed_at: sale_at,
           created_at_source: now,
           updated_at_source: now,
           raw_total: Decimal.new("10.00"),
           raw_discount_total: Decimal.new("0"),
           raw_tax_total: Decimal.new("0"),
           inserted_at: now,
           updated_at: now
         }, order_id}
      end

    Repo.insert_all("sales_orders", Enum.map(orders, &elem(&1, 0)))

    items =
      Enum.map(orders, fn {_order, order_id} ->
        line = System.unique_integer([:positive])

        %{
          id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          order_id: order_id,
          event_id: event_id,
          ticket_type_id: ticket_id,
          woo_line_item_id: line,
          woo_product_id: 71,
          woo_variation_id: 72,
          name: "Additional target ticket",
          quantity: 1,
          line_subtotal: Decimal.new("10.00"),
          line_total: Decimal.new("10.00"),
          line_total_tax: Decimal.new("1.50"),
          discount_total: Decimal.new("0"),
          item_kind: "ticket",
          mapping_status: "mapped",
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all("sales_order_items", items)
  end

  defp refresh_event!(event_id) do
    case Repo.transaction(fn -> PeriodProjectionRefresh.refresh_pending_event(event_id) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> flunk("period refresh failed: #{inspect(reason)}")
    end
  end

  defp population_query_counts(queries) do
    sale =
      Enum.count(queries, fn {sql, _params} ->
        String.contains?(sql, "sales_order_items") and String.contains?(sql, "sales_orders") and
          not String.contains?(sql, "sales_refund_lines")
      end)

    refund =
      Enum.count(queries, fn {sql, _params} ->
        String.contains?(sql, "sales_refund_lines") and String.contains?(sql, "sales_refunds")
      end)

    facts =
      Enum.count(queries, fn {sql, _params} ->
        String.contains?(sql, "analytics_contribution_facts") and
          String.starts_with?(String.trim_leading(sql), "SELECT")
      end)

    %{sale: sale, refund: refund, facts: facts}
  end

  defp fact_ids(event_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT source_contribution_id FROM analytics_contribution_facts WHERE event_id = $1",
        [Ecto.UUID.dump!(event_id)]
      )

    rows
  end

  defp explain_plan(query) do
    {sql, params} = Repo.to_sql(:all, query)

    case Repo.query!("EXPLAIN (FORMAT JSON) #{sql}", params).rows do
      [[json]] when is_binary(json) -> json |> Jason.decode!() |> plan_root()
      [[plan]] when is_list(plan) -> plan_root(plan)
    end
  end

  defp plan_root([%{"Plan" => root} | _]), do: root
  defp plan_root(%{"Plan" => root}), do: root

  defp relation_nodes(plan, relation) do
    flatten_plan(plan)
    |> Enum.filter(&(&1["Relation Name"] == relation))
  end

  defp flatten_plan(%{"Plans" => children} = node) do
    [node | Enum.flat_map(children, &flatten_plan/1)]
  end

  defp flatten_plan(node) when is_map(node), do: [node]

  defp assert_no_seq_scan!(plan, relation) do
    refute Enum.any?(relation_nodes(plan, relation), &(&1["Node Type"] == "Seq Scan"))
  end

  defp refund_line_index?(node) do
    node["Node Type"] in ["Index Scan", "Bitmap Index Scan", "Index Only Scan"] and
      node["Index Name"] == "sales_refund_lines_order_item_id_idx"
  end

  defp refund_header_index?(node) do
    node["Node Type"] in ["Index Scan", "Bitmap Index Scan", "Index Only Scan"] and
      node["Index Name"] in [
        "sales_refunds_order_id_idx",
        "sales_refunds_pkey",
        "sales_refunds_unique_source_order_refund_index"
      ]
  end

  defp capture_sql(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, {test_pid, id} ->
          send(test_pid, {id, metadata.query, metadata.params})
        end,
        {parent, handler_id}
      )

    try do
      result = fun.()
      {result, collect_sql(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_sql(handler_id, acc) do
    receive do
      {^handler_id, sql, params} -> collect_sql(handler_id, [{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
