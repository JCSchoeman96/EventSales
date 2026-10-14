defmodule EventSales.Analytics.EventSnapshotAffectedEvents do
  @moduledoc false

  @type snapshot :: %{required(:order_items) => [map()]}

  @spec resolve(snapshot() | nil, snapshot(), [Ecto.UUID.t() | String.t()]) ::
          {:ok, [Ecto.UUID.t()]} | {:error, :invalid_snapshot | :invalid_event_id}
  def resolve(before_snapshot, after_snapshot, explicit_event_ids \\ []) do
    with {:ok, before_event_ids} <- persisted_event_ids(before_snapshot),
         {:ok, after_event_ids} <- persisted_event_ids(after_snapshot),
         {:ok, explicit_event_ids} <- canonical_event_ids(explicit_event_ids) do
      {:ok,
       (before_event_ids ++ after_event_ids ++ explicit_event_ids)
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  defp persisted_event_ids(nil), do: {:ok, []}

  defp persisted_event_ids(%{order_items: order_items}) when is_list(order_items) do
    Enum.reduce_while(order_items, {:ok, []}, fn item, {:ok, event_ids} ->
      case Map.fetch(item, :event_id) do
        {:ok, nil} ->
          {:cont, {:ok, event_ids}}

        {:ok, event_id} ->
          case canonical_event_id(event_id) do
            {:ok, canonical_event_id} ->
              {:cont, {:ok, [canonical_event_id | event_ids]}}

            :error ->
              {:halt, {:error, :invalid_event_id}}
          end

        :error ->
          {:halt, {:error, :invalid_snapshot}}
      end
    end)
  end

  defp persisted_event_ids(_snapshot), do: {:error, :invalid_snapshot}

  defp canonical_event_ids(event_ids) when is_list(event_ids) do
    Enum.reduce_while(event_ids, {:ok, []}, fn event_id, {:ok, canonical_ids} ->
      case canonical_event_id(event_id) do
        {:ok, canonical_event_id} ->
          {:cont, {:ok, [canonical_event_id | canonical_ids]}}

        :error ->
          {:halt, {:error, :invalid_event_id}}
      end
    end)
  end

  defp canonical_event_ids(_event_ids), do: {:error, :invalid_event_id}

  defp canonical_event_id(event_id) when is_binary(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, canonical_event_id} -> {:ok, canonical_event_id}
      :error -> :error
    end
  end

  defp canonical_event_id(_event_id), do: :error
end
