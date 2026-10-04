defmodule EventSales.Analytics.PeriodDimensionAggregator do
  @moduledoc """
  Builds the dimensional period projection from normalized contribution facts.

  This module is deliberately pure. It does not read source tables or call the
  repository. `PeriodProjectionRefresh` supplies the already validated facts
  used for the event-period projection and the pending bucket identities that
  define the replacement scope.
  """

  alias EventSales.Analytics.PeriodBucketRules
  alias EventSales.Sales.FinancialPrimitives

  @families [:ticket_type, :source_product, :source_variation]
  @primitive_fields [
    :gross_ticket_quantity,
    :gross_ticket_value,
    :refund_ticket_quantity,
    :refund_ticket_value
  ]
  @zero Decimal.new("0")

  @type bucket_key ::
          {String.t(), String.t(), :utc_hour | :johannesburg_day, DateTime.t(), DateTime.t()}

  @type dimensional_row :: %{
          required(:event_id) => String.t(),
          required(:currency) => String.t(),
          required(:bucket_kind) => :utc_hour | :johannesburg_day,
          required(:bucket_start_utc) => DateTime.t(),
          required(:bucket_end_utc) => DateTime.t(),
          required(:bucket_timezone) => String.t(),
          required(:dimension_kind) => :ticket_type | :source_product | :source_variation,
          optional(:ticket_type_id) => String.t() | nil,
          optional(:source_system_id) => String.t() | nil,
          optional(:woo_product_id) => pos_integer() | nil,
          optional(:woo_variation_id) => pos_integer() | nil,
          required(:gross_ticket_quantity) => non_neg_integer(),
          required(:gross_ticket_value) => Decimal.t(),
          required(:refund_ticket_quantity) => non_neg_integer(),
          required(:refund_ticket_value) => Decimal.t()
        }

  @doc """
  Groups normalized M5-04D contribution facts into the three period families.

  A fact must belong to at least one pending bucket. When only one of its
  canonical hour/day identities is pending, only that identity is emitted.
  """
  @spec rows_for_pending_buckets([map()], [map()]) ::
          {:ok, [dimensional_row()]} | {:error, term()}
  def rows_for_pending_buckets(current_facts, pending_event_buckets)
      when is_list(current_facts) and is_list(pending_event_buckets) do
    with {:ok, pending_index} <- pending_index(pending_event_buckets),
         {:ok, facts} <- validated_facts(current_facts),
         {:ok, contributions} <- matching_contributions(facts, pending_index) do
      {:ok, group_contributions(contributions)}
    end
  end

  def rows_for_pending_buckets(_current_facts, _pending_event_buckets),
    do: {:error, {:invalid_dimension_input, :lists_required}}

  @doc false
  @spec variation_subset_totals_for_pending_buckets([map()], [map()]) ::
          {:ok, map()} | {:error, term()}
  def variation_subset_totals_for_pending_buckets(current_facts, pending_event_buckets)
      when is_list(current_facts) and is_list(pending_event_buckets) do
    with {:ok, pending_index} <- pending_index(pending_event_buckets),
         {:ok, facts} <- validated_facts(current_facts),
         {:ok, contributions} <- matching_contributions(facts, pending_index) do
      totals =
        contributions
        |> Enum.filter(&is_integer(&1.woo_variation_id))
        |> Enum.reduce(%{}, &add_variation_fact_totals/2)

      {:ok, totals}
    end
  end

  def variation_subset_totals_for_pending_buckets(_current_facts, _pending_event_buckets),
    do: {:error, {:invalid_dimension_input, :lists_required}}

  defp add_variation_fact_totals(fact, acc) do
    Enum.reduce(fact.buckets, acc, fn bucket, bucket_acc ->
      key = bucket_key(bucket, fact.event_id, fact.currency)
      add_fact_totals(bucket_acc, key, fact)
    end)
  end

  @doc """
  Reconciles each dimensional family independently against event totals.

  Ticket type and source product use the full event primitive totals. Source
  variation uses only the variation-bearing subset supplied by the caller.
  """
  @spec reconcile_rows([dimensional_row()], [map()], map(), map()) :: :ok | {:error, term()}
  def reconcile_rows(
        dimensional_rows,
        pending_event_buckets,
        event_totals_by_bucket,
        variation_totals_by_bucket
      )
      when is_list(dimensional_rows) and is_list(pending_event_buckets) and
             is_map(event_totals_by_bucket) and is_map(variation_totals_by_bucket) do
    with {:ok, pending_index} <- pending_index(pending_event_buckets),
         {:ok, rows} <- validated_rows(dimensional_rows, pending_index),
         {:ok, event_totals} <- validate_expected_totals(event_totals_by_bucket, pending_index),
         {:ok, variation_totals} <-
           validate_expected_totals(variation_totals_by_bucket, pending_index) do
      rows_by_family = Enum.group_by(rows, & &1.dimension_kind)

      failed_family =
        Enum.find(@families, fn family ->
          not family_reconciles?(
            Map.get(rows_by_family, family, []),
            family,
            pending_index,
            event_totals,
            variation_totals
          )
        end)

      case failed_family do
        nil -> :ok
        family -> {:error, {:dimension_reconciliation_failed, family}}
      end
    end
  end

  def reconcile_rows(_rows, _pending, _event_totals, _variation_totals),
    do: {:error, {:invalid_dimension_input, :reconciliation_arguments}}

  defp pending_index(pending_event_buckets) do
    Enum.reduce_while(pending_event_buckets, {:ok, %{}}, fn bucket, {:ok, acc} ->
      case pending_bucket_identity(bucket) do
        {:ok, key} ->
          {:cont, {:ok, Map.put(acc, key, bucket)}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_pending_dimension_bucket, reason}}}
      end
    end)
  end

  defp validated_facts(facts) do
    facts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {fact, index}, {:ok, acc} ->
      case validate_fact(fact) do
        {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_dimension_fact, index, reason}}}
      end
    end)
    |> case do
      {:ok, facts} -> {:ok, Enum.reverse(facts)}
      error -> error
    end
  end

  defp validate_fact(fact) when is_map(fact) do
    with {:ok, event_id} <- uuid(Map.get(fact, :event_id)),
         {:ok, currency} <- currency(Map.get(fact, :currency)),
         {:ok, ticket_type_id} <- uuid(Map.get(fact, :ticket_type_id)),
         {:ok, source_system_id} <- uuid(Map.get(fact, :source_system_id)),
         :ok <- positive_id(Map.get(fact, :woo_product_id), :woo_product_id),
         :ok <- optional_positive_id(Map.get(fact, :woo_variation_id), :woo_variation_id),
         {:ok, effective_at} <- canonical_instant(Map.get(fact, :effective_at)),
         :ok <- contribution_kind(Map.get(fact, :contribution_kind)),
         {:ok, primitives} <- primitive_values(fact),
         {:ok, buckets} <- PeriodBucketRules.for_instant(effective_at) do
      {:ok,
       Map.merge(fact, %{
         event_id: event_id,
         currency: currency,
         ticket_type_id: ticket_type_id,
         source_system_id: source_system_id,
         effective_at: effective_at
       })
       |> Map.merge(primitives)
       |> Map.put(:buckets, buckets)}
    end
  end

  defp validate_fact(_fact), do: {:error, :fact_must_be_a_map}

  defp matching_contributions(facts, pending_index) do
    Enum.reduce_while(facts, {:ok, []}, fn fact, {:ok, acc} ->
      matching_buckets =
        Enum.filter(fact.buckets, fn bucket ->
          Map.has_key?(pending_index, bucket_key(bucket, fact.event_id, fact.currency))
        end)

      case matching_buckets do
        [] ->
          {:halt,
           {:error,
            {:dimension_pending_bucket_missing, fact.event_id, fact.currency, fact.effective_at}}}

        buckets ->
          {:cont, {:ok, [Map.put(fact, :buckets, buckets) | acc]}}
      end
    end)
    |> case do
      {:ok, facts} -> {:ok, Enum.reverse(facts)}
      error -> error
    end
  end

  defp group_contributions(contributions) do
    contributions
    |> Enum.flat_map(fn fact ->
      ticket_type =
        family_contribution(fact, :ticket_type, %{
          ticket_type_id: fact.ticket_type_id,
          source_system_id: nil,
          woo_product_id: nil,
          woo_variation_id: nil
        })

      source_product =
        family_contribution(fact, :source_product, %{
          ticket_type_id: nil,
          source_system_id: fact.source_system_id,
          woo_product_id: fact.woo_product_id,
          woo_variation_id: nil
        })

      source_variation =
        if is_integer(fact.woo_variation_id) do
          family_contribution(fact, :source_variation, %{
            ticket_type_id: nil,
            source_system_id: fact.source_system_id,
            woo_product_id: fact.woo_product_id,
            woo_variation_id: fact.woo_variation_id
          })
        else
          []
        end

      ticket_type ++ source_product ++ source_variation
    end)
    |> Enum.group_by(&row_key/1)
    |> Enum.map(fn {_key, rows} ->
      Enum.reduce(tl(rows), hd(rows), &add_row_totals/2)
    end)
    |> Enum.reject(&zero_row?/1)
    |> Enum.sort_by(&row_sort_key/1)
  end

  defp family_contribution(fact, dimension_kind, identity) do
    Enum.map(fact.buckets, fn bucket ->
      Map.merge(identity, %{
        event_id: fact.event_id,
        currency: fact.currency,
        bucket_kind: bucket.bucket_kind,
        bucket_start_utc: bucket.bucket_start_utc,
        bucket_end_utc: bucket.bucket_end_utc,
        bucket_timezone: bucket.bucket_timezone,
        dimension_kind: dimension_kind,
        gross_ticket_quantity: fact.gross_ticket_quantity,
        gross_ticket_value: fact.gross_ticket_value,
        refund_ticket_quantity: fact.refund_ticket_quantity,
        refund_ticket_value: fact.refund_ticket_value
      })
    end)
  end

  defp row_key(row) do
    {row.event_id, row.currency, row.dimension_kind, row.ticket_type_id, row.source_system_id,
     row.woo_product_id, row.woo_variation_id, row.bucket_kind, row.bucket_start_utc,
     row.bucket_end_utc}
  end

  defp add_row_totals(row, acc) do
    acc
    |> Map.update!(:gross_ticket_quantity, &(&1 + row.gross_ticket_quantity))
    |> Map.update!(:gross_ticket_value, &Decimal.add(&1, row.gross_ticket_value))
    |> Map.update!(:refund_ticket_quantity, &(&1 + row.refund_ticket_quantity))
    |> Map.update!(:refund_ticket_value, &Decimal.add(&1, row.refund_ticket_value))
  end

  defp zero_row?(row) do
    row.gross_ticket_quantity == 0 and
      Decimal.equal?(row.gross_ticket_value, @zero) and
      row.refund_ticket_quantity == 0 and
      Decimal.equal?(row.refund_ticket_value, @zero)
  end

  defp row_sort_key(row) do
    {row.event_id, row.currency, row.bucket_kind, row.bucket_start_utc,
     Atom.to_string(row.dimension_kind), row.ticket_type_id, row.source_system_id,
     row.woo_product_id, row.woo_variation_id}
  end

  defp validated_rows(rows, pending_index) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case validate_row(row, pending_index) do
        {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_dimension_row, index, reason}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp validate_row(row, pending_index) when is_map(row) do
    with {:ok, event_id} <- uuid(Map.get(row, :event_id)),
         {:ok, currency} <- currency(Map.get(row, :currency)),
         {:ok, bucket_kind} <- bucket_kind(Map.get(row, :bucket_kind)),
         {:ok, bucket_start_utc} <- canonical_instant(Map.get(row, :bucket_start_utc)),
         {:ok, bucket_end_utc} <- canonical_instant(Map.get(row, :bucket_end_utc)),
         {:ok, bucket_timezone} <- bucket_timezone(Map.get(row, :bucket_timezone), bucket_kind),
         :ok <- valid_bucket_bounds(bucket_start_utc, bucket_end_utc),
         :ok <-
           pending_identity_exists?(
             pending_index,
             event_id,
             currency,
             bucket_kind,
             bucket_start_utc,
             bucket_end_utc
           ),
         {:ok, dimension_kind} <- dimension_kind(Map.get(row, :dimension_kind)),
         :ok <- valid_dimension_identity(row, dimension_kind),
         {:ok, primitives} <- primitive_values(row) do
      {:ok,
       row
       |> Map.merge(%{
         event_id: event_id,
         currency: currency,
         bucket_kind: bucket_kind,
         bucket_start_utc: bucket_start_utc,
         bucket_end_utc: bucket_end_utc,
         bucket_timezone: bucket_timezone,
         dimension_kind: dimension_kind
       })
       |> Map.merge(primitives)}
    end
  end

  defp validate_row(_row, _pending_index), do: {:error, :row_must_be_a_map}

  defp validate_expected_totals(totals_by_bucket, pending_index) do
    totals_by_bucket
    |> Enum.reduce_while({:ok, %{}}, fn {key, totals}, {:ok, acc} ->
      with {:ok, normalized_key} <- normalize_bucket_key(key),
           {:ok, normalized_totals} <- normalize_totals(totals) do
        {:cont, {:ok, Map.put(acc, normalized_key, normalized_totals)}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_expected_totals, reason}}}
      end
    end)
    |> case do
      {:ok, totals} -> {:ok, Map.take(totals, Map.keys(pending_index))}
      error -> error
    end
  end

  defp family_reconciles?(rows, family, pending_index, event_totals, variation_totals) do
    rows_by_bucket = Enum.group_by(rows, &row_bucket_key/1)

    Enum.all?(pending_index, fn {key, _bucket} ->
      expected =
        if family == :source_variation do
          Map.get(variation_totals, key, FinancialPrimitives.empty_totals())
        else
          Map.get(event_totals, key, FinancialPrimitives.empty_totals())
        end

      actual = sum_rows(Map.get(rows_by_bucket, key, []))
      totals_equal?(actual, expected)
    end)
  end

  defp sum_rows(rows) do
    Enum.reduce(rows, zero_totals(), fn row, acc ->
      acc
      |> Map.update!(:gross_ticket_quantity, &(&1 + row.gross_ticket_quantity))
      |> Map.update!(:gross_ticket_value, &Decimal.add(&1, row.gross_ticket_value))
      |> Map.update!(:refund_ticket_quantity, &(&1 + row.refund_ticket_quantity))
      |> Map.update!(:refund_ticket_value, &Decimal.add(&1, row.refund_ticket_value))
    end)
  end

  defp totals_equal?(left, right) do
    Enum.all?(@primitive_fields, fn primitive ->
      left_value = Map.fetch!(left, primitive)
      right_value = Map.fetch!(right, primitive)

      if primitive in [:gross_ticket_quantity, :refund_ticket_quantity] do
        Decimal.equal?(quantity_decimal(left_value), quantity_decimal(right_value))
      else
        Decimal.equal?(left_value, right_value)
      end
    end)
  end

  defp normalize_totals(totals) when is_map(totals) do
    with {:ok, gross_quantity} <- non_negative_quantity(Map.get(totals, :gross_ticket_quantity)),
         {:ok, gross_value} <- non_negative_decimal(Map.get(totals, :gross_ticket_value)),
         {:ok, refund_quantity} <- non_negative_quantity(Map.get(totals, :refund_ticket_quantity)),
         {:ok, refund_value} <- non_negative_decimal(Map.get(totals, :refund_ticket_value)) do
      {:ok,
       %{
         gross_ticket_quantity: gross_quantity,
         gross_ticket_value: gross_value,
         refund_ticket_quantity: refund_quantity,
         refund_ticket_value: refund_value
       }}
    end
  end

  defp normalize_totals(_totals), do: {:error, :totals_must_be_a_map}

  defp non_negative_quantity(value) when is_integer(value) and value >= 0,
    do: {:ok, Decimal.new(value)}

  defp non_negative_quantity(%Decimal{} = value) do
    if Decimal.compare(value, @zero) == :lt or not FinancialPrimitives.integral_quantity?(value),
      do: {:error, :quantity_must_be_non_negative_integer},
      else: {:ok, value}
  end

  defp non_negative_quantity(_value), do: {:error, :quantity_must_be_non_negative_integer}

  defp primitive_values(fact) do
    with {:ok, gross_quantity} <- non_negative_integer(Map.get(fact, :gross_ticket_quantity)),
         {:ok, gross_value} <- non_negative_decimal(Map.get(fact, :gross_ticket_value)),
         {:ok, refund_quantity} <- non_negative_integer(Map.get(fact, :refund_ticket_quantity)),
         {:ok, refund_value} <- non_negative_decimal(Map.get(fact, :refund_ticket_value)) do
      {:ok,
       %{
         gross_ticket_quantity: gross_quantity,
         gross_ticket_value: gross_value,
         refund_ticket_quantity: refund_quantity,
         refund_ticket_value: refund_value
       }}
    end
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_value), do: {:error, :quantity_must_be_non_negative_integer}

  defp quantity_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp quantity_decimal(%Decimal{} = value), do: value

  defp non_negative_decimal(%Decimal{} = value) do
    if Decimal.compare(value, @zero) == :lt,
      do: {:error, :value_must_be_non_negative},
      else: {:ok, value}
  end

  defp non_negative_decimal(_value), do: {:error, :value_must_be_decimal}

  defp add_fact_totals(acc, key, fact) do
    previous = Map.get(acc, key, zero_totals())

    Map.put(acc, key, %{
      gross_ticket_quantity: previous.gross_ticket_quantity + fact.gross_ticket_quantity,
      gross_ticket_value: Decimal.add(previous.gross_ticket_value, fact.gross_ticket_value),
      refund_ticket_quantity: previous.refund_ticket_quantity + fact.refund_ticket_quantity,
      refund_ticket_value: Decimal.add(previous.refund_ticket_value, fact.refund_ticket_value)
    })
  end

  defp zero_totals do
    %{
      gross_ticket_quantity: 0,
      gross_ticket_value: @zero,
      refund_ticket_quantity: 0,
      refund_ticket_value: @zero
    }
  end

  defp pending_bucket_identity(bucket) when is_map(bucket) do
    with {:ok, event_id} <- uuid(Map.get(bucket, :event_id)),
         {:ok, currency} <- currency(Map.get(bucket, :currency)),
         {:ok, bucket_kind} <- bucket_kind(Map.get(bucket, :bucket_kind)),
         {:ok, bucket_start_utc} <- canonical_instant(Map.get(bucket, :bucket_start_utc)),
         {:ok, bucket_end_utc} <- canonical_instant(Map.get(bucket, :bucket_end_utc)),
         {:ok, bucket_timezone} <- bucket_timezone(Map.get(bucket, :bucket_timezone), bucket_kind),
         :ok <- valid_bucket_bounds(bucket_start_utc, bucket_end_utc) do
      _ = bucket_timezone
      {:ok, {event_id, currency, bucket_kind, bucket_start_utc, bucket_end_utc}}
    end
  end

  defp pending_bucket_identity(_bucket), do: {:error, :bucket_must_be_a_map}

  defp pending_identity_exists?(
         pending_index,
         event_id,
         currency,
         bucket_kind,
         start_utc,
         end_utc
       ) do
    key = {event_id, currency, bucket_kind, start_utc, end_utc}
    if Map.has_key?(pending_index, key), do: :ok, else: {:error, :bucket_not_pending}
  end

  defp bucket_key(bucket, event_id, currency) do
    {event_id, currency, bucket.bucket_kind, bucket.bucket_start_utc, bucket.bucket_end_utc}
  end

  defp row_bucket_key(row) do
    {row.event_id, row.currency, row.bucket_kind, row.bucket_start_utc, row.bucket_end_utc}
  end

  defp normalize_bucket_key({event_id, currency, bucket_kind, bucket_start_utc, bucket_end_utc}) do
    with {:ok, event_id} <- uuid(event_id),
         {:ok, currency} <- currency(currency),
         {:ok, bucket_kind} <- bucket_kind(bucket_kind),
         {:ok, bucket_start_utc} <- canonical_instant(bucket_start_utc),
         {:ok, bucket_end_utc} <- canonical_instant(bucket_end_utc),
         :ok <- valid_bucket_bounds(bucket_start_utc, bucket_end_utc) do
      {:ok, {event_id, currency, bucket_kind, bucket_start_utc, bucket_end_utc}}
    end
  end

  defp normalize_bucket_key(_key), do: {:error, :invalid_bucket_key}

  defp valid_dimension_identity(row, :ticket_type) do
    with {:ok, _} <- uuid(Map.get(row, :ticket_type_id)),
         true <- is_nil(Map.get(row, :source_system_id)),
         true <- is_nil(Map.get(row, :woo_product_id)),
         true <- is_nil(Map.get(row, :woo_variation_id)) do
      :ok
    else
      _ -> {:error, :invalid_ticket_type_identity}
    end
  end

  defp valid_dimension_identity(row, :source_product) do
    with true <- is_nil(Map.get(row, :ticket_type_id)),
         {:ok, _} <- uuid(Map.get(row, :source_system_id)),
         :ok <- positive_id(Map.get(row, :woo_product_id), :woo_product_id),
         true <- is_nil(Map.get(row, :woo_variation_id)) do
      :ok
    else
      _ -> {:error, :invalid_source_product_identity}
    end
  end

  defp valid_dimension_identity(row, :source_variation) do
    with true <- is_nil(Map.get(row, :ticket_type_id)),
         {:ok, _} <- uuid(Map.get(row, :source_system_id)),
         :ok <- positive_id(Map.get(row, :woo_product_id), :woo_product_id),
         :ok <- positive_id(Map.get(row, :woo_variation_id), :woo_variation_id) do
      :ok
    else
      _ -> {:error, :invalid_source_variation_identity}
    end
  end

  defp contribution_kind(:sale), do: :ok
  defp contribution_kind(:refund), do: :ok
  defp contribution_kind(_kind), do: {:error, :invalid_contribution_kind}

  defp dimension_kind(:ticket_type), do: {:ok, :ticket_type}
  defp dimension_kind(:source_product), do: {:ok, :source_product}
  defp dimension_kind(:source_variation), do: {:ok, :source_variation}
  defp dimension_kind(_kind), do: {:error, :invalid_dimension_kind}

  defp bucket_kind(:utc_hour), do: {:ok, :utc_hour}
  defp bucket_kind(:johannesburg_day), do: {:ok, :johannesburg_day}
  defp bucket_kind(_kind), do: {:error, :invalid_bucket_kind}

  defp bucket_timezone("UTC", :utc_hour), do: {:ok, "UTC"}
  defp bucket_timezone("Africa/Johannesburg", :johannesburg_day), do: {:ok, "Africa/Johannesburg"}
  defp bucket_timezone(_timezone, _kind), do: {:error, :invalid_bucket_timezone}

  defp valid_bucket_bounds(start_utc, end_utc) do
    if DateTime.compare(start_utc, end_utc) == :lt,
      do: :ok,
      else: {:error, :invalid_bucket_bounds}
  end

  defp positive_id(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_id(_value, field), do: {:error, {:invalid_positive_id, field}}

  defp optional_positive_id(nil, _field), do: :ok
  defp optional_positive_id(value, field), do: positive_id(value, field)

  defp currency(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_currency}, else: {:ok, value}
  end

  defp currency(_value), do: {:error, :invalid_currency}

  defp canonical_instant(%DateTime{} = instant) do
    case PeriodBucketRules.for_instant(instant) do
      {:ok, _buckets} -> {:ok, instant}
      {:error, _reason} -> {:error, :invalid_utc_instant}
    end
  end

  defp canonical_instant(_instant), do: {:error, :invalid_utc_instant}

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, canonical} ->
        {:ok, canonical}

      :error ->
        case Ecto.UUID.load(value) do
          {:ok, canonical} -> {:ok, canonical}
          :error -> {:error, :invalid_uuid}
        end
    end
  end

  defp uuid(_value), do: {:error, :invalid_uuid}
end
