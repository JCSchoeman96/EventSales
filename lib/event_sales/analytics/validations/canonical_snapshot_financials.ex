defmodule EventSales.Analytics.Validations.CanonicalSnapshotFinancials do
  @moduledoc false

  use Ash.Resource.Validation

  @canonical_fields [
    :gross_ticket_quantity,
    :refund_ticket_quantity,
    :gross_ticket_value,
    :refund_ticket_value,
    :recognised_order_count
  ]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if requires_canonical_financials?(changeset) do
      missing_fields =
        Enum.reject(@canonical_fields, &Map.has_key?(changeset.casted_attributes, &1))

      case missing_fields do
        [] ->
          :ok

        [field | _rest] ->
          {:error, field: field, message: "must be explicitly supplied for a version-2 snapshot"}
      end
    else
      :ok
    end
  end

  defp requires_canonical_financials?(%{action_type: :create} = changeset) do
    Ash.Changeset.get_attribute(changeset, :snapshot_version) == 2
  end

  defp requires_canonical_financials?(%{action_type: :update} = changeset) do
    Ash.Changeset.get_attribute(changeset, :snapshot_version) == 2 and
      Map.get(changeset.data, :snapshot_version) != 2
  end

  defp requires_canonical_financials?(_changeset), do: false
end
