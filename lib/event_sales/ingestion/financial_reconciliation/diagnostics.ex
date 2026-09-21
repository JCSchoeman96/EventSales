defmodule EventSales.Ingestion.FinancialReconciliation.Diagnostics do
  @moduledoc """
  Pure classification of upstream financial reconciliation outcomes into in-memory
  diagnostic hints for M4-05 persistence.

  This module performs no IO, persistence, or lifecycle mutation.
  """

  alias EventSales.Sales.FinancialPrimitives

  @scope_fields [
    :sync_run_id,
    :event_id,
    :source_system_id,
    :coverage_start,
    :sales_covered_through,
    :refunds_covered_through
  ]

  @uuid_scope_fields [:sync_run_id, :event_id, :source_system_id]
  @datetime_scope_fields [:coverage_start, :sales_covered_through, :refunds_covered_through]

  @max_list_cap 20

  @detail_whitelist ~w(
    source_order_id
    woo_order_id
    woo_line_item_id
    woo_refund_id
    woo_refund_line_item_id
    field
    kind
    reason
    boundary
    expected
    actual
    reference_count
    present_reference_count
    source_refund_count
    expected_refund_count
    source_only_refund_ids
    expected_only_refund_ids
    truncated?
    source_currency_count
    local_currency_count
    source_currencies
    local_currencies
  )a

  @primitive_categories %{
    gross_ticket_quantity: :gross_quantity_mismatch,
    gross_ticket_value: :gross_value_mismatch,
    refund_ticket_quantity: :refund_quantity_mismatch,
    refund_ticket_value: :refund_value_mismatch,
    net_ticket_quantity: :net_quantity_mismatch,
    net_ticket_value: :net_value_mismatch
  }

  @source_missing_source_fact_kinds %{
    order: :missing_source_fact,
    order_fetch_failed: :missing_source_fact,
    refund: :missing_refund_detail,
    refund_fetch_failed: :missing_refund_detail,
    refund_observation: :missing_local_fact,
    refund_reference_inconsistent: :missing_local_fact,
    refund_reference_lookup: :missing_local_fact
  }

  @local_missing_local_fact_kinds %{
    order: :missing_local_fact,
    refund_observation: :missing_local_fact,
    refund_reference_inconsistent: :missing_local_fact,
    refund_not_active: :missing_local_fact,
    refund_parent_binding: :missing_local_fact,
    refund: :missing_refund_detail,
    refund_not_complete: :missing_refund_detail
  }

  @type disposition :: :matched | :mismatched | :failed | :superseded

  @type metric_mismatch :: %{
          category: atom(),
          currency: String.t(),
          primitive: FinancialPrimitives.primitive(),
          source_value: Decimal.t(),
          local_value: Decimal.t(),
          delta: Decimal.t()
        }

  @type structural_finding :: %{
          category: atom(),
          origin: :source | :local | :comparator,
          scope: map(),
          details: map()
        }

  @type diagnostic_result :: %{
          disposition: disposition(),
          metric_mismatches: [metric_mismatch()],
          structural_findings: [structural_finding()]
        }

  @doc """
  Classifies a successful M4-03 comparison result.
  """
  @spec from_comparison(map()) :: {:ok, diagnostic_result()} | {:error, term()}
  def from_comparison(comparison_result) when is_map(comparison_result) do
    with {:ok, _} <- validate_comparison_result(comparison_result) do
      case Map.fetch!(comparison_result, :status) do
        :matched ->
          {:ok,
           %{
             disposition: :matched,
             metric_mismatches: [],
             structural_findings: []
           }}

        :mismatched ->
          metric_mismatches = build_metric_mismatches(Map.fetch!(comparison_result, :comparisons))

          {:ok,
           %{
             disposition: :mismatched,
             metric_mismatches: metric_mismatches,
             structural_findings: []
           }}

        status ->
          {:error,
           {:invalid_diagnostic_input, %{reason: :invalid_comparison_status, status: status}}}
      end
    end
  end

  def from_comparison(_comparison_result) do
    {:error, {:invalid_diagnostic_input, %{reason: :not_map}}}
  end

  @doc """
  Classifies an M4-01 source-side structural error.
  """
  @spec from_source_error(map(), {atom(), map()}) :: {:ok, diagnostic_result()} | {:error, term()}
  def from_source_error(scope, {category, details})
      when is_map(scope) and is_atom(category) and is_map(details) do
    with {:ok, validated_scope} <- validate_scope(scope),
         {:ok, disposition, finding_category} <- classify_source_error(category, details) do
      finding =
        build_structural_finding(
          finding_category,
          :source,
          validated_scope,
          category,
          details
        )

      {:ok,
       %{
         disposition: disposition,
         metric_mismatches: [],
         structural_findings: [finding]
       }}
    end
  end

  def from_source_error(_scope, _error) do
    {:error, {:invalid_diagnostic_input, %{reason: :invalid_source_error_shape}}}
  end

  @doc """
  Classifies an M4-02 local-side structural error.
  """
  @spec from_local_error(map(), {atom(), map()}) :: {:ok, diagnostic_result()} | {:error, term()}
  def from_local_error(scope, {category, details})
      when is_map(scope) and is_atom(category) and is_map(details) do
    with {:ok, validated_scope} <- validate_scope(scope),
         {:ok, disposition, finding_category} <- classify_local_error(category, details) do
      finding =
        build_structural_finding(
          finding_category,
          :local,
          validated_scope,
          category,
          details
        )

      {:ok,
       %{
         disposition: disposition,
         metric_mismatches: [],
         structural_findings: [finding]
       }}
    end
  end

  def from_local_error(_scope, _error) do
    {:error, {:invalid_diagnostic_input, %{reason: :invalid_local_error_shape}}}
  end

  @doc """
  Classifies an M4-03 comparator structural error.
  """
  @spec from_comparator_error(map(), {atom(), map()}) ::
          {:ok, diagnostic_result()} | {:error, term()}
  def from_comparator_error(scope, {category, details})
      when is_map(scope) and is_atom(category) and is_map(details) do
    with {:ok, validated_scope} <- validate_scope(scope),
         {:ok, disposition, finding_category} <- classify_comparator_error(category) do
      finding =
        build_structural_finding(
          finding_category,
          :comparator,
          validated_scope,
          category,
          details
        )

      {:ok,
       %{
         disposition: disposition,
         metric_mismatches: [],
         structural_findings: [finding]
       }}
    end
  end

  def from_comparator_error(_scope, _error) do
    {:error, {:invalid_diagnostic_input, %{reason: :invalid_comparator_error_shape}}}
  end

  defp validate_comparison_result(%{status: status, comparisons: comparisons, scope: scope})
       when status in [:matched, :mismatched] and is_list(comparisons) and is_map(scope) do
    with {:ok, _} <- validate_scope(scope) do
      validate_comparison_rows(comparisons)
    end
  end

  defp validate_comparison_result(_comparison_result) do
    {:error, {:invalid_diagnostic_input, %{reason: :invalid_comparison_result_shape}}}
  end

  defp validate_comparison_rows(comparisons) do
    Enum.reduce_while(comparisons, {:ok, comparisons}, fn row, {:ok, _} ->
      validate_comparison_row(row, comparisons)
    end)
  end

  defp validate_comparison_row(
         %{
           currency: currency,
           primitive: primitive,
           source_value: %Decimal{},
           local_value: %Decimal{},
           matched?: matched?
         },
         comparisons
       )
       when is_binary(currency) and is_boolean(matched?) do
    if Map.has_key?(@primitive_categories, primitive) do
      {:cont, {:ok, comparisons}}
    else
      {:halt,
       {:error, {:invalid_diagnostic_input, %{reason: :unknown_primitive, primitive: primitive}}}}
    end
  end

  defp validate_comparison_row(_row, _comparisons) do
    {:halt, {:error, {:invalid_diagnostic_input, %{reason: :invalid_comparison_row}}}}
  end

  defp validate_scope(scope) when is_map(scope) do
    Enum.reduce_while(@scope_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      validate_scope_field(scope, field, acc)
    end)
  end

  defp validate_scope_field(scope, field, acc) do
    with {:ok, value} <- Map.fetch(scope, field),
         :ok <- validate_scope_value(field, value) do
      {:cont, {:ok, Map.put(acc, field, value)}}
    else
      :error ->
        {:halt,
         {:error, {:invalid_diagnostic_input, %{reason: :missing_scope_field, field: field}}}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp validate_scope_value(field, value) when field in @uuid_scope_fields do
    if is_binary(value) and value != "" do
      :ok
    else
      {:error, {:invalid_diagnostic_input, %{reason: :invalid_scope_field, field: field}}}
    end
  end

  defp validate_scope_value(field, %DateTime{} = value) when field in @datetime_scope_fields do
    if DateTime.compare(value, value) == :eq do
      :ok
    else
      {:error, {:invalid_diagnostic_input, %{reason: :invalid_scope_field, field: field}}}
    end
  end

  defp validate_scope_value(field, _value) when field in @datetime_scope_fields do
    {:error, {:invalid_diagnostic_input, %{reason: :invalid_scope_field, field: field}}}
  end

  defp build_metric_mismatches(comparisons) do
    comparisons
    |> Enum.filter(fn row -> row.matched? == false end)
    |> Enum.map(fn row ->
      category = Map.fetch!(@primitive_categories, row.primitive)

      %{
        category: category,
        currency: row.currency,
        primitive: row.primitive,
        source_value: row.source_value,
        local_value: row.local_value,
        delta: Decimal.sub(row.local_value, row.source_value)
      }
    end)
  end

  defp classify_source_error(:source_snapshot_stale, _details) do
    {:ok, :superseded, :source_snapshot_stale}
  end

  defp classify_source_error(:refund_identity_drift, _details) do
    {:ok, :superseded, :refund_identity_drift}
  end

  defp classify_source_error(:http_under_lock, _details) do
    {:ok, :failed, :http_under_lock}
  end

  defp classify_source_error(:historical_recognition_unproven, _details) do
    {:ok, :failed, :historical_recognition_unproven}
  end

  defp classify_source_error(:timestamp_incomplete, _details) do
    {:ok, :failed, :timestamp_incomplete}
  end

  defp classify_source_error(:currency_conflict, _details) do
    {:ok, :failed, :currency_conflict}
  end

  defp classify_source_error(:invalid_currency, _details) do
    {:ok, :failed, :currency_conflict}
  end

  defp classify_source_error(:unresolved_attribution, _details) do
    {:ok, :failed, :unresolved_attribution}
  end

  defp classify_source_error(:financial_primitive_incomplete, _details) do
    {:ok, :failed, :financial_primitive_incomplete}
  end

  defp classify_source_error(:missing_source_fact, %{kind: kind}) when is_atom(kind) do
    case Map.fetch(@source_missing_source_fact_kinds, kind) do
      {:ok, category} ->
        {:ok, :failed, category}

      :error ->
        {:error,
         {:invalid_diagnostic_input, %{reason: :unknown_missing_source_fact_kind, kind: kind}}}
    end
  end

  defp classify_source_error(:invalid_scope, %{reason: :historical_certificate_not_current}) do
    {:ok, :superseded, :invalid_scope}
  end

  defp classify_source_error(:invalid_scope, _details) do
    {:ok, :failed, :invalid_scope}
  end

  defp classify_source_error(category, _details) do
    {:error, {:invalid_diagnostic_input, %{reason: :unknown_source_error, category: category}}}
  end

  defp classify_local_error(:unresolved_attribution, _details) do
    {:ok, :failed, :unresolved_attribution}
  end

  defp classify_local_error(:timestamp_incomplete, _details) do
    {:ok, :failed, :timestamp_incomplete}
  end

  defp classify_local_error(:currency_conflict, _details) do
    {:ok, :failed, :currency_conflict}
  end

  defp classify_local_error(:financial_primitive_incomplete, _details) do
    {:ok, :failed, :financial_primitive_incomplete}
  end

  defp classify_local_error(:historical_recognition_unproven, _details) do
    {:ok, :failed, :historical_recognition_unproven}
  end

  defp classify_local_error(:missing_local_fact, %{kind: kind}) when is_atom(kind) do
    case Map.fetch(@local_missing_local_fact_kinds, kind) do
      {:ok, category} ->
        {:ok, :failed, category}

      :error ->
        {:error,
         {:invalid_diagnostic_input, %{reason: :unknown_missing_local_fact_kind, kind: kind}}}
    end
  end

  defp classify_local_error(:invalid_scope, %{reason: :historical_certificate_not_current}) do
    {:ok, :superseded, :invalid_scope}
  end

  defp classify_local_error(:invalid_scope, _details) do
    {:ok, :failed, :invalid_scope}
  end

  defp classify_local_error(category, _details) do
    {:error, {:invalid_diagnostic_input, %{reason: :unknown_local_error, category: category}}}
  end

  defp classify_comparator_error(:currency_set_mismatch) do
    {:ok, :mismatched, :currency_conflict}
  end

  defp classify_comparator_error(:scope_mismatch) do
    {:ok, :failed, :comparison_scope_mismatch}
  end

  defp classify_comparator_error(category)
       when category in [
              :invalid_scope_field,
              :invalid_currency_key,
              :invalid_currencies,
              :invalid_primitive,
              :invalid_input
            ] do
    {:ok, :failed, :invalid_comparison_input}
  end

  defp classify_comparator_error(category) do
    {:error,
     {:invalid_diagnostic_input, %{reason: :unknown_comparator_error, category: category}}}
  end

  defp build_structural_finding(category, origin, scope, upstream_category, upstream_details) do
    details = build_bounded_details(upstream_category, category, upstream_details)

    %{
      category: category,
      origin: origin,
      scope: scope,
      details: details
    }
  end

  defp build_bounded_details(:refund_identity_drift, :refund_identity_drift, details) do
    normalize_refund_identity_drift_details(details)
  end

  defp build_bounded_details(:currency_set_mismatch, :currency_conflict, details) do
    normalize_currency_set_mismatch_details(details)
  end

  defp build_bounded_details(_upstream_category, _finding_category, details) do
    whitelist_details(details)
  end

  defp whitelist_details(details) do
    details
    |> Map.take(@detail_whitelist)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_refund_identity_drift_details(details) do
    woo_ids = normalize_id_list(Map.get(details, :woo_refund_ids, []))
    expected_ids = normalize_id_list(Map.get(details, :expected_refund_ids, []))

    woo_set = MapSet.new(woo_ids)
    expected_set = MapSet.new(expected_ids)

    source_only = Enum.sort(Enum.filter(woo_ids, &(!MapSet.member?(expected_set, &1))))
    expected_only = Enum.sort(Enum.filter(expected_ids, &(!MapSet.member?(woo_set, &1))))

    {source_only_kept, source_truncated} = cap_list(source_only)
    {expected_only_kept, expected_truncated} = cap_list(expected_only)

    details
    |> whitelist_details()
    |> Map.merge(%{
      source_refund_count: length(woo_ids),
      expected_refund_count: length(expected_ids),
      source_only_refund_ids: source_only_kept,
      expected_only_refund_ids: expected_only_kept,
      truncated?: source_truncated or expected_truncated
    })
  end

  defp normalize_currency_set_mismatch_details(details) do
    source_currencies = normalize_currency_list(Map.get(details, :source_currencies, []))
    local_currencies = normalize_currency_list(Map.get(details, :local_currencies, []))

    {source_kept, source_truncated} = cap_list(source_currencies)
    {local_kept, local_truncated} = cap_list(local_currencies)

    %{
      source_currency_count: length(source_currencies),
      local_currency_count: length(local_currencies),
      source_currencies: source_kept,
      local_currencies: local_kept,
      truncated?: source_truncated or local_truncated
    }
  end

  defp normalize_id_list(ids) when is_list(ids) do
    ids
    |> Enum.filter(&(is_integer(&1) or is_binary(&1)))
    |> Enum.uniq()
  end

  defp normalize_id_list(_ids), do: []

  defp normalize_currency_list(currencies) when is_list(currencies) do
    currencies
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.sort()
    |> Enum.uniq()
  end

  defp normalize_currency_list(_currencies), do: []

  defp cap_list(items) do
    if length(items) > @max_list_cap do
      {Enum.take(items, @max_list_cap), true}
    else
      {items, false}
    end
  end
end
