defmodule EventSales.Sales.Changes.SyncStatusFromSource do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &apply_sync_attributes/1)
  end

  defp apply_sync_attributes(changeset) do
    if changeset.valid? do
      status = Ash.Changeset.get_argument_or_attribute(changeset, :status)
      updated_at_source = Ash.Changeset.get_argument_or_attribute(changeset, :updated_at_source)

      changeset =
        changeset
        |> Ash.Changeset.force_change_attribute(:status, status)
        |> Ash.Changeset.force_change_attribute(:updated_at_source, updated_at_source)

      case {status, Ash.Changeset.get_argument_or_attribute(changeset, :completed_at)} do
        {:completed, %DateTime{} = completed_at} ->
          Ash.Changeset.force_change_attribute(changeset, :completed_at, completed_at)

        _ ->
          changeset
      end
    else
      changeset
    end
  end
end
