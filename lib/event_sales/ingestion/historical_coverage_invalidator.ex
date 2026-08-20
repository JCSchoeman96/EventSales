defmodule EventSales.Ingestion.HistoricalCoverageInvalidator do
  @moduledoc """
  Invalidates current historical coverage for bounded, proven Order changes.

  The caller proves that the Order changed and supplies candidate Event IDs.
  This module only evaluates current certificates against the Order's
  original source creation timestamp.
  """

  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Sales.Resources.Order

  @type skip_reason :: :no_current_coverage | :outside_sales_coverage
  @type result :: %{
          invalidated_event_ids: [String.t()],
          skipped: [%{event_id: String.t(), reason: skip_reason()}]
        }
  @type error_reason ::
          :invalid_order
          | :invalid_event_id
          | :historical_coverage_lookup_failed
          | :coverage_source_mismatch
          | :order_coverage_invalidation_failed

  @spec invalidate_order_change(term(), term()) ::
          {:ok, result()} | {:error, error_reason()}
  def invalidate_order_change(order, event_ids) do
    with :ok <- validate_order(order),
         {:ok, normalized_event_ids} <- normalize_event_ids(event_ids) do
      process_candidates(order, normalized_event_ids)
    end
  end

  defp validate_order(%Order{
         id: id,
         source_system_id: source_system_id,
         created_at_source: %DateTime{} = created_at_source
       }) do
    with {:ok, _canonical_id} <- Ecto.UUID.cast(id),
         {:ok, _canonical_source_system_id} <- Ecto.UUID.cast(source_system_id),
         true <- utc_datetime?(created_at_source) do
      :ok
    else
      _error -> {:error, :invalid_order}
    end
  end

  defp validate_order(_order), do: {:error, :invalid_order}

  defp utc_datetime?(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}),
    do: true

  defp utc_datetime?(_datetime), do: false

  defp normalize_event_ids(event_ids) when is_list(event_ids) do
    event_ids
    |> Enum.reduce_while({:ok, {MapSet.new(), []}}, fn event_id, {:ok, {seen, normalized}} ->
      case Ecto.UUID.cast(event_id) do
        {:ok, canonical_event_id} ->
          {next_seen, next_normalized} =
            deduplicate_event_id(seen, normalized, canonical_event_id)

          {:cont, {:ok, {next_seen, next_normalized}}}

        :error ->
          {:halt, {:error, :invalid_event_id}}
      end
    end)
    |> case do
      {:ok, {_seen, normalized}} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_event_ids(_event_ids), do: {:error, :invalid_event_id}

  defp deduplicate_event_id(seen, normalized, canonical_event_id) do
    case MapSet.member?(seen, canonical_event_id) do
      true ->
        {seen, normalized}

      false ->
        {MapSet.put(seen, canonical_event_id), [canonical_event_id | normalized]}
    end
  end

  defp process_candidates(order, event_ids) do
    case Enum.reduce_while(event_ids, {:ok, {[], []}}, fn event_id,
                                                          {:ok, {invalidated, skipped}} ->
           process_candidate(order, event_id, invalidated, skipped)
         end) do
      {:ok, {invalidated, skipped}} ->
        {:ok,
         %{
           invalidated_event_ids: Enum.reverse(invalidated),
           skipped: Enum.reverse(skipped)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_candidate(order, event_id, invalidated, skipped) do
    case HistoricalCoverageResolver.resolve_current(event_id) do
      {:error, :historical_coverage_not_current} ->
        {:cont,
         {:ok, {invalidated, [%{event_id: event_id, reason: :no_current_coverage} | skipped]}}}

      {:error, reason} ->
        {:halt, {:error, reason}}

      {:ok, %SyncRun{} = certificate} ->
        process_current_certificate(order, event_id, certificate, invalidated, skipped)
    end
  end

  defp process_current_certificate(
         %Order{} = order,
         event_id,
         %SyncRun{} = certificate,
         invalidated,
         skipped
       ) do
    cond do
      order.source_system_id != certificate.source_system_id ->
        {:halt, {:error, :coverage_source_mismatch}}

      order_in_sales_scope?(order, certificate) ->
        case invalidate_certificate(certificate) do
          :ok -> {:cont, {:ok, {[event_id | invalidated], skipped}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      true ->
        {:cont,
         {:ok, {invalidated, [%{event_id: event_id, reason: :outside_sales_coverage} | skipped]}}}
    end
  end

  defp order_in_sales_scope?(
         %Order{created_at_source: %DateTime{} = created_at_source},
         %SyncRun{
           coverage_start: %DateTime{} = coverage_start,
           sales_covered_through: %DateTime{} = sales_covered_through
         }
       ) do
    DateTime.compare(created_at_source, coverage_start) in [:eq, :gt] and
      DateTime.compare(created_at_source, sales_covered_through) in [:eq, :lt]
  end

  defp order_in_sales_scope?(_order, _certificate), do: false

  defp invalidate_certificate(%SyncRun{} = certificate) do
    case Ash.update(
           certificate,
           %{coverage_invalidation_reason: :historical_order_changed},
           action: :invalidate_order_coverage,
           domain: Ingestion
         ) do
      {:ok, %SyncRun{}} -> :ok
      {:ok, %SyncRun{}, _notifications} -> :ok
      _other -> {:error, :order_coverage_invalidation_failed}
    end
  rescue
    _error -> {:error, :order_coverage_invalidation_failed}
  catch
    :exit, _reason -> {:error, :order_coverage_invalidation_failed}
    :throw, _value -> {:error, :order_coverage_invalidation_failed}
  end
end
