defmodule EventSales.Catalog.CacheInvalidation do
  @moduledoc """
  Telemetry-only cache invalidation facade for Slice 3.0.

  Does not touch Redis, ETS, Cachex, or Analytics cache modules. Slice 9.x owns
  real cache invalidation behavior.
  """

  alias EventSales.Telemetry

  @doc """
  Emits a cache-invalidation telemetry event for an event scope.
  """
  @spec emit_for_event(Ecto.UUID.t(), atom()) :: :ok
  def emit_for_event(event_id, reason) when is_binary(event_id) and is_atom(reason) do
    Telemetry.emit(Telemetry.cache_invalidate(), %{count: 1}, %{
      event_id: event_id,
      reason: reason
    })
  end
end
