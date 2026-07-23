defmodule EventSales.Catalog.TickeraCatalog.SourceRisk do
  @moduledoc """
  Bounded persisted source-risk fact carried from the v2 catalog feed.
  """

  @codes [
    :private_event,
    :draft_event,
    :trashed_event,
    :deleted_event,
    :private_product,
    :draft_product,
    :trashed_product,
    :deleted_product,
    :private_variation,
    :draft_variation,
    :variation_mapping_required,
    :ambiguous_variation_name,
    :subscription,
    :payment_plan,
    :membership,
    :bundle,
    :add_on,
    :unsupported_product_type,
    :missing_ticket_template,
    :unknown_product_semantics,
    :duplicate_ticket_name,
    :existing_mapping_conflict,
    :product_moved_between_events,
    :ambiguous_identity,
    :missing_source_risk_data
  ]

  @code_by_string Map.new(@codes, &{Atom.to_string(&1), &1})

  @enforce_keys [:target_type, :target_id, :code, :evidence]
  defstruct [:target_type, :target_id, :code, :evidence]

  @type t :: %__MODULE__{
          target_type: :event | :product | :variation,
          target_id: pos_integer(),
          code: atom(),
          evidence: :explicit_risky | :missing | :unknown | :unsupported
        }

  @spec from_code(atom(), pos_integer(), String.t()) :: t()
  def from_code(target_type, target_id, code) do
    normalized_code = Map.get(@code_by_string, code, :missing_source_risk_data)

    %__MODULE__{
      target_type: target_type,
      target_id: target_id,
      code: normalized_code,
      evidence: evidence(normalized_code)
    }
  end

  defp evidence(:missing_source_risk_data), do: :missing
  defp evidence(:unknown_product_semantics), do: :unknown
  defp evidence(:unsupported_product_type), do: :unsupported
  defp evidence(_code), do: :explicit_risky
end
