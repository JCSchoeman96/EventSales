defmodule EventSales.Analytics.PeriodDimensionProjectionQueryPlanTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.PeriodBucketRules
  alias EventSales.Analytics.PeriodProjectionRefresh
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Repo
  alias EventSales.TestSupport.Analytics.EventAggregatorQueryPlanFixture

  @dimension_table "analytics_event_dimension_period_aggregate_snapshots"
  @index_names %{
    ticket_type: "analytics_dim_period_ticket_type_uidx",
    source_product: "analytics_dim_period_source_product_uidx",
    source_variation: "analytics_dim_period_source_variation_uidx"
  }

  test "each dimensional delete uses its selective partial index" do
    fixture = EventAggregatorQueryPlanFixture.seed!(noise_line_count: 800)
    pending_rows = pending_rows_for(fixture)
    seed_dimension_noise!(fixture, 1_200)

    for dimension_kind <- [:ticket_type, :source_product, :source_variation] do
      plan =
        dimension_kind
        |> PeriodProjectionRefresh.dimension_delete_query(pending_rows)
        |> explain_delete_plan()

      dimension_nodes = relation_nodes(plan, @dimension_table)
      index_nodes = flatten_plan(plan)

      assert Enum.any?(index_nodes, fn node ->
               node["Node Type"] in ["Index Scan", "Bitmap Index Scan", "Index Only Scan"] and
                 node["Index Name"] == @index_names[dimension_kind]
             end),
             "expected #{dimension_kind} DELETE to use #{@index_names[dimension_kind]}, got #{inspect(dimension_nodes)}"

      refute Enum.any?(relation_nodes(plan, @dimension_table), &(&1["Node Type"] == "Seq Scan"))
    end
  end

  test "dimension replacement query count stays fixed as target cardinality grows" do
    fixture = EventAggregatorQueryPlanFixture.seed!()
    event_id = fixture.target_event.id
    pending_rows = pending_rows_for(fixture)
    seed_pending_buckets!(pending_rows)

    {first_result, first_queries} = capture_sql(fn -> refresh_event!(event_id) end)
    assert first_result == :ok
    assert dimension_write_counts(first_queries) == %{delete: 3, insert: 1}
    assert population_query_counts(first_queries) == %{sale: 1, refund: 1, facts: 1}
    first_dimension_count = dimension_count(event_id)

    add_distinct_target_sales!(fixture, 20)

    Repo.query!(
      "UPDATE analytics_event_period_aggregate_snapshots SET projection_state = 'refresh_pending' WHERE event_id = $1::text::uuid",
      [event_id]
    )

    {second_result, second_queries} = capture_sql(fn -> refresh_event!(event_id) end)
    assert second_result == :ok
    assert dimension_write_counts(second_queries) == %{delete: 3, insert: 1}
    assert population_query_counts(second_queries) == %{sale: 1, refund: 1, facts: 1}

    assert dimension_count(event_id) > first_dimension_count
  end

  test "empty dimensional rows skip the bulk insert" do
    fixture = EventAggregatorQueryPlanFixture.seed!()
    pending_rows = pending_rows_for(fixture)
    seed_pending_buckets!(pending_rows)

    Repo.query!(
      "UPDATE sales_order_items SET mapping_status = 'pending_mapping_resolution', item_kind = 'unknown' WHERE id = $1::text::uuid",
      [fixture.target_item_id]
    )

    {result, queries} = capture_sql(fn -> refresh_event!(fixture.target_event.id) end)

    assert result == :ok
    assert dimension_write_counts(queries) == %{delete: 3, insert: 0}
  end

  test "an exact replay with no pending rows performs no writes" do
    fixture = EventAggregatorQueryPlanFixture.seed!()
    pending_rows = pending_rows_for(fixture)
    seed_pending_buckets!(pending_rows)

    assert refresh_event!(fixture.target_event.id) == :ok

    {result, queries} = capture_sql(fn -> refresh_event!(fixture.target_event.id) end)

    assert result == :ok
    assert write_queries(queries) == []
  end

  defp pending_rows_for(fixture) do
    instants = [
      DateTime.add(fixture.target_period.start_utc, 4, :hour),
      DateTime.add(fixture.target_period.start_utc, 6, :hour)
    ]

    instants
    |> Enum.flat_map(fn instant ->
      {:ok, buckets} = PeriodBucketRules.for_instant(instant)
      buckets
    end)
    |> Enum.uniq_by(fn bucket ->
      {bucket.bucket_kind, bucket.bucket_start_utc, bucket.bucket_end_utc}
    end)
    |> Enum.map(&Map.merge(&1, %{event_id: fixture.target_event.id, currency: "ZAR"}))
  end

  defp seed_pending_buckets!(pending_rows) do
    Enum.each(pending_rows, fn bucket ->
      Ash.create!(
        EventPeriodAggregateSnapshot,
        Map.merge(bucket, %{
          generation_id: Ecto.UUID.generate(),
          semantic_version: 1,
          coverage_identity: "m5_04e:test_pending",
          projection_state: :refresh_pending,
          refreshed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        }),
        action: :create_snapshot,
        domain: EventSales.Analytics
      )
    end)
  end

  defp seed_dimension_noise!(fixture, count) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    event_id = Ecto.UUID.dump!(fixture.target_event.id)
    ticket_type_id = Ecto.UUID.dump!(fixture.target_ticket.id)
    source_system_id = Ecto.UUID.dump!(fixture.source.id)

    rows =
      for offset <- 1..count,
          {dimension_kind, identity} <- [
            {"ticket_type", %{ticket_type_id: ticket_type_id}},
            {"source_product",
             %{source_system_id: source_system_id, woo_product_id: 10_000 + offset}},
            {"source_variation",
             %{
               source_system_id: source_system_id,
               woo_product_id: 10_000 + offset,
               woo_variation_id: 20_000 + offset
             }}
          ] do
        bucket_start = DateTime.add(~U[2025-01-01 00:00:00Z], offset, :hour)

        Map.merge(identity, %{
          id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          event_id: event_id,
          currency: "ZAR",
          bucket_kind: "utc_hour",
          bucket_start_utc: bucket_start,
          bucket_end_utc: DateTime.add(bucket_start, 1, :hour),
          bucket_timezone: "UTC",
          dimension_kind: dimension_kind,
          gross_ticket_quantity: 1,
          gross_ticket_value: Decimal.new("10.00"),
          refund_ticket_quantity: 0,
          refund_ticket_value: Decimal.new("0"),
          generation_id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          semantic_version: 1,
          coverage_identity: "m5_04e:plan_noise",
          projection_state: "current",
          refreshed_at: timestamp,
          source_watermark_at: timestamp,
          inserted_at: timestamp,
          updated_at: timestamp
        })
      end

    inserted =
      rows
      |> Enum.chunk_every(300)
      |> Enum.reduce(0, fn chunk, total ->
        {chunk_count, _rows} = Repo.insert_all(@dimension_table, chunk)
        total + chunk_count
      end)

    assert inserted == count * 3
    Repo.query!("ANALYZE #{@dimension_table}")
  end

  defp dimension_count(event_id) do
    event_id_binary = Ecto.UUID.dump!(event_id)

    Repo.one!(
      Ecto.Query.from(d in @dimension_table,
        where: d.event_id == ^event_id_binary,
        select: count(d.id)
      )
    )
  end

  defp add_distinct_target_sales!(fixture, count) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    sale_at = DateTime.add(fixture.target_period.start_utc, 4, :hour)
    source_id = Ecto.UUID.dump!(fixture.source.id)
    event_id = Ecto.UUID.dump!(fixture.target_event.id)
    ticket_id = Ecto.UUID.dump!(fixture.target_ticket.id)
    zero = Decimal.new("0")

    orders =
      for offset <- 1..count do
        id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

        {%{
           id: id,
           source_system_id: source_id,
           woo_order_id: 2_000_000 + offset,
           order_number: "period-dimension-added-#{offset}",
           status: "completed",
           currency: "ZAR",
           paid_at: sale_at,
           completed_at: sale_at,
           created_at_source: timestamp,
           updated_at_source: timestamp,
           raw_total: zero,
           raw_discount_total: zero,
           raw_tax_total: zero,
           inserted_at: timestamp,
           updated_at: timestamp
         }, id}
      end

    Repo.insert_all("sales_orders", Enum.map(orders, &elem(&1, 0)))

    items =
      orders
      |> Enum.with_index(1)
      |> Enum.map(fn {{_order, order_id}, offset} ->
        %{
          id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          order_id: order_id,
          event_id: event_id,
          ticket_type_id: ticket_id,
          woo_line_item_id: 50_000 + offset,
          woo_product_id: 30_000 + offset,
          woo_variation_id: 40_000 + offset,
          name: "Additional target ticket",
          quantity: 1,
          line_subtotal: Decimal.new("10.00"),
          line_total: Decimal.new("10.00"),
          line_total_tax: Decimal.new("1.50"),
          discount_total: zero,
          item_kind: "ticket",
          mapping_status: "mapped",
          inserted_at: timestamp,
          updated_at: timestamp
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

  defp dimension_write_counts(queries) do
    deletes =
      Enum.count(queries, fn {sql, _params} ->
        trimmed = String.trim_leading(sql)
        String.starts_with?(trimmed, "DELETE FROM") and String.contains?(sql, @dimension_table)
      end)

    inserts =
      Enum.count(queries, fn {sql, _params} ->
        String.starts_with?(String.trim_leading(sql), "INSERT INTO") and
          String.contains?(sql, @dimension_table)
      end)

    %{delete: deletes, insert: inserts}
  end

  defp population_query_counts(queries) do
    sale =
      Enum.count(queries, fn {sql, _params} ->
        String.contains?(sql, "sales_order_items") and
          String.contains?(sql, "sales_orders") and
          not String.contains?(sql, "sales_refund_lines")
      end)

    refund =
      Enum.count(queries, fn {sql, _params} ->
        String.contains?(sql, "sales_refund_lines") and
          String.contains?(sql, "sales_refunds")
      end)

    facts =
      Enum.count(queries, fn {sql, _params} ->
        String.contains?(sql, "analytics_contribution_facts") and
          String.starts_with?(String.trim_leading(sql), "SELECT")
      end)

    %{sale: sale, refund: refund, facts: facts}
  end

  defp write_queries(queries) do
    Enum.filter(queries, fn {sql, _params} ->
      trimmed = String.trim_leading(sql)

      String.starts_with?(trimmed, "INSERT INTO") or
        String.starts_with?(trimmed, "UPDATE") or
        String.starts_with?(trimmed, "DELETE FROM")
    end)
  end

  defp explain_delete_plan(query) do
    {sql, params} = Repo.to_sql(:delete_all, query)

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
