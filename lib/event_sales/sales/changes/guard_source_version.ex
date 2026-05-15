defmodule EventSales.Sales.Changes.GuardSourceVersion do
  @moduledoc false

  use Ash.Resource.Change

  alias EventSales.Sales.SourceVersionGuard

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &validate_source_version/1)
  end

  defp validate_source_version(changeset) do
    existing = changeset.data && Map.get(changeset.data, :updated_at_source)
    incoming = Ash.Changeset.get_argument_or_attribute(changeset, :updated_at_source)

    if SourceVersionGuard.allows_update?(existing, incoming) do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :updated_at_source,
        message: "stale source update (stale_source_update)"
      )
    end
  end
end
