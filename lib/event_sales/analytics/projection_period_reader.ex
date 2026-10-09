defmodule EventSales.Analytics.ProjectionPeriodReader do
  @moduledoc false

  import Ecto.Query

  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Repo

  @zero Decimal.new("0")

  @doc false
  def read(event_id, currency, plan) when is_binary(event_id) and is_binary(currency) do
    snapshot_specs = required_snapshot_specs(plan)
    event_rows = fetch_event_snapshot_rows(event_id, currency, snapshot_specs)
    event_index = index_event_rows(event_rows)

    with {:ok, event_edges} <- aggregate_event_edges(event_id, currency, plan, event_rows) do
      {:ok,
       %{
         event_rows: event_rows,
         event_edges: event_edges,
         current_operand:
           compose_operand(
             Enum.find(plan.operands, &(&1.operand == :current)),
             event_index,
             event_edges
           ),
         previous_operand:
           compose_operand(
             Enum.find(plan.operands, &(&1.operand == :previous)),
             event_index,
             event_edges
           )
       }}
    end
  end

  defp required_snapshot_specs(plan) do
    plan.operands
    |> Enum.flat_map(fn operand ->
      envelope_specs = Enum.map(operand.edge_fragments, &envelope_bucket_spec/1)
      operand.fixed_buckets ++ envelope_specs
    end)
    |> Enum.uniq_by(&bucket_key/1)
  end

  defp envelope_bucket_spec(fragment) do
    hour_start = fragment.envelope_hour_start_utc

    %{
      bucket_kind: :utc_hour,
      bucket_start_utc: hour_start,
      bucket_end_utc: DateTime.add(hour_start, 1, :hour)
    }
  end

  defp fetch_event_snapshot_rows(_event_id, _currency, []), do: []

  defp fetch_event_snapshot_rows(event_id, currency, snapshot_specs) do
    bucket_filter = bucket_specs_dynamic(snapshot_specs)

    query =
      from(row in EventPeriodAggregateSnapshot,
        where: row.event_id == ^event_id and row.currency == ^currency,
        where: ^bucket_filter
      )

    Repo.all(query)
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

  defp aggregate_event_edges(_event_id, _currency, %{edge_fragment_count: 0}, _event_rows),
    do: {:ok, %{}}

  defp aggregate_event_edges(event_id, currency, plan, event_rows) do
    edge_fragments = Enum.flat_map(plan.operands, & &1.edge_fragments)
    {coverage_by_hour, semantic_by_hour} = envelope_hour_metadata_maps(event_rows)

    if Enum.all?(edge_fragments, fn fragment ->
         Map.has_key?(coverage_by_hour, fragment.envelope_hour_start_utc) and
           Map.has_key?(semantic_by_hour, fragment.envelope_hour_start_utc)
       end) do
      query_event_edge_aggregates(
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

  defp query_event_edge_aggregates(
         event_id,
         currency,
         edge_fragments,
         coverage_by_hour,
         semantic_by_hour
       ) do
    operands = Enum.map(edge_fragments, &Atom.to_string(&1.operand))
    edge_indices = Enum.to_list(0..(length(edge_fragments) - 1))
    edge_starts = Enum.map(edge_fragments, & &1.edge_start_utc)
    edge_ends = Enum.map(edge_fragments, & &1.edge_end_utc)

    coverages =
      Enum.map(edge_fragments, &Map.fetch!(coverage_by_hour, &1.envelope_hour_start_utc))

    semantics =
      Enum.map(edge_fragments, &Map.fetch!(semantic_by_hour, &1.envelope_hour_start_utc))

    sql = """
    SELECT
      r.operand,
      r.edge_start_utc,
      r.edge_end_utc,
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
      {:ok, result} -> {:ok, index_event_edge_rows(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp index_event_edge_rows(%{columns: columns, rows: rows}) do
    Map.new(rows, fn values ->
      row = columns |> Enum.zip(values) |> Map.new()

      edge = %{
        operand: if(row["operand"] == "current", do: :current, else: :previous),
        edge_start_utc: row["edge_start_utc"],
        edge_end_utc: row["edge_end_utc"],
        primitives: %{
          gross_ticket_quantity: decimalize(row["gross_ticket_quantity"]),
          refund_ticket_quantity: decimalize(row["refund_ticket_quantity"]),
          gross_ticket_value: decimalize(row["gross_ticket_value"]),
          refund_ticket_value: decimalize(row["refund_ticket_value"])
        },
        metadata_mismatch_count: integerize(row["metadata_mismatch_count"])
      }

      {edge_key(edge), edge}
    end)
  end

  defp envelope_hour_metadata_maps(event_rows) do
    event_rows
    |> Enum.filter(&(&1.bucket_kind == :utc_hour))
    |> Enum.reduce({%{}, %{}}, fn row, {coverage, semantic} ->
      {
        Map.put(coverage, row.bucket_start_utc, row.coverage_identity),
        Map.put(semantic, row.bucket_start_utc, row.semantic_version)
      }
    end)
  end

  defp zero_event_edges(edge_fragments) do
    Map.new(edge_fragments, fn fragment ->
      {edge_key(fragment), %{primitives: zero_primitives(), metadata_mismatch_count: 0}}
    end)
  end

  defp edge_key(fragment), do: {fragment.operand, fragment.edge_start_utc, fragment.edge_end_utc}

  defp compose_operand(operand_plan, event_index, event_edges) do
    required_specs =
      operand_plan.fixed_buckets ++ Enum.map(operand_plan.edge_fragments, &envelope_bucket_spec/1)

    rows = Enum.map(required_specs, &Map.get(event_index, bucket_key(&1)))
    present_rows = Enum.reject(rows, &is_nil/1) |> Enum.uniq_by(& &1.id)

    edges = Enum.map(operand_plan.edge_fragments, &Map.get(event_edges, edge_key(&1)))

    ready? =
      required_specs != [] and
        length(present_rows) == length(Enum.uniq_by(required_specs, &bucket_key/1)) and
        coherent_current_rows?(present_rows) and edge_rows_ready?(edges)

    if ready? do
      first_row = hd(present_rows)
      fixed_rows = Enum.map(operand_plan.fixed_buckets, &Map.fetch!(event_index, bucket_key(&1)))
      primitives = sum_event_rows(fixed_rows)

      edge_primitives =
        Enum.reduce(edges, zero_primitives(), &merge_primitives(&2, &1.primitives))

      %{
        readiness: :ready,
        scope: %{
          semantic_version: first_row.semantic_version,
          coverage_identity: first_row.coverage_identity
        },
        primitives: merge_primitives(primitives, edge_primitives)
      }
    else
      %{readiness: :not_ready, scope: nil, primitives: nil}
    end
  end

  defp coherent_current_rows?(rows) do
    rows != [] and Enum.all?(rows, &current_compatible_row?/1) and
      length(Enum.uniq_by(rows, & &1.semantic_version)) == 1 and
      length(Enum.uniq_by(rows, & &1.coverage_identity)) == 1
  end

  defp edge_rows_ready?(edges) do
    Enum.all?(edges, fn
      %{metadata_mismatch_count: 0} -> true
      _ -> false
    end)
  end

  defp current_compatible_row?(row) do
    row.projection_state == :current and row.semantic_version >= 1 and
      is_binary(row.coverage_identity) and byte_size(row.coverage_identity) > 0
  end

  defp sum_event_rows(rows) do
    %{
      gross_ticket_quantity: sum_quantities(Enum.map(rows, & &1.gross_ticket_quantity)),
      refund_ticket_quantity: sum_quantities(Enum.map(rows, & &1.refund_ticket_quantity)),
      gross_ticket_value: sum_decimal(Enum.map(rows, & &1.gross_ticket_value)),
      refund_ticket_value: sum_decimal(Enum.map(rows, & &1.refund_ticket_value))
    }
  end

  defp sum_quantities(values) do
    values
    |> Enum.map(fn
      %Decimal{} = value -> value
      integer when is_integer(integer) -> Decimal.new(integer)
    end)
    |> sum_decimal()
  end

  defp sum_decimal(values) do
    Enum.reduce(values, @zero, fn
      nil, acc -> acc
      %Decimal{} = value, acc -> Decimal.add(acc, value)
    end)
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

  defp decimalize(nil), do: @zero
  defp decimalize(%Decimal{} = value), do: value
  defp decimalize(value) when is_integer(value), do: Decimal.new(value)
  defp decimalize(value) when is_binary(value), do: Decimal.new(value)

  defp integerize(value) when is_integer(value), do: value
  defp integerize(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integerize(value) when is_binary(value), do: String.to_integer(value)
  defp integerize(nil), do: 0

  defp bucket_key(%{bucket_kind: kind, bucket_start_utc: start, bucket_end_utc: end_utc}),
    do: {kind, start, end_utc}

  defp bucket_key(row), do: {row.bucket_kind, row.bucket_start_utc, row.bucket_end_utc}

  defp index_event_rows(rows) do
    Map.new(rows, fn row -> {bucket_key(row), row} end)
  end
end
