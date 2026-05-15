defmodule EventSales.Catalog.MappingSideEffects do
  @moduledoc """
  Post-commit side effects for successful ProductMapping writes (Slice 3.0).

  Invoked only from Ash `after_action` hooks after the database transaction commits.
  """

  alias EventSales.Catalog.CacheInvalidation
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.Workers.MappingChangedWorker

  @doc """
  Enqueues a minimal recalculation job and emits cache-invalidation telemetry.
  """
  @spec on_mapping_changed!(ProductMapping.t()) :: :ok
  def on_mapping_changed!(%ProductMapping{event_id: event_id}) do
    CacheInvalidation.emit_for_event(event_id, :mapping_changed)

    %{"event_id" => event_id}
    |> MappingChangedWorker.new()
    |> Oban.insert!()

    :ok
  end
end
