defmodule EventSales.Analytics.AggregateEventIdempotency do
  @moduledoc """
  Small state helpers for aggregate-event duplicate protection.
  """

  @type state :: %{
          required(:applied) => MapSet.t(String.t()),
          required(:in_flight) => MapSet.t(String.t()),
          optional(any()) => any()
        }

  @doc "Returns true when an event is already applied or currently being processed."
  @spec duplicate?(state(), String.t()) :: boolean()
  def duplicate?(state, aggregate_event_id) when is_binary(aggregate_event_id) do
    MapSet.member?(state.applied, aggregate_event_id) or
      MapSet.member?(state.in_flight, aggregate_event_id)
  end

  @doc "Marks an event as in-flight before recompute work starts."
  @spec reserve(state(), String.t()) :: state()
  def reserve(state, aggregate_event_id) when is_binary(aggregate_event_id) do
    %{state | in_flight: MapSet.put(state.in_flight, aggregate_event_id)}
  end

  @doc "Clears an in-flight reservation without applying it."
  @spec clear_in_flight(state(), String.t()) :: state()
  def clear_in_flight(state, aggregate_event_id) when is_binary(aggregate_event_id) do
    %{state | in_flight: MapSet.delete(state.in_flight, aggregate_event_id)}
  end

  @doc "Marks a successfully handled event as applied."
  @spec mark_applied(state(), String.t(), pos_integer()) :: state()
  def mark_applied(state, aggregate_event_id, max_entries)
      when is_binary(aggregate_event_id) and is_integer(max_entries) and max_entries > 0 do
    applied =
      state.applied
      |> MapSet.put(aggregate_event_id)
      |> trim(max_entries)

    %{state | in_flight: MapSet.delete(state.in_flight, aggregate_event_id), applied: applied}
  end

  defp trim(applied, max_entries) do
    if MapSet.size(applied) <= max_entries do
      applied
    else
      applied
      |> MapSet.to_list()
      |> Enum.take(-max_entries)
      |> MapSet.new()
    end
  end
end
