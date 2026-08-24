defmodule EventSales.Ingestion.HistoricalOrderCoverageCandidateResolver do
  @moduledoc """
  Resolves exact Event candidates for an already accepted historical Order
  mutation.

  Persisted `OrderItem.event_id` values remain authoritative. For unresolved
  items, a trusted positive Tickera Event ID is resolved only inside the
  Order's source system. ProductMapping and other catalogue attributes are not
  candidate authority.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Sales.Resources.Order

  @untrusted_source_reasons [
    :invalid_source_tickera_event_id,
    :source_event_identity_conflict
  ]

  @type snapshot :: %{required(:order_items) => [map()]}
  @type error_reason ::
          :invalid_order
          | :invalid_historical_order_snapshot
          | :invalid_explicit_event_id
          | :historical_order_candidate_lookup_failed

  @doc """
  Returns the deterministic union of persisted, exact source, and explicit
  Event UUID candidates for a proven historical Order mutation.

  `before_snapshot` is `nil` for a newly created Order. The resolver does not
  compare snapshots and therefore never decides whether a mutation changed.
  """
  @spec resolve(Order.t(), snapshot() | nil, snapshot(), [term()]) ::
          {:ok, [Ecto.UUID.t()]} | {:error, error_reason()}
  def resolve(order, before_snapshot, after_snapshot, explicit_event_ids \\ []) do
    with {:ok, source_system_id} <- validate_order(order),
         :ok <- validate_snapshots(before_snapshot, after_snapshot),
         {:ok, persisted_event_ids, source_event_ids} <-
           snapshot_evidence(before_snapshot, after_snapshot),
         {:ok, explicit_event_ids} <- normalize_explicit_event_ids(explicit_event_ids),
         {:ok, resolved_source_event_ids} <-
           resolve_source_event_ids(source_system_id, source_event_ids) do
      {:ok,
       (persisted_event_ids ++ resolved_source_event_ids ++ explicit_event_ids)
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  defp validate_order(%Order{id: id, source_system_id: source_system_id}) do
    with {:ok, _canonical_id} <- Ecto.UUID.cast(id),
         {:ok, canonical_source_system_id} <- Ecto.UUID.cast(source_system_id) do
      {:ok, canonical_source_system_id}
    else
      _error -> {:error, :invalid_order}
    end
  end

  defp validate_order(_order), do: {:error, :invalid_order}

  defp validate_snapshots(nil, after_snapshot), do: validate_snapshot(after_snapshot)

  defp validate_snapshots(before_snapshot, after_snapshot) do
    with :ok <- validate_snapshot(before_snapshot) do
      validate_snapshot(after_snapshot)
    end
  end

  defp validate_snapshot(%{} = snapshot) do
    case Map.get(snapshot, :order_items) do
      order_items when is_list(order_items) ->
        if Enum.all?(order_items, &is_map/1) do
          :ok
        else
          {:error, :invalid_historical_order_snapshot}
        end

      _other ->
        {:error, :invalid_historical_order_snapshot}
    end
  end

  defp validate_snapshot(_snapshot), do: {:error, :invalid_historical_order_snapshot}

  defp snapshot_evidence(before_snapshot, after_snapshot) do
    [before_snapshot, after_snapshot]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while({:ok, MapSet.new(), MapSet.new()}, fn snapshot, evidence ->
      snapshot
      |> Map.get(:order_items)
      |> snapshot_evidence_for_items(evidence)
      |> case do
        {:ok, persisted, source} -> {:cont, {:ok, persisted, source}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, persisted, source} ->
        {:ok, Enum.sort(MapSet.to_list(persisted)), Enum.sort(MapSet.to_list(source))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp snapshot_evidence_for_items(order_items, evidence) do
    Enum.reduce_while(order_items, evidence, fn item, {:ok, persisted, source} ->
      case persisted_event_id(item) do
        {:ok, nil} ->
          {:cont, {:ok, persisted, add_trusted_source_id(source, item)}}

        {:ok, event_id} ->
          {:cont, {:ok, MapSet.put(persisted, event_id), source}}

        :error ->
          {:halt, {:error, :invalid_historical_order_snapshot}}
      end
    end)
  end

  defp persisted_event_id(item) do
    case item_value(item, :event_id) do
      nil -> {:ok, nil}
      event_id -> canonical_uuid(event_id)
    end
  end

  defp add_trusted_source_id(source_ids, item) do
    source_event_id = item_value(item, :source_tickera_event_id)
    reason = item_value(item, :attribution_status_reason)

    if is_integer(source_event_id) and source_event_id > 0 and
         reason not in @untrusted_source_reasons do
      MapSet.put(source_ids, source_event_id)
    else
      source_ids
    end
  end

  defp item_value(item, key) do
    case Map.fetch(item, key) do
      {:ok, value} -> value
      :error -> Map.get(item, Atom.to_string(key))
    end
  end

  defp normalize_explicit_event_ids(event_ids) when is_list(event_ids) do
    Enum.reduce_while(event_ids, {:ok, MapSet.new()}, fn event_id, {:ok, normalized} ->
      case canonical_uuid(event_id) do
        {:ok, canonical_event_id} ->
          {:cont, {:ok, MapSet.put(normalized, canonical_event_id)}}

        :error ->
          {:halt, {:error, :invalid_explicit_event_id}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.sort(MapSet.to_list(normalized))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_explicit_event_ids(_event_ids),
    do: {:error, :invalid_explicit_event_id}

  defp canonical_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> :error
    end
  end

  defp resolve_source_event_ids(_source_system_id, []), do: {:ok, []}

  defp resolve_source_event_ids(source_system_id, source_event_ids) do
    Event
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        external_event_kind == :tickera_event and
        external_event_id in ^source_event_ids
    )
    |> Ash.Query.select([:id])
    |> Ash.read(domain: Catalog)
    |> case do
      {:ok, events} when is_list(events) ->
        {:ok, events |> Enum.map(& &1.id) |> Enum.sort()}

      _other ->
        {:error, :historical_order_candidate_lookup_failed}
    end
  rescue
    _error -> {:error, :historical_order_candidate_lookup_failed}
  catch
    :exit, _reason -> {:error, :historical_order_candidate_lookup_failed}
    :throw, _value -> {:error, :historical_order_candidate_lookup_failed}
  end
end
