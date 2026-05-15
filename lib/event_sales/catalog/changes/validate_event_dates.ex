defmodule EventSales.Catalog.Changes.ValidateEventDates do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      starts_at = Ash.Changeset.get_attribute(changeset, :starts_at)
      ends_at = Ash.Changeset.get_attribute(changeset, :ends_at)

      if starts_at && ends_at && DateTime.compare(ends_at, starts_at) != :gt do
        Ash.Changeset.add_error(changeset,
          field: :ends_at,
          message: "must be after starts_at"
        )
      else
        changeset
      end
    end)
  end
end
