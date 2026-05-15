defmodule EventSales.Catalog.Changes.MappingSideEffectsAfterAction do
  @moduledoc false

  use Ash.Resource.Change

  alias EventSales.Catalog.MappingSideEffects

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      MappingSideEffects.on_mapping_changed!(record)
      {:ok, record}
    end)
  end
end
