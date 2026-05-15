defmodule EventSales.Catalog.Changes.MappingSideEffectsAfterAction do
  @moduledoc """
  Runs mapping side effects only after the Ash data-layer transaction commits.

  Uses `Ash.Changeset.after_transaction/2` so failed validations, consistency checks,
  and unique constraints do not enqueue Oban jobs or emit cache-invalidation telemetry.
  """

  use Ash.Resource.Change

  alias EventSales.Catalog.MappingSideEffects

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, record} ->
          MappingSideEffects.on_mapping_changed!(record)
          {:ok, record}

        {:error, error} ->
          {:error, error}
      end
    end)
  end
end
