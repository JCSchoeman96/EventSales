defmodule EventSales.Ingestion.TickeraAttendeeSnapshotHash do
  @moduledoc """
  Deterministic hash for normalized Tickera attendee snapshots.
  """

  @excluded_keys MapSet.new(["api_key", "tickera_api_key"])

  @spec hash(map()) :: String.t()
  def hash(attendee) when is_map(attendee) do
    attendee
    |> canonicalize()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonicalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.reject(fn {key, _value} -> MapSet.member?(@excluded_keys, key) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Map.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value
end
