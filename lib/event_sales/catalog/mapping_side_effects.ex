defmodule EventSales.Catalog.MappingSideEffects do
  @moduledoc """
  Post-commit side effects for successful ProductMapping writes (Slice 3.0).

  Invoked only from `MappingSideEffectsAfterAction` via `Ash.Changeset.after_transaction/2`
  after the database transaction commits successfully.
  """

  alias EventSales.Catalog.CacheInvalidation
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.Workers.MappingChangedWorker

  @doc """
  Enqueues a minimal recalculation job and emits cache-invalidation telemetry.
  """
  @spec on_mapping_changed!(ProductMapping.t()) :: :ok
  def on_mapping_changed!(%ProductMapping{event_id: event_id}) do
    %{"event_id" => event_id}
    |> MappingChangedWorker.new()
    |> Oban.insert!()

    CacheInvalidation.emit_for_event(event_id, :mapping_changed)

    :ok
  end
end
