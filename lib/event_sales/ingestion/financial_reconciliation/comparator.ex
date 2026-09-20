defmodule EventSales.Ingestion.FinancialReconciliation.Comparator do
  @moduledoc """
  Pure deterministic comparison between M4-01 source totals and M4-02 local totals.

  Accepts already-successful extraction result maps, validates scope equivalence,
  compares currency sets exactly, and compares the locked C17 financial primitives
  with exact `Decimal.equal?/2` semantics.
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

  @type comparison_row :: %{
          currency: String.t(),
          primitive: FinancialPrimitives.primitive(),
          source_value: Decimal.t(),
          local_value: Decimal.t(),
          matched?: boolean()
        }

  @type comparison_result :: %{
          status: :matched | :mismatched,
          scope: %{
            sync_run_id: String.t(),
            event_id: String.t(),
            source_system_id: String.t(),
            coverage_start: DateTime.t(),
            sales_covered_through: DateTime.t(),
            refunds_covered_through: DateTime.t()
          },
          comparisons: [comparison_row()]
        }

  @doc """
  Compares successful M4-01 source totals with successful M4-02 local totals.
  """
  @spec compare(map(), map()) :: {:ok, comparison_result()} | {:error, term()}
  def compare(source_result, local_result) when is_map(source_result) and is_map(local_result) do
    with {:ok, scope} <- validate_scope_equivalence(source_result, local_result),
         {:ok, source_currencies} <- validate_currencies_map(source_result),
         {:ok, local_currencies} <- validate_currencies_map(local_result),
         :ok <- validate_currency_set_equivalence(source_currencies, local_currencies),
         {:ok, comparisons} <- build_comparisons(source_currencies, local_currencies) do
      status =
        if Enum.all?(comparisons, & &1.matched?),
          do: :matched,
          else: :mismatched

      {:ok, %{status: status, scope: scope, comparisons: comparisons}}
    end
  end

  def compare(_source_result, _local_result) do
    {:error, {:invalid_input, %{reason: :not_map}}}
  end

  defp validate_scope_equivalence(source_result, local_result) do
    with {:ok, source_scope} <- extract_scope(source_result),
         {:ok, local_scope} <- extract_scope(local_result),
         :ok <- compare_scope_maps(source_scope, local_scope) do
      {:ok, source_scope}
    end
  end

  defp extract_scope(result) do
    Enum.reduce_while(@scope_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case fetch_scope_field(result, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_scope_field(result, field) do
    with {:ok, value} <- Map.fetch(result, field),
         :ok <- validate_scope_value(field, value) do
      {:ok, value}
    else
      :error -> {:error, {:invalid_scope_field, %{field: field, reason: :missing}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_scope_value(field, value) when field in @uuid_scope_fields do
    if is_binary(value) and value != "" do
      :ok
    else
      {:error, {:invalid_scope_field, %{field: field, reason: :invalid}}}
    end
  end

  defp validate_scope_value(field, %DateTime{} = value) when field in @datetime_scope_fields do
    if DateTime.compare(value, value) == :eq do
      :ok
    else
      {:error, {:invalid_scope_field, %{field: field, reason: :invalid_datetime}}}
    end
  end

  defp validate_scope_value(field, _value) when field in @datetime_scope_fields do
    {:error, {:invalid_scope_field, %{field: field, reason: :invalid_datetime}}}
  end

  defp compare_scope_maps(source_scope, local_scope) do
    Enum.reduce_while(@scope_fields, :ok, fn field, :ok ->
      source_value = Map.fetch!(source_scope, field)
      local_value = Map.fetch!(local_scope, field)

      if scope_values_equal?(field, source_value, local_value) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          {:scope_mismatch,
           %{
             field: field,
             source: source_value,
             local: local_value
           }}}}
      end
    end)
  end

  defp scope_values_equal?(_field, %DateTime{} = left, %DateTime{} = right) do
    DateTime.compare(left, right) == :eq
  end

  defp scope_values_equal?(_field, left, right), do: left == right

  defp validate_currencies_map(%{currencies: currencies}) when is_map(currencies) do
    Enum.reduce_while(currencies, {:ok, %{}}, fn {currency, totals}, {:ok, acc} ->
      with :ok <- validate_currency_key(currency),
           {:ok, validated_totals} <- validate_currency_totals(currency, totals) do
        {:cont, {:ok, Map.put(acc, currency, validated_totals)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_currencies_map(_result) do
    {:error, {:invalid_currencies, %{reason: :missing}}}
  end

  defp validate_currency_key(currency) when is_binary(currency) do
    case String.trim(currency) do
      "" -> {:error, {:invalid_currency_key, %{reason: :blank}}}
      _ -> :ok
    end
  end

  defp validate_currency_key(_currency) do
    {:error, {:invalid_currency_key, %{reason: :non_string}}}
  end

  defp validate_currency_totals(currency, totals) when is_map(totals) do
    Enum.reduce_while(FinancialPrimitives.primitives(), {:ok, %{}}, fn primitive, {:ok, acc} ->
      case Map.fetch(totals, primitive) do
        :error ->
          {:halt,
           {:error,
            {:invalid_primitive, %{currency: currency, primitive: primitive, reason: :missing}}}}

        {:ok, %Decimal{} = value} ->
          {:cont, {:ok, Map.put(acc, primitive, value)}}

        {:ok, nil} ->
          {:halt,
           {:error,
            {:invalid_primitive, %{currency: currency, primitive: primitive, reason: nil}}}}

        {:ok, _value} ->
          {:halt,
           {:error,
            {:invalid_primitive,
             %{currency: currency, primitive: primitive, reason: :not_decimal}}}}
      end
    end)
  end

  defp validate_currency_totals(currency, _totals) do
    {:error, {:invalid_currencies, %{currency: currency, reason: :invalid_totals}}}
  end

  defp validate_currency_set_equivalence(source_currencies, local_currencies) do
    source_set = source_currencies |> Map.keys() |> Enum.sort()
    local_set = local_currencies |> Map.keys() |> Enum.sort()

    if source_set == local_set do
      :ok
    else
      {:error,
       {:currency_set_mismatch,
        %{
          source_currencies: source_set,
          local_currencies: local_set
        }}}
    end
  end

  defp build_comparisons(source_currencies, local_currencies) do
    currencies = source_currencies |> Map.keys() |> Enum.sort()
    primitives = FinancialPrimitives.primitives()

    comparisons =
      for currency <- currencies,
          primitive <- primitives,
          source_value = Map.fetch!(Map.fetch!(source_currencies, currency), primitive),
          local_value = Map.fetch!(Map.fetch!(local_currencies, currency), primitive) do
        %{
          currency: currency,
          primitive: primitive,
          source_value: source_value,
          local_value: local_value,
          matched?: Decimal.equal?(source_value, local_value)
        }
      end

    {:ok, comparisons}
  end
end
