defmodule EventSales.Analytics.PeriodComparisonReader do
  @moduledoc """
  Projection-only management period comparison reader (M5-04F).

  Composes current and previous operands from durable fixed buckets and bounded
  contribution-edge aggregates inside one coherent database transaction.
  """

  import Ecto.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Accounts.Resources.User
  alias EventSales.Analytics.MetricRules
  alias EventSales.Analytics.PeriodReadPlan
  alias EventSales.Analytics.TimeRules
  alias EventSales.Analytics.TimeRules.ComparisonWindows

  alias EventSales.Analytics.Resources.{
    EventDimensionPeriodAggregateSnapshot,
    EventPeriodAggregateSnapshot
  }

  alias EventSales.Analytics.EventSnapshotRefreshFence
  alias EventSales.Ingestion.AnalyticsReadinessResolver
  alias EventSales.Repo

  @zero Decimal.new("0")
  @supported_requests [:today, :yesterday, {:rolling_days, 7}, {:rolling_days, 30}]
  @dimension_kinds [:ticket_type, :source_product, :source_variation]
  @required_dimension_kinds [:ticket_type, :source_product]
  @comparison_metrics [
    :gross_ticket_quantity,
    :refund_ticket_quantity,
    :net_ticket_quantity,
    :gross_ticket_value,
    :refund_ticket_value,
    :net_ticket_value,
    :average_ticket_value
  ]
  @monetary_metrics [
    :gross_ticket_value,
    :refund_ticket_value,
    :net_ticket_value,
    :average_ticket_value
  ]

  @type period_request ::
          :today | :yesterday | {:rolling_days, 7} | {:rolling_days, 30}

  @doc """
  Compares current and previous management periods for one event and currency.

  Options:

    * `:actor` — required authorized user
    * `:now` — optional deterministic UTC anchor for tests
  """
  @spec compare_event(Ecto.UUID.t() | String.t(), String.t(), period_request(), keyword()) ::
          {:ok, map()}
          | {:error,
             :forbidden
             | :unsupported_comparison_period
             | :invalid_currency
             | :too_many_edge_fragments
             | {:invalid_uuid, :event_id}
             | term()}
  def compare_event(event_id, currency, period_request, opts \\ [])
      when is_binary(event_id) and is_binary(currency) do
    actor = Keyword.get(opts, :actor)

    with {:ok, event_id} <- cast_uuid(event_id, :event_id),
         :ok <- authorize(actor, event_id),
         :ok <- validate_currency(currency),
         :ok <- validate_request(period_request),
         {:ok, readiness} <- AnalyticsReadinessResolver.resolve(event_id),
         {:ok, windows} <- capture_windows(period_request, opts),
         {:ok, plan} <- PeriodReadPlan.build(windows) do
      revenue_visible? = Policies.can_view_revenue?(actor, event_id)

      envelope =
        base_envelope(event_id, currency, period_request, windows, revenue_visible?)

      finalize_comparison(
        readiness,
        event_id,
        currency,
        plan,
        envelope,
        revenue_visible?
      )
    end
  end

  defp finalize_comparison(readiness, event_id, currency, plan, envelope, revenue_visible?) do
    if readiness.analytics_ready? do
      read_coherent_comparison(event_id, currency, plan, envelope, revenue_visible?)
    else
      {:ok, fail_closed_envelope(envelope, readiness.blocking_reason)}
    end
  end

  defp authorize(%User{} = actor, event_id) do
    if Policies.can_access_event_dashboard?(actor, event_id), do: :ok, else: {:error, :forbidden}
  end

  defp authorize(_actor, _event_id), do: {:error, :forbidden}

  defp validate_currency(currency) when is_binary(currency) and byte_size(currency) > 0, do: :ok
  defp validate_currency(_currency), do: {:error, :invalid_currency}

  defp validate_request(request) when request in @supported_requests, do: :ok
  defp validate_request(_request), do: {:error, :unsupported_comparison_period}

  defp capture_windows(period_request, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    timezone = MetricRules.business_timezone()
    TimeRules.comparison_windows(timezone, now, period_request)
  end

  defp base_envelope(
         event_id,
         currency,
         request,
         %ComparisonWindows{} = windows,
         revenue_visible?
       ) do
    %{
      event_id: event_id,
      currency: currency,
      request: request,
      captured_now_utc: windows.captured_now_utc,
      timezone: windows.timezone,
      revenue_visible?: revenue_visible?,
      pii_visibility: :none,
      analytics_ready?: true,
      blocking_reason: nil,
      current: operand_envelope(windows.current),
      comparison: operand_envelope(windows.previous),
      event: %{metric_comparisons: %{}},
      dimensions: %{
        ticket_type: [],
        source_product: [],
        source_variation: []
      }
    }
  end

  defp operand_envelope(%TimeRules.Period{start_utc: start, end_utc: end_utc}) do
    %{start_utc: start, end_utc: end_utc, readiness: :not_ready, metrics: nil}
  end

  defp fail_closed_envelope(envelope, blocking_reason) do
    envelope
    |> Map.put(:analytics_ready?, false)
    |> Map.put(:blocking_reason, blocking_reason)
    |> Map.put(:event, %{metric_comparisons: empty_metric_comparisons()})
    |> Map.put(:current, Map.put(envelope.current, :readiness, :not_ready))
    |> Map.put(:comparison, Map.put(envelope.comparison, :readiness, :not_ready))
  end

  defp empty_metric_comparisons do
    Map.new(@comparison_metrics, fn metric ->
      {metric,
       %{
         current: nil,
         comparison: nil,
         state: :current_missing,
         absolute_delta: nil,
         percentage_delta: nil
       }}
    end)
  end

  defp read_coherent_comparison(event_id, currency, plan, envelope, revenue_visible?) do
    transaction_opts = EventSnapshotRefreshFence.coherent_transaction_opts()

    case Repo.transaction(
           fn -> load_projection_operands_in_transaction(event_id, currency, plan) end,
           transaction_opts
         ) do
      {:ok, payload} ->
        {:ok, build_comparison_result(envelope, payload, revenue_visible?)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_projection_operands_in_transaction(event_id, currency, plan) do
    :ok = EventSnapshotRefreshFence.prepare_coherent_transaction!()

    case load_projection_operands(event_id, currency, plan) do
      {:ok, payload} -> payload
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp load_projection_operands(event_id, currency, plan) do
    fixed_buckets = Enum.flat_map(plan.operands, & &1.fixed_buckets)
    edge_fragments = Enum.flat_map(plan.operands, & &1.edge_fragments)
    coverage_specs = coverage_bucket_specs_for_plan(plan)
    snapshot_specs = required_event_snapshot_specs(fixed_buckets, edge_fragments)

    with {:ok, event_rows} <- fetch_event_snapshot_rows(event_id, currency, snapshot_specs),
         {:ok, event_edges} <-
           aggregate_event_edges(event_id, currency, edge_fragments, event_rows),
         {:ok, dim_coverage_rows} <-
           fetch_dimension_coverage_rows(event_id, currency, coverage_specs),
         {:ok, dim_interior_rows} <-
           fetch_dimension_interior_rows(event_id, currency, fixed_buckets),
         {:ok, dim_edges} <-
           aggregate_dimension_edges(event_id, currency, edge_fragments, event_rows) do
      {:ok,
       %{
         plan: plan,
         event_rows: event_rows,
         event_edges: event_edges,
         dim_coverage_rows: dim_coverage_rows,
         dim_interior_rows: dim_interior_rows,
         dim_edges: dim_edges
       }}
    end
  end

  defp coverage_bucket_specs_for_plan(plan) do
    plan.operands
    |> Enum.flat_map(&coverage_bucket_specs_for_operand/1)
    |> Enum.uniq_by(fn spec ->
      {spec.bucket_kind, spec.bucket_start_utc, spec.bucket_end_utc}
    end)
  end

  defp coverage_bucket_specs_for_operand(operand_plan) do
    envelope_specs =
      Enum.map(operand_plan.edge_fragments, fn fragment ->
        hour_start = fragment.envelope_hour_start_utc

        %{
          bucket_kind: :utc_hour,
          bucket_start_utc: hour_start,
          bucket_end_utc: DateTime.add(hour_start, 1, :hour)
        }
      end)

    (operand_plan.fixed_buckets ++ envelope_specs)
    |> Enum.uniq_by(fn spec ->
      {spec.bucket_kind, spec.bucket_start_utc, spec.bucket_end_utc}
    end)
  end

  defp required_event_snapshot_specs(fixed_buckets, edge_fragments) do
    envelope_specs =
      Enum.map(edge_fragments, fn fragment ->
        hour_start = fragment.envelope_hour_start_utc

        %{
          bucket_kind: :utc_hour,
          bucket_start_utc: hour_start,
          bucket_end_utc: DateTime.add(hour_start, 1, :hour)
        }
      end)

    (fixed_buckets ++ envelope_specs)
    |> Enum.uniq_by(fn spec ->
      {spec.bucket_kind, spec.bucket_start_utc, spec.bucket_end_utc}
    end)
  end

  defp fetch_event_snapshot_rows(_event_id, _currency, []), do: {:ok, []}

  defp fetch_event_snapshot_rows(event_id, currency, snapshot_specs) do
    bucket_filter = bucket_specs_dynamic(snapshot_specs)

    query =
      from(row in EventPeriodAggregateSnapshot,
        where: row.event_id == ^event_id and row.currency == ^currency,
        where: ^bucket_filter
      )

    {:ok, Repo.all(query)}
  end

  defp bucket_specs_dynamic(specs) do
    Enum.reduce(specs, dynamic(false), fn spec, dyn ->
      dynamic(
        [row],
        ^dyn or
          (row.bucket_kind == ^spec.bucket_kind and
             row.bucket_start_utc == ^spec.bucket_start_utc and
             row.bucket_end_utc == ^spec.bucket_end_utc)
      )
    end)
  end

  defp current_compatible_row?(row) do
    row.projection_state == :current and row.semantic_version >= 1 and
      is_binary(row.coverage_identity) and byte_size(row.coverage_identity) > 0
  end

  defp aggregate_event_edges(_event_id, _currency, [], _event_rows), do: {:ok, %{}}

  defp aggregate_event_edges(event_id, currency, edge_fragments, event_rows) do
    {coverage_by_hour, semantic_by_hour} = envelope_hour_metadata_maps(event_rows)

    if envelope_metadata_complete?(edge_fragments, coverage_by_hour, semantic_by_hour) do
      aggregate_event_edges_with_metadata(
        event_id,
        currency,
        edge_fragments,
        coverage_by_hour,
        semantic_by_hour
      )
    else
      {:ok, zero_event_edges(edge_fragments)}
    end
  end

  defp aggregate_event_edges_with_metadata(
         event_id,
         currency,
         edge_fragments,
         coverage_by_hour,
         semantic_by_hour
       ) do
    with {:ok, rows} <-
           query_edge_aggregates(
             event_id,
             currency,
             edge_fragments,
             coverage_by_hour,
             semantic_by_hour,
             nil
           ),
         indexed = index_event_edge_rows(rows, edge_fragments),
         {:ok, merged} <-
           apply_edge_metadata_mismatch_counts(
             indexed,
             event_id,
             currency,
             edge_fragments,
             coverage_by_hour,
             semantic_by_hour
           ) do
      {:ok, finalize_event_edges(merged, edge_fragments)}
    end
  end

  defp envelope_metadata_complete?(edge_fragments, coverage_by_hour, semantic_by_hour) do
    Enum.all?(edge_fragments, fn fragment ->
      hour = fragment.envelope_hour_start_utc
      Map.has_key?(coverage_by_hour, hour) and Map.has_key?(semantic_by_hour, hour)
    end)
  end

  defp zero_event_edges(edge_fragments) do
    Map.new(edge_fragments, fn fragment ->
      {edge_map_key(fragment), %{primitives: zero_primitives(), metadata_mismatch_count: 0}}
    end)
  end

  defp apply_edge_metadata_mismatch_counts(
         indexed,
         event_id,
         currency,
         edge_fragments,
         coverage_by_hour,
         semantic_by_hour
       ) do
    case query_edge_metadata_mismatch_counts(
           event_id,
           currency,
           edge_fragments,
           coverage_by_hour,
           semantic_by_hour
         ) do
      {:ok, mismatch_rows} ->
        {:ok, merge_edge_metadata_mismatch_counts(indexed, edge_fragments, mismatch_rows)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query_edge_metadata_mismatch_counts(
         event_id,
         currency,
         edge_fragments,
         coverage_by_hour,
         semantic_by_hour
       ) do
    operands = Enum.map(edge_fragments, fn f -> Atom.to_string(f.operand) end)
    edge_indices = Enum.map(Enum.with_index(edge_fragments), fn {_, idx} -> idx end)
    edge_starts = Enum.map(edge_fragments, & &1.edge_start_utc)
    edge_ends = Enum.map(edge_fragments, & &1.edge_end_utc)

    coverages =
      Enum.map(edge_fragments, fn fragment ->
        Map.fetch!(coverage_by_hour, fragment.envelope_hour_start_utc)
      end)

    semantics =
      Enum.map(edge_fragments, fn fragment ->
        Map.fetch!(semantic_by_hour, fragment.envelope_hour_start_utc)
      end)

    sql = """
    SELECT
      r.operand,
      r.edge_start_utc,
      r.edge_end_utc,
      COUNT(f.id) FILTER (
        WHERE f.coverage_identity IS DISTINCT FROM r.coverage_identity
           OR f.semantic_version IS DISTINCT FROM r.semantic_version
      )::bigint AS metadata_mismatch_count
    FROM unnest($1::text[], $2::int[], $3::timestamptz[], $4::timestamptz[], $5::text[], $6::int[])
      AS r(operand, edge_index, edge_start_utc, edge_end_utc, coverage_identity, semantic_version)
    LEFT JOIN analytics_contribution_facts f
      ON f.event_id = $7::uuid
     AND f.currency = $8
     AND f.effective_at >= r.edge_start_utc
     AND f.effective_at < r.edge_end_utc
    GROUP BY r.operand, r.edge_start_utc, r.edge_end_utc
    """

    params = [
      operands,
      edge_indices,
      edge_starts,
      edge_ends,
      coverages,
      semantics,
      Ecto.UUID.dump!(event_id),
      currency
    ]

    case Repo.query(sql, params) do
      {:ok, result} -> {:ok, decode_edge_rows(result, nil)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_edge_metadata_mismatch_counts(indexed, edge_fragments, mismatch_rows) do
    Enum.reduce(mismatch_rows, indexed, fn row, acc ->
      fragment = find_edge_fragment!(edge_fragments, row)
      key = {fragment.operand, fragment.edge_start_utc, fragment.edge_end_utc}

      Map.update!(acc, key, fn entry ->
        Map.put(entry, :metadata_mismatch_count, edge_metadata_mismatch_count(row))
      end)
    end)
  end

  defp fetch_dimension_coverage_rows(_event_id, _currency, []), do: {:ok, []}

  defp fetch_dimension_coverage_rows(event_id, currency, coverage_specs) do
    bucket_filter = bucket_specs_dynamic(coverage_specs)

    query =
      from(row in EventDimensionPeriodAggregateSnapshot,
        where: row.event_id == ^event_id and row.currency == ^currency,
        where: ^bucket_filter
      )

    {:ok, Repo.all(query)}
  end

  defp fetch_dimension_interior_rows(_event_id, _currency, []),
    do: {:ok, %{ticket_type: [], source_product: [], source_variation: []}}

  defp fetch_dimension_interior_rows(event_id, currency, fixed_buckets) do
    {:ok,
     %{
       ticket_type: fetch_dimension_family_rows(:ticket_type, event_id, currency, fixed_buckets),
       source_product:
         fetch_dimension_family_rows(:source_product, event_id, currency, fixed_buckets),
       source_variation:
         fetch_dimension_family_rows(:source_variation, event_id, currency, fixed_buckets)
     }}
  end

  defp fetch_dimension_family_rows(_kind, _event_id, _currency, []), do: []

  defp fetch_dimension_family_rows(kind, event_id, currency, fixed_buckets) do
    bucket_filter = bucket_specs_dynamic(fixed_buckets)

    query =
      from(row in EventDimensionPeriodAggregateSnapshot,
        where:
          row.event_id == ^event_id and row.currency == ^currency and
            row.dimension_kind == ^kind and row.projection_state == ^:current,
        where: ^bucket_filter
      )

    Repo.all(query)
  end

  defp aggregate_dimension_edges(_event_id, _currency, [], _event_rows),
    do: {:ok, %{ticket_type: %{}, source_product: %{}, source_variation: %{}}}

  defp aggregate_dimension_edges(event_id, currency, edge_fragments, event_rows) do
    {coverage_by_hour, semantic_by_hour} = envelope_hour_metadata_maps(event_rows)

    unless envelope_metadata_complete?(edge_fragments, coverage_by_hour, semantic_by_hour) do
      {:ok, %{ticket_type: %{}, source_product: %{}, source_variation: %{}}}
    else
      aggregate_dimension_edges_with_metadata(
        event_id,
        currency,
        edge_fragments,
        coverage_by_hour,
        semantic_by_hour
      )
    end
  end

  defp aggregate_dimension_edges_with_metadata(
         event_id,
         currency,
         edge_fragments,
         coverage_by_hour,
         semantic_by_hour
       ) do
    with {:ok, ticket_type} <-
           dimension_edge_totals(
             :ticket_type,
             event_id,
             currency,
             edge_fragments,
             coverage_by_hour,
             semantic_by_hour
           ),
         {:ok, source_product} <-
           dimension_edge_totals(
             :source_product,
             event_id,
             currency,
             edge_fragments,
             coverage_by_hour,
             semantic_by_hour
           ),
         {:ok, source_variation} <-
           dimension_edge_totals(
             :source_variation,
             event_id,
             currency,
             edge_fragments,
             coverage_by_hour,
             semantic_by_hour
           ) do
      {:ok,
       %{
         ticket_type: ticket_type,
         source_product: source_product,
         source_variation: source_variation
       }}
    end
  end

  defp dimension_edge_totals(
         kind,
         event_id,
         currency,
         edge_fragments,
         coverage_by_hour,
         semantic_by_hour
       ) do
    case query_edge_aggregates(
           event_id,
           currency,
           edge_fragments,
           coverage_by_hour,
           semantic_by_hour,
           kind
         ) do
      {:ok, rows} -> {:ok, group_dimension_edge_rows(kind, rows)}
      other -> other
    end
  end

  defp group_dimension_edge_rows(kind, rows) do
    rows
    |> Enum.reject(&invalid_dimension_edge_row?(kind, &1))
    |> Enum.group_by(fn row -> {operand_atom(row.operand), identity_from_row(kind, row)} end)
    |> Map.new(fn {key, group} -> {key, sum_edge_group_rows(group)} end)
  end

  defp invalid_dimension_edge_row?(:ticket_type, row), do: is_nil(row.ticket_type_id)
  defp invalid_dimension_edge_row?(:source_product, row), do: is_nil(row.source_system_id)
  defp invalid_dimension_edge_row?(:source_variation, row), do: is_nil(row.woo_variation_id)

  defp query_edge_aggregates(
         event_id,
         currency,
         edge_fragments,
         coverage_by_hour,
         semantic_by_hour,
         kind
       ) do
    operands = Enum.map(edge_fragments, fn f -> Atom.to_string(f.operand) end)
    edge_indices = Enum.map(Enum.with_index(edge_fragments), fn {_, idx} -> idx end)

    edge_starts = Enum.map(edge_fragments, & &1.edge_start_utc)
    edge_ends = Enum.map(edge_fragments, & &1.edge_end_utc)

    coverages =
      Enum.map(edge_fragments, fn fragment ->
        Map.fetch!(coverage_by_hour, fragment.envelope_hour_start_utc)
      end)

    semantics =
      Enum.map(edge_fragments, fn fragment ->
        Map.fetch!(semantic_by_hour, fragment.envelope_hour_start_utc)
      end)

    {select_sql, group_sql} = edge_select_and_group(kind)

    sql = """
    SELECT
      r.operand,
      r.edge_start_utc,
      r.edge_end_utc,
      #{select_sql}
      COALESCE(SUM(
        CASE
          WHEN f.id IS NOT NULL
           AND f.coverage_identity = r.coverage_identity
           AND f.semantic_version = r.semantic_version
          THEN f.gross_ticket_quantity
          ELSE 0
        END
      ), 0)::bigint AS gross_ticket_quantity,
      COALESCE(SUM(
        CASE
          WHEN f.id IS NOT NULL
           AND f.coverage_identity = r.coverage_identity
           AND f.semantic_version = r.semantic_version
          THEN f.gross_ticket_value
          ELSE 0
        END
      ), 0)::numeric AS gross_ticket_value,
      COALESCE(SUM(
        CASE
          WHEN f.id IS NOT NULL
           AND f.coverage_identity = r.coverage_identity
           AND f.semantic_version = r.semantic_version
          THEN f.refund_ticket_quantity
          ELSE 0
        END
      ), 0)::bigint AS refund_ticket_quantity,
      COALESCE(SUM(
        CASE
          WHEN f.id IS NOT NULL
           AND f.coverage_identity = r.coverage_identity
           AND f.semantic_version = r.semantic_version
          THEN f.refund_ticket_value
          ELSE 0
        END
      ), 0)::numeric AS refund_ticket_value,
      COUNT(*) FILTER (
        WHERE f.id IS NOT NULL
          AND (
            f.coverage_identity IS DISTINCT FROM r.coverage_identity
            OR f.semantic_version IS DISTINCT FROM r.semantic_version
          )
      )::bigint AS metadata_mismatch_count
    FROM unnest($1::text[], $2::int[], $3::timestamptz[], $4::timestamptz[], $5::text[], $6::int[])
      AS r(operand, edge_index, edge_start_utc, edge_end_utc, coverage_identity, semantic_version)
    LEFT JOIN analytics_contribution_facts f
      ON f.event_id = $7::uuid
     AND f.currency = $8
     AND f.effective_at >= r.edge_start_utc
     AND f.effective_at < r.edge_end_utc
    GROUP BY r.operand, r.edge_start_utc, r.edge_end_utc#{group_sql}
    """

    params = [
      operands,
      edge_indices,
      edge_starts,
      edge_ends,
      coverages,
      semantics,
      Ecto.UUID.dump!(event_id),
      currency
    ]

    case Repo.query(sql, params) do
      {:ok, result} -> {:ok, decode_edge_rows(result, kind)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp edge_select_and_group(nil), do: {"", ""}

  defp edge_select_and_group(:ticket_type),
    do: {"f.ticket_type_id AS ticket_type_id,", ", f.ticket_type_id"}

  defp edge_select_and_group(:source_product),
    do:
      {"f.source_system_id AS source_system_id, f.woo_product_id AS woo_product_id,",
       ", f.source_system_id, f.woo_product_id"}

  defp edge_select_and_group(:source_variation),
    do:
      {"f.source_system_id AS source_system_id, f.woo_product_id AS woo_product_id, f.woo_variation_id AS woo_variation_id,",
       ", f.source_system_id, f.woo_product_id, f.woo_variation_id"}

  defp row_value(row, key) when is_binary(key) do
    Map.get(row, key) || Map.get(row, String.to_atom(key))
  end

  defp envelope_hour_metadata_maps(event_rows) do
    hour_rows = Enum.filter(event_rows, &(&1.bucket_kind == :utc_hour))

    {
      Map.new(hour_rows, &{&1.bucket_start_utc, &1.coverage_identity}),
      Map.new(hour_rows, &{&1.bucket_start_utc, &1.semantic_version})
    }
  end

  defp edge_metadata_mismatch_count(row) do
    count =
      Map.get(row, :metadata_mismatch_count) || row_value(row, "metadata_mismatch_count") || 0

    case count do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      %Decimal{} = d -> Decimal.to_integer(d)
      n when is_binary(n) -> String.to_integer(n)
      _ -> 0
    end
  end

  defp decode_edge_rows(%{columns: columns, rows: rows}, kind) do
    rows
    |> Enum.map(fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new()
      |> normalize_edge_row(kind)
    end)
    |> Enum.reject(fn row -> is_nil(row.operand) or is_nil(row.edge_start_utc) end)
  end

  defp normalize_edge_row(row, kind) do
    base = %{
      operand: row_value(row, "operand"),
      edge_start_utc: row_value(row, "edge_start_utc"),
      edge_end_utc: row_value(row, "edge_end_utc"),
      gross_ticket_quantity: row_value(row, "gross_ticket_quantity") || 0,
      gross_ticket_value: decimalize(row_value(row, "gross_ticket_value")),
      refund_ticket_quantity: row_value(row, "refund_ticket_quantity") || 0,
      refund_ticket_value: decimalize(row_value(row, "refund_ticket_value")),
      metadata_mismatch_count: row_value(row, "metadata_mismatch_count") || 0
    }

    case kind do
      nil ->
        base

      :ticket_type ->
        Map.put(base, :ticket_type_id, uuid_dump!(row["ticket_type_id"]))

      :source_product ->
        base
        |> Map.put(:source_system_id, uuid_dump!(row["source_system_id"]))
        |> Map.put(:woo_product_id, row["woo_product_id"])

      :source_variation ->
        base
        |> Map.put(:source_system_id, uuid_dump!(row["source_system_id"]))
        |> Map.put(:woo_product_id, row["woo_product_id"])
        |> Map.put(:woo_variation_id, row["woo_variation_id"])
    end
  end

  defp index_event_edge_rows(rows, edge_fragments) do
    indexed =
      rows
      |> Enum.reject(&is_nil/1)
      |> Map.new(fn row ->
        fragment = find_edge_fragment!(edge_fragments, row)
        key = {fragment.operand, fragment.edge_start_utc, fragment.edge_end_utc}

        {key,
         %{
           primitives: edge_primitive_map(row),
           metadata_mismatch_count: edge_metadata_mismatch_count(row)
         }}
      end)

    Enum.reduce(edge_fragments, indexed, fn fragment, acc ->
      key = {fragment.operand, fragment.edge_start_utc, fragment.edge_end_utc}

      Map.update(acc, key, %{primitives: zero_primitives(), metadata_mismatch_count: 0}, fn
        existing -> existing
      end)
    end)
  end

  defp find_edge_fragment!(fragments, row) do
    Enum.find(fragments, fn fragment ->
      Atom.to_string(fragment.operand) == row.operand and
        datetime_equal?(fragment.edge_start_utc, row.edge_start_utc) and
        datetime_equal?(fragment.edge_end_utc, row.edge_end_utc)
    end) || raise "missing edge fragment for #{inspect(row)}"
  end

  defp datetime_equal?(left, right) do
    DateTime.compare(to_datetime!(left), to_datetime!(right)) == :eq
  end

  defp to_datetime!(value) do
    case Ecto.Type.cast(:utc_datetime_usec, value) do
      {:ok, %DateTime{} = dt} -> dt
      _ -> raise ArgumentError, "unsupported datetime: #{inspect(value)}"
    end
  end

  defp assess_operand_readiness(operand_plan, payload) do
    if operand_projection_ready?(operand_plan, payload), do: :ready, else: :not_ready
  end

  defp operand_projection_ready?(operand_plan, payload) do
    event_index = index_event_rows(payload.event_rows)

    fixed_ready? =
      Enum.all?(operand_plan.fixed_buckets, fn bucket ->
        bucket_ready?(Map.get(event_index, bucket_key(bucket)))
      end)

    envelope_ready? =
      Enum.all?(operand_plan.edge_fragments, fn fragment ->
        hour_start = fragment.envelope_hour_start_utc

        bucket_ready?(
          Map.get(event_index, {:utc_hour, hour_start, DateTime.add(hour_start, 1, :hour)})
        )
      end)

    metadata_ready? = operand_metadata_coherent?(operand_plan, payload)
    dimension_ready? = operand_dimension_coverage_ready?(operand_plan, payload)
    edge_metadata_ready? = operand_edge_metadata_ready?(operand_plan, payload)

    fixed_ready? and envelope_ready? and metadata_ready? and dimension_ready? and
      edge_metadata_ready?
  end

  defp bucket_ready?(nil), do: false
  defp bucket_ready?(row), do: current_compatible_row?(row)

  defp operand_metadata_coherent?(operand_plan, payload) do
    rows = operand_event_rows(operand_plan, payload)

    if rows == [] do
      false
    else
      semantics = Enum.map(rows, & &1.semantic_version) |> Enum.uniq()
      coverages = Enum.map(rows, & &1.coverage_identity) |> Enum.uniq()

      length(semantics) == 1 and length(coverages) == 1 and
        Enum.all?(rows, &current_compatible_row?/1)
    end
  end

  defp operand_event_rows(operand_plan, payload) do
    indexed = index_event_rows(payload.event_rows)

    fixed_rows =
      Enum.map(operand_plan.fixed_buckets, fn bucket ->
        Map.get(indexed, bucket_key(bucket))
      end)

    envelope_rows =
      Enum.map(operand_plan.edge_fragments, fn fragment ->
        hour_start = fragment.envelope_hour_start_utc
        Map.get(indexed, {:utc_hour, hour_start, DateTime.add(hour_start, 1, :hour)})
      end)

    (fixed_rows ++ envelope_rows)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp operand_dimension_coverage_ready?(operand_plan, payload) do
    event_index = index_event_rows(payload.event_rows)

    dim_by_bucket =
      Enum.group_by(payload.dim_coverage_rows, fn row ->
        {row.bucket_kind, row.bucket_start_utc, row.bucket_end_utc}
      end)

    Enum.all?(coverage_bucket_specs_for_operand(operand_plan), fn spec ->
      key = {spec.bucket_kind, spec.bucket_start_utc, spec.bucket_end_utc}
      event_row = Map.get(event_index, key)
      dims = Map.get(dim_by_bucket, key, [])
      bucket_dimension_coverage_ok?(event_row, dims)
    end)
  end

  defp bucket_dimension_coverage_ok?(nil, _dims), do: false

  defp bucket_dimension_coverage_ok?(event_row, dims) do
    event_zero? = event_bucket_zero?(event_row)

    cond do
      event_zero? and dims == [] -> true
      event_zero? and dims != [] -> false
      true -> dimension_coverage_valid?(dims, event_row)
    end
  end

  defp dimension_coverage_valid?(dims, event_row) do
    case validate_required_families!(dims, event_row) do
      :ok ->
        case validate_atomic_generation!(dims, event_row) do
          :ok -> reconcile_family_totals!(dims, event_row) == :ok
          {:error, _} -> false
        end

      {:error, _} ->
        false
    end
  end

  defp operand_edge_metadata_ready?(operand_plan, payload) do
    Enum.all?(operand_plan.edge_fragments, fn fragment ->
      case find_event_edge_payload(payload.event_edges, fragment) do
        %{metadata_mismatch_count: count} when count == 0 -> true
        %{metadata_mismatch_count: _count} -> false
        _ -> false
      end
    end)
  end

  defp finalize_event_edges(indexed, edge_fragments) do
    Map.new(edge_fragments, fn fragment ->
      key = edge_map_key(fragment)

      entry =
        find_event_edge_payload(indexed, fragment) ||
          %{primitives: zero_primitives(), metadata_mismatch_count: 0}

      {key, entry}
    end)
  end

  defp find_event_edge_payload(edges, fragment) when is_map(edges) do
    Enum.find_value(edges, fn {key, entry} ->
      if edge_map_key_matches?(key, fragment), do: entry
    end)
  end

  defp edge_map_key(fragment) do
    {fragment.operand, fragment.edge_start_utc, fragment.edge_end_utc}
  end

  defp edge_map_key_matches?({operand, edge_start, edge_end}, fragment) do
    operand == fragment.operand and datetime_equal?(edge_start, fragment.edge_start_utc) and
      datetime_equal?(edge_end, fragment.edge_end_utc)
  end

  defp operand_scope_metadata(operand_plan, payload) do
    rows = operand_event_rows(operand_plan, payload)
    row = hd(rows)

    %{
      semantic_version: row.semantic_version,
      coverage_identity: row.coverage_identity
    }
  end

  defp event_bucket_zero?(row) do
    row.gross_ticket_quantity == 0 and row.refund_ticket_quantity == 0 and
      value_zero?(row.gross_ticket_value) and value_zero?(row.refund_ticket_value)
  end

  defp value_zero?(nil), do: true
  defp value_zero?(%Decimal{} = v), do: Decimal.equal?(v, @zero)

  defp validate_required_families!(dims, event_row) do
    if event_bucket_zero?(event_row) do
      :ok
    else
      kinds = MapSet.new(dims, & &1.dimension_kind)

      if Enum.all?(@required_dimension_kinds, &MapSet.member?(kinds, &1)) do
        :ok
      else
        {:error, :projection_not_ready}
      end
    end
  end

  defp validate_atomic_generation!(dims, event_row) do
    if dims == [] do
      :ok
    else
      compatible? =
        Enum.all?(dims, fn dim ->
          dim.projection_state == :current and dim.generation_id == event_row.generation_id and
            dim.semantic_version == event_row.semantic_version and
            dim.coverage_identity == event_row.coverage_identity
        end)

      if compatible?, do: :ok, else: {:error, :projection_not_ready}
    end
  end

  defp reconcile_family_totals!(dims, event_row) do
    if event_bucket_zero?(event_row) do
      :ok
    else
      case reconcile_family!(:ticket_type, dims, event_row) do
        :ok -> reconcile_family!(:source_product, dims, event_row)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp reconcile_family!(kind, dims, event_row) do
    family_rows = Enum.filter(dims, &(&1.dimension_kind == kind))

    gross_q = Enum.sum(Enum.map(family_rows, & &1.gross_ticket_quantity))
    refund_q = Enum.sum(Enum.map(family_rows, & &1.refund_ticket_quantity))
    gross_v = sum_decimal(Enum.map(family_rows, & &1.gross_ticket_value))
    refund_v = sum_decimal(Enum.map(family_rows, & &1.refund_ticket_value))

    if gross_q == event_row.gross_ticket_quantity and refund_q == event_row.refund_ticket_quantity and
         decimal_equal?(gross_v, event_row.gross_ticket_value) and
         decimal_equal?(refund_v, event_row.refund_ticket_value) do
      :ok
    else
      {:error, :projection_not_ready}
    end
  end

  defp build_comparison_result(envelope, payload, revenue_visible?) do
    [current_plan, comparison_plan] = payload.plan.operands

    current_readiness = assess_operand_readiness(current_plan, payload)
    comparison_readiness = assess_operand_readiness(comparison_plan, payload)

    current_operand = compose_operand(current_plan, payload, current_readiness)
    comparison_operand = compose_operand(comparison_plan, payload, comparison_readiness)

    comparable? =
      current_readiness == :ready and comparison_readiness == :ready and
        MetricRules.projections_comparable?(
          projection_scope(envelope, current_operand),
          projection_scope(envelope, comparison_operand)
        )

    event_comparisons =
      build_metric_comparisons(
        current_operand,
        comparison_operand,
        current_readiness,
        comparison_readiness,
        comparable?,
        :event
      )

    dimensions =
      build_dimension_comparisons(
        payload,
        current_readiness,
        comparison_readiness,
        comparable?
      )

    envelope
    |> Map.put(:current, operand_output(envelope.current, current_operand, current_readiness))
    |> Map.put(
      :comparison,
      operand_output(envelope.comparison, comparison_operand, comparison_readiness)
    )
    |> Map.put(:event, %{metric_comparisons: event_comparisons})
    |> Map.put(:dimensions, dimensions)
    |> redact_revenue!(revenue_visible?)
  end

  defp compose_operand(_operand_plan, _payload, :not_ready) do
    %{scope: nil, primitives: nil, metrics: nil}
  end

  defp compose_operand(operand_plan, payload, :ready) do
    indexed_rows = index_event_rows(payload.event_rows)

    fixed_rows =
      Enum.map(operand_plan.fixed_buckets, fn bucket ->
        Map.fetch!(indexed_rows, bucket_key(bucket))
      end)

    primitives = sum_event_rows(fixed_rows)

    edge_primitives =
      sum_edge_primitives(operand_plan.edge_fragments, payload.event_edges)

    merged = merge_primitives(primitives, edge_primitives)

    metrics =
      case MetricRules.derive_financial_metrics(merged) do
        {:ok, metrics} -> metrics
        {:error, _} -> nil
      end

    %{
      scope: operand_scope_metadata(operand_plan, payload),
      primitives: merged,
      metrics: metrics
    }
  end

  defp projection_scope(envelope, %{scope: nil}) do
    %{
      currency: envelope.currency,
      grain: :event,
      period_scope: period_scope(envelope.request),
      semantic_version: 0,
      coverage_identity: ""
    }
  end

  defp projection_scope(envelope, %{scope: scope}) do
    %{
      currency: envelope.currency,
      grain: :event,
      period_scope: period_scope(envelope.request),
      semantic_version: scope.semantic_version,
      coverage_identity: scope.coverage_identity
    }
  end

  defp period_scope(:today), do: {:today_elapsed, 1}
  defp period_scope(:yesterday), do: {:yesterday, 1}
  defp period_scope({:rolling_days, 7}), do: {{:rolling_days, 7}, 1}
  defp period_scope({:rolling_days, 30}), do: {{:rolling_days, 30}, 1}

  defp operand_output(shell, operand, readiness) do
    metrics =
      if readiness == :ready do
        operand.metrics
      else
        nil
      end

    shell
    |> Map.put(:readiness, readiness)
    |> Map.put(:metrics, metrics)
  end

  defp build_metric_comparisons(
         current,
         comparison,
         current_readiness,
         comparison_readiness,
         comparable?,
         _grain
       ) do
    comparison_zero? = comparison_grain_zero_activity?(comparison)

    Map.new(@comparison_metrics, fn metric ->
      {metric,
       metric_comparison(
         metric,
         current,
         comparison,
         current_readiness,
         comparison_readiness,
         comparable?,
         comparison_zero?
       )}
    end)
  end

  defp metric_comparison(
         metric,
         current,
         comparison,
         current_readiness,
         comparison_readiness,
         comparable?,
         comparison_zero?
       ) do
    current_metric = metric_value(current[:metrics] || current.metrics, metric)
    comparison_metric = metric_value(comparison[:metrics] || comparison.metrics, metric)

    state =
      MetricRules.classify_comparison_state(%{
        current_readiness: current_readiness,
        comparison_readiness: comparison_readiness,
        comparable: comparable?,
        comparison_grain_zero_activity: comparison_zero?,
        current_metric: current_metric || @zero,
        comparison_metric: comparison_metric || @zero
      })

    {current_metric, comparison_metric, state} =
      atv_safe_metrics(metric, current_metric, comparison_metric, state)

    deltas =
      if is_nil(current_metric) or is_nil(comparison_metric) do
        %{absolute_delta: nil, percentage_delta: nil}
      else
        MetricRules.derive_comparison_deltas(state, current_metric, comparison_metric)
      end

    %{
      current: current_metric,
      comparison: comparison_metric,
      state: state,
      absolute_delta: deltas.absolute_delta,
      percentage_delta: deltas.percentage_delta
    }
  end

  defp atv_safe_metrics(:average_ticket_value, current, comparison, state) do
    if is_nil(current) or is_nil(comparison) do
      preserved_state =
        if state in [:current_missing, :comparison_missing, :not_comparable], do: state, else: nil

      {current, comparison, preserved_state}
    else
      {current, comparison, state}
    end
  end

  defp atv_safe_metrics(_metric, current, comparison, state), do: {current, comparison, state}

  defp metric_value(nil, _metric), do: nil
  defp metric_value(metrics, metric) when is_map(metrics), do: Map.get(metrics, metric)

  defp comparison_grain_zero_activity?(%{primitives: primitives}) when is_map(primitives) do
    Enum.all?(
      [
        :gross_ticket_quantity,
        :refund_ticket_quantity,
        :gross_ticket_value,
        :refund_ticket_value
      ],
      fn key ->
        case Map.fetch!(primitives, key) do
          %Decimal{} = d -> Decimal.equal?(d, @zero)
          n when is_integer(n) -> n == 0
        end
      end
    )
  end

  defp comparison_grain_zero_activity?(%{metrics: nil}), do: true
  defp comparison_grain_zero_activity?(_), do: false

  defp build_dimension_comparisons(payload, current_readiness, comparison_readiness, comparable?) do
    [current_plan, comparison_plan] = payload.plan.operands

    Map.new(@dimension_kinds, fn kind ->
      rows =
        build_dimension_rows(
          kind,
          payload,
          current_plan,
          comparison_plan,
          current_readiness,
          comparison_readiness,
          comparable?
        )

      {kind, rows}
    end)
  end

  defp build_dimension_rows(
         kind,
         payload,
         current_plan,
         comparison_plan,
         current_readiness,
         comparison_readiness,
         comparable?
       ) do
    identities =
      MapSet.union(
        grain_identities_for_operand(kind, current_plan, payload),
        grain_identities_for_operand(kind, comparison_plan, payload)
      )
      |> Enum.reject(&invalid_identity?(kind, &1))
      |> MapSet.new()

    Enum.map(identities, fn identity ->
      current =
        dimension_operand_metrics(kind, identity, current_plan, payload, current_readiness)

      comparison =
        dimension_operand_metrics(kind, identity, comparison_plan, payload, comparison_readiness)

      current_r = if current_readiness == :ready, do: :ready, else: :not_ready
      comparison_r = if comparison_readiness == :ready, do: :ready, else: :not_ready

      zero? =
        comparison_r == :ready and
          comparison_grain_zero_activity?(%{primitives: comparison.primitives})

      comparisons =
        build_metric_comparisons(
          %{metrics: current && current.metrics},
          %{metrics: comparison && comparison.metrics},
          current_r,
          comparison_r,
          comparable?,
          zero?
        )

      %{identity: identity, metric_comparisons: comparisons}
    end)
    |> Enum.sort_by(&identity_sort_key/1)
  end

  defp identity_sort_key(%{identity: {:ticket_type, id}}), do: {0, id}
  defp identity_sort_key(%{identity: {:source_product, sid, pid}}), do: {1, sid, pid}
  defp identity_sort_key(%{identity: {:source_variation, sid, pid, vid}}), do: {2, sid, pid, vid}

  defp grain_identities_for_operand(kind, operand_plan, payload) do
    bucket_keys = operand_bucket_keys(operand_plan)

    interior =
      payload.dim_interior_rows[kind]
      |> Enum.filter(fn row ->
        MapSet.member?(bucket_keys, bucket_key(row))
      end)
      |> Enum.map(&identity_from_dimension_row(kind, &1))

    edges =
      payload.dim_edges[kind]
      |> Map.keys()
      |> Enum.filter(fn {operand, _identity} -> operand == operand_plan.operand end)
      |> Enum.map(fn {_operand, identity} -> identity end)

    MapSet.new(interior ++ edges)
  end

  defp dimension_operand_metrics(_kind, _identity, _operand_plan, _payload, :not_ready), do: nil

  defp dimension_operand_metrics(kind, identity, operand_plan, payload, :ready) do
    bucket_keys = operand_bucket_keys(operand_plan)

    interior_rows =
      payload.dim_interior_rows[kind]
      |> Enum.filter(fn row ->
        MapSet.member?(bucket_keys, bucket_key(row)) and
          identity_from_dimension_row(kind, row) == identity
      end)

    edge_key = {operand_plan.operand, identity}

    edge_primitives =
      Map.get(payload.dim_edges[kind], edge_key, zero_primitives())

    merged = merge_primitives(sum_dimension_rows(interior_rows), edge_primitives)

    metrics =
      case MetricRules.derive_financial_metrics(merged) do
        {:ok, metrics} -> metrics
        {:error, _} -> nil
      end

    %{primitives: merged, metrics: metrics}
  end

  defp operand_bucket_keys(operand_plan) do
    operand_plan.fixed_buckets
    |> Enum.map(&bucket_key/1)
    |> MapSet.new()
  end

  defp bucket_key(%{bucket_kind: kind, bucket_start_utc: start, bucket_end_utc: end_utc}),
    do: {kind, start, end_utc}

  defp bucket_key(row),
    do: {row.bucket_kind, row.bucket_start_utc, row.bucket_end_utc}

  defp identity_from_dimension_row(:ticket_type, row), do: {:ticket_type, row.ticket_type_id}

  defp identity_from_dimension_row(:source_product, row),
    do: {:source_product, row.source_system_id, row.woo_product_id}

  defp identity_from_dimension_row(:source_variation, row),
    do: {:source_variation, row.source_system_id, row.woo_product_id, row.woo_variation_id}

  defp identity_from_row(:ticket_type, row), do: {:ticket_type, row.ticket_type_id}

  defp identity_from_row(:source_product, row),
    do: {:source_product, row.source_system_id, row.woo_product_id}

  defp identity_from_row(:source_variation, row),
    do: {:source_variation, row.source_system_id, row.woo_product_id, row.woo_variation_id}

  defp invalid_identity?(:ticket_type, {:ticket_type, nil}), do: true
  defp invalid_identity?(:source_product, {:source_product, nil, _}), do: true
  defp invalid_identity?(:source_variation, {:source_variation, _, _, nil}), do: true
  defp invalid_identity?(_kind, _identity), do: false

  defp redact_revenue!(result, true), do: result

  defp redact_revenue!(result, false) do
    result
    |> redact_operand_metrics!(:current)
    |> redact_operand_metrics!(:comparison)
    |> Map.update!(:event, fn %{metric_comparisons: comparisons} ->
      %{metric_comparisons: redact_metric_comparisons(comparisons)}
    end)
    |> Map.update!(:dimensions, fn dimensions ->
      Map.new(dimensions, fn {kind, rows} ->
        {kind,
         Enum.map(rows, fn row ->
           Map.update!(row, :metric_comparisons, &redact_metric_comparisons/1)
         end)}
      end)
    end)
  end

  defp redact_operand_metrics!(result, key) do
    Map.update!(result, key, fn operand ->
      if operand.metrics do
        %{operand | metrics: redact_metrics(operand.metrics)}
      else
        operand
      end
    end)
  end

  defp redact_metrics(metrics) do
    metrics
    |> Map.put(:gross_ticket_value, nil)
    |> Map.put(:refund_ticket_value, nil)
    |> Map.put(:net_ticket_value, nil)
    |> Map.put(:average_ticket_value, nil)
  end

  defp redact_metric_comparisons(comparisons) do
    Map.new(comparisons, fn {metric, comparison} ->
      if metric in @monetary_metrics do
        {metric,
         %{
           current: nil,
           comparison: nil,
           state: nil,
           absolute_delta: nil,
           percentage_delta: nil
         }}
      else
        {metric, comparison}
      end
    end)
  end

  defp sum_event_rows(rows) do
    %{
      gross_ticket_quantity: sum_quantities(Enum.map(rows, & &1.gross_ticket_quantity)),
      refund_ticket_quantity: sum_quantities(Enum.map(rows, & &1.refund_ticket_quantity)),
      gross_ticket_value: sum_decimal(Enum.map(rows, & &1.gross_ticket_value)),
      refund_ticket_value: sum_decimal(Enum.map(rows, & &1.refund_ticket_value))
    }
  end

  defp sum_dimension_rows(rows) do
    sum_event_rows(rows)
  end

  defp sum_edge_primitives(fragments, edges) do
    Enum.reduce(fragments, zero_primitives(), fn fragment, acc ->
      edge_entry =
        find_event_edge_payload(edges, fragment) || %{primitives: zero_primitives()}

      merge_primitives(acc, edge_entry.primitives)
    end)
  end

  defp sum_edge_group_rows(rows) do
    Enum.reduce(rows, zero_primitives(), fn row, acc ->
      merge_primitives(acc, edge_primitive_map(row))
    end)
  end

  defp edge_primitive_map(row) do
    %{
      gross_ticket_quantity: sum_quantities([row.gross_ticket_quantity]),
      refund_ticket_quantity: sum_quantities([row.refund_ticket_quantity]),
      gross_ticket_value: decimalize(row.gross_ticket_value),
      refund_ticket_value: decimalize(row.refund_ticket_value)
    }
  end

  defp merge_primitives(left, right) do
    %{
      gross_ticket_quantity: Decimal.add(left.gross_ticket_quantity, right.gross_ticket_quantity),
      refund_ticket_quantity:
        Decimal.add(left.refund_ticket_quantity, right.refund_ticket_quantity),
      gross_ticket_value: Decimal.add(left.gross_ticket_value, right.gross_ticket_value),
      refund_ticket_value: Decimal.add(left.refund_ticket_value, right.refund_ticket_value)
    }
  end

  defp zero_primitives do
    %{
      gross_ticket_quantity: @zero,
      refund_ticket_quantity: @zero,
      gross_ticket_value: @zero,
      refund_ticket_value: @zero
    }
  end

  defp sum_quantities(values) do
    values
    |> Enum.map(fn
      %Decimal{} = d -> d
      n when is_integer(n) -> Decimal.new(n)
    end)
    |> sum_decimal()
  end

  defp sum_decimal(values) do
    Enum.reduce(values, @zero, fn
      nil, acc -> acc
      %Decimal{} = value, acc -> Decimal.add(acc, value)
    end)
  end

  defp decimalize(nil), do: @zero
  defp decimalize(%Decimal{} = value), do: value
  defp decimalize(value) when is_integer(value), do: Decimal.new(value)
  defp decimalize(value) when is_binary(value), do: Decimal.new(value)

  defp decimal_equal?(%Decimal{} = left, %Decimal{} = right), do: Decimal.equal?(left, right)

  defp index_event_rows(rows) do
    Map.new(rows, fn row ->
      {{row.bucket_kind, row.bucket_start_utc, row.bucket_end_utc}, row}
    end)
  end

  defp operand_atom("current"), do: :current
  defp operand_atom("previous"), do: :previous
  defp operand_atom(atom) when is_atom(atom), do: atom

  defp uuid_dump!(nil), do: nil

  defp uuid_dump!(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, canonical} -> canonical
      :error -> uuid
    end
  end

  defp cast_uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_uuid, field}}
    end
  end

  @doc false
  def load_operand_payload_for_test!(event_id, currency, plan) do
    if Repo.in_transaction?() do
      load_projection_operands_in_transaction(event_id, currency, plan)
    else
      case load_projection_operands(event_id, currency, plan) do
        {:ok, payload} -> payload
        {:error, reason} -> raise "load_operand_payload_for_test!: #{inspect(reason)}"
      end
    end
  end
end
