defmodule EventSales.Ingestion.HistoricalRefundCoverageInvalidator do
  @moduledoc """
  Invalidates current historical refund coverage for a proven Refund change.

  The caller supplies the valid before/after evidence and bounded candidate
  Event IDs. This module does not compare Refund snapshots or rediscover
  candidates; it only evaluates the supplied evidence against each Event's
  current historical coverage certificate.
  """

  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun

  @type snapshot :: %{
          required(:refund_truth) => map(),
          required(:refund_line_truth) => [map()],
          required(:parent_order_evidence) => map() | nil,
          required(:parent_order_item_evidence) => [map()]
        }

  @type scope_state :: :inside | :outside | :unknown
  @type skip_reason :: :no_current_coverage | :outside_refund_coverage

  @type result :: %{
          invalidated_event_ids: [String.t()],
          skipped: [%{event_id: String.t(), reason: skip_reason()}]
        }

  @type error_reason ::
          :invalid_refund_snapshot
          | :invalid_event_id
          | :historical_coverage_lookup_failed
          | :coverage_source_mismatch
          | :refund_scope_indeterminate
          | :refund_coverage_invalidation_failed

  @spec invalidate_refund_change(nil | term(), term(), term()) ::
          {:ok, result()} | {:error, error_reason()}
  def invalidate_refund_change(before_snapshot, after_snapshot, event_ids) do
    with :ok <- validate_before_snapshot(before_snapshot),
         :ok <- validate_snapshot(after_snapshot),
         {:ok, normalized_event_ids} <- normalize_event_ids(event_ids) do
      process_candidates(before_snapshot, after_snapshot, normalized_event_ids)
    end
  end

  defp validate_before_snapshot(nil), do: :ok

  defp validate_before_snapshot(before_snapshot),
    do: validate_snapshot(before_snapshot)

  defp validate_snapshot(snapshot) when is_map(snapshot) do
    if valid_snapshot?(snapshot), do: :ok, else: {:error, :invalid_refund_snapshot}
  end

  defp validate_snapshot(_snapshot), do: {:error, :invalid_refund_snapshot}

  defp valid_snapshot?(snapshot) do
    valid_refund_truth?(Map.get(snapshot, :refund_truth, :missing)) and
      valid_snapshot_list?(Map.get(snapshot, :refund_line_truth, :missing)) and
      valid_parent_order_evidence?(Map.get(snapshot, :parent_order_evidence, :missing)) and
      valid_snapshot_list?(Map.get(snapshot, :parent_order_item_evidence, :missing))
  end

  defp valid_refund_truth?(refund_truth) when is_map(refund_truth) do
    with {:ok, source_system_id} <- Map.fetch(refund_truth, :source_system_id),
         {:ok, source_created_at} <- Map.fetch(refund_truth, :source_created_at),
         true <- valid_uuid?(source_system_id),
         true <- optional_utc_datetime?(source_created_at) do
      true
    else
      _error -> false
    end
  end

  defp valid_refund_truth?(_refund_truth), do: false

  defp valid_parent_order_evidence?(nil), do: true

  defp valid_parent_order_evidence?(parent_order_evidence) when is_map(parent_order_evidence) do
    with {:ok, id} <- Map.fetch(parent_order_evidence, :id),
         {:ok, source_system_id} <- Map.fetch(parent_order_evidence, :source_system_id),
         {:ok, created_at_source} <- Map.fetch(parent_order_evidence, :created_at_source),
         true <- valid_uuid?(id),
         true <- valid_uuid?(source_system_id),
         true <- utc_datetime?(created_at_source) do
      true
    else
      _error -> false
    end
  end

  defp valid_parent_order_evidence?(_parent_order_evidence), do: false

  defp valid_snapshot_list?(items) when is_list(items), do: Enum.all?(items, &is_map/1)
  defp valid_snapshot_list?(_items), do: false

  defp normalize_event_ids(event_ids) when is_list(event_ids) do
    event_ids
    |> Enum.reduce_while({:ok, MapSet.new()}, fn event_id, {:ok, seen} ->
      case Ecto.UUID.cast(event_id) do
        {:ok, canonical_event_id} ->
          {:cont, {:ok, MapSet.put(seen, canonical_event_id)}}

        :error ->
          {:halt, {:error, :invalid_event_id}}
      end
    end)
    |> case do
      {:ok, seen} -> {:ok, seen |> MapSet.to_list() |> Enum.sort()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_event_ids(_event_ids), do: {:error, :invalid_event_id}

  defp process_candidates(before_snapshot, after_snapshot, event_ids) do
    case Enum.reduce_while(
           event_ids,
           {:ok, {[], []}},
           fn event_id, {:ok, {invalidated, skipped}} ->
             process_candidate(
               before_snapshot,
               after_snapshot,
               event_id,
               invalidated,
               skipped
             )
           end
         ) do
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

  defp process_candidate(
         before_snapshot,
         after_snapshot,
         event_id,
         invalidated,
         skipped
       ) do
    case resolve_current(event_id) do
      {:error, :historical_coverage_not_current} ->
        {:cont,
         {:ok, {invalidated, [%{event_id: event_id, reason: :no_current_coverage} | skipped]}}}

      {:error, reason} ->
        {:halt, {:error, reason}}

      {:ok, %SyncRun{} = certificate} ->
        case process_current_certificate(
               before_snapshot,
               after_snapshot,
               event_id,
               certificate,
               invalidated,
               skipped
             ) do
          {:error, reason} -> {:halt, {:error, reason}}
          control -> control
        end
    end
  end

  defp resolve_current(event_id) do
    case HistoricalCoverageResolver.resolve_current(event_id) do
      {:ok, %SyncRun{} = certificate} ->
        {:ok, certificate}

      {:error, :historical_coverage_not_current} ->
        {:error, :historical_coverage_not_current}

      {:error, :invalid_event_id} ->
        {:error, :invalid_event_id}

      {:error, :historical_coverage_lookup_failed} ->
        {:error, :historical_coverage_lookup_failed}
    end
  rescue
    _error -> {:error, :historical_coverage_lookup_failed}
  catch
    :exit, _reason -> {:error, :historical_coverage_lookup_failed}
    :throw, _value -> {:error, :historical_coverage_lookup_failed}
  end

  defp process_current_certificate(
         before_snapshot,
         after_snapshot,
         event_id,
         certificate,
         invalidated,
         skipped
       ) do
    case verify_source_authority(before_snapshot, after_snapshot, certificate) do
      :ok ->
        {:ok, after_scope} = classify_scope(after_snapshot, certificate)

        process_after_scope(
          before_snapshot,
          after_scope,
          event_id,
          certificate,
          invalidated,
          skipped
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_after_scope(
         nil,
         after_scope,
         event_id,
         certificate,
         invalidated,
         skipped
       ) do
    process_new_refund(after_scope, event_id, certificate, invalidated, skipped)
  end

  defp process_after_scope(
         before_snapshot,
         after_scope,
         event_id,
         certificate,
         invalidated,
         skipped
       ) do
    {:ok, before_scope} = classify_scope(before_snapshot, certificate)

    process_existing_refund(
      before_scope,
      after_scope,
      event_id,
      certificate,
      invalidated,
      skipped
    )
  end

  defp verify_source_authority(before_snapshot, after_snapshot, certificate) do
    case Ecto.UUID.cast(certificate.source_system_id) do
      {:ok, certificate_source_system_id} ->
        source_system_ids =
          [before_snapshot, after_snapshot]
          |> Enum.reject(&is_nil/1)
          |> Enum.flat_map(&snapshot_source_system_ids/1)

        if Enum.all?(source_system_ids, &(&1 == certificate_source_system_id)) do
          :ok
        else
          {:error, :coverage_source_mismatch}
        end

      :error ->
        {:error, :coverage_source_mismatch}
    end
  end

  defp snapshot_source_system_ids(snapshot) do
    refund_source_system_id = Map.fetch!(snapshot.refund_truth, :source_system_id)

    parent_source_system_ids =
      case snapshot.parent_order_evidence do
        nil -> []
        parent -> [Map.fetch!(parent, :source_system_id)]
      end

    [refund_source_system_id | parent_source_system_ids]
    |> Enum.map(fn source_system_id ->
      {:ok, canonical_source_system_id} = Ecto.UUID.cast(source_system_id)
      canonical_source_system_id
    end)
  end

  defp classify_scope(snapshot, certificate) do
    with {:ok, coverage_start} <- utc_boundary(certificate.coverage_start),
         {:ok, sales_covered_through} <- utc_boundary(certificate.sales_covered_through),
         {:ok, refunds_covered_through} <- utc_boundary(certificate.refunds_covered_through),
         {:ok, created_at_source} <- parent_created_at_source(snapshot) do
      cond do
        not in_inclusive_range?(created_at_source, coverage_start, sales_covered_through) ->
          {:ok, :outside}

        refund_inside_horizon?(snapshot.refund_truth.source_created_at, refunds_covered_through) ->
          {:ok, :inside}

        true ->
          {:ok, :outside}
      end
    else
      _error -> {:ok, :unknown}
    end
  end

  defp parent_created_at_source(%{parent_order_evidence: %{created_at_source: created_at_source}})
       when is_struct(created_at_source, DateTime),
       do: {:ok, created_at_source}

  defp parent_created_at_source(_snapshot), do: {:error, :missing_parent_scope}

  defp refund_inside_horizon?(nil, _refunds_covered_through), do: true

  defp refund_inside_horizon?(%DateTime{} = source_created_at, refunds_covered_through) do
    DateTime.compare(source_created_at, refunds_covered_through) in [:eq, :lt]
  end

  defp refund_inside_horizon?(_source_created_at, _refunds_covered_through), do: false

  defp process_new_refund(:inside, event_id, certificate, invalidated, skipped) do
    case invalidate_certificate(certificate) do
      :ok -> {:cont, {:ok, {[event_id | invalidated], skipped}}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp process_new_refund(:outside, event_id, _certificate, invalidated, skipped) do
    {:cont,
     {:ok, {invalidated, [%{event_id: event_id, reason: :outside_refund_coverage} | skipped]}}}
  end

  defp process_new_refund(:unknown, _event_id, _certificate, _invalidated, _skipped),
    do: {:halt, {:error, :refund_scope_indeterminate}}

  defp process_existing_refund(
         before_scope,
         after_scope,
         event_id,
         certificate,
         invalidated,
         skipped
       ) do
    case transition_decision(before_scope, after_scope) do
      :invalidate ->
        case invalidate_certificate(certificate) do
          :ok -> {:cont, {:ok, {[event_id | invalidated], skipped}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      :outside ->
        {:cont,
         {:ok, {invalidated, [%{event_id: event_id, reason: :outside_refund_coverage} | skipped]}}}

      :indeterminate ->
        {:halt, {:error, :refund_scope_indeterminate}}
    end
  end

  defp transition_decision(before_scope, after_scope) do
    cond do
      before_scope == :inside or after_scope == :inside -> :invalidate
      before_scope == :unknown or after_scope == :unknown -> :indeterminate
      true -> :outside
    end
  end

  defp invalidate_certificate(%SyncRun{} = certificate) do
    case Ash.update(
           certificate,
           %{coverage_invalidation_reason: :historical_refund_changed},
           action: :invalidate_refund_coverage,
           domain: Ingestion
         ) do
      {:ok, %SyncRun{}} -> :ok
      {:ok, %SyncRun{}, _notifications} -> :ok
      _other -> {:error, :refund_coverage_invalidation_failed}
    end
  rescue
    _error -> {:error, :refund_coverage_invalidation_failed}
  catch
    :exit, _reason -> {:error, :refund_coverage_invalidation_failed}
    :throw, _value -> {:error, :refund_coverage_invalidation_failed}
  end

  defp in_inclusive_range?(value, lower, upper) do
    DateTime.compare(value, lower) in [:eq, :gt] and
      DateTime.compare(value, upper) in [:eq, :lt]
  end

  defp utc_boundary(%DateTime{} = value) do
    if utc_datetime?(value), do: {:ok, value}, else: {:error, :invalid_boundary}
  end

  defp utc_boundary(_value), do: {:error, :invalid_boundary}

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_value), do: false

  defp optional_utc_datetime?(nil), do: true
  defp optional_utc_datetime?(value), do: utc_datetime?(value)

  defp utc_datetime?(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}),
    do: true

  defp utc_datetime?(_value), do: false
end
