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

  @enforce_keys [:target_type, :target_id, :code, :evidence_classification, :evidence_source]
  defstruct [
    :target_type,
    :target_id,
    :code,
    :evidence_classification,
    :evidence_source,
    :evidence_value
  ]

  @type t :: %__MODULE__{
          target_type: :event | :product | :variation,
          target_id: pos_integer(),
          code: atom(),
          evidence_classification: :explicit_risky | :missing | :unknown | :unsupported,
          evidence_source: atom(),
          evidence_value: String.t() | nil
        }

  @spec from_code(atom(), pos_integer(), String.t()) :: t()
  def from_code(target_type, target_id, code) do
    normalized_code = Map.get(@code_by_string, code, :missing_source_risk_data)

    %__MODULE__{
      target_type: target_type,
      target_id: target_id,
      code: normalized_code,
      evidence_classification: evidence(normalized_code),
      evidence_source: evidence_source(normalized_code),
      evidence_value: evidence_value(normalized_code)
    }
  end

  defp evidence(:missing_source_risk_data), do: :missing
  defp evidence(:unknown_product_semantics), do: :unknown
  defp evidence(:unsupported_product_type), do: :unsupported
  defp evidence(_code), do: :explicit_risky

  defp evidence_source(code)
       when code in [
              :private_event,
              :draft_event,
              :trashed_event,
              :deleted_event,
              :private_product,
              :draft_product,
              :trashed_product,
              :deleted_product,
              :private_variation,
              :draft_variation
            ],
       do: :wp_post_status

  defp evidence_source(:missing_ticket_template), do: :ticket_template_meta
  defp evidence_source(:subscription), do: :subscription_meta
  defp evidence_source(:unknown_product_semantics), do: :wc_product_type
  defp evidence_source(:unsupported_product_type), do: :wc_product_type
  defp evidence_source(_code), do: :planner_identity_query

  defp evidence_value(:private_event), do: "private"
  defp evidence_value(:private_product), do: "private"
  defp evidence_value(:private_variation), do: "private"
  defp evidence_value(:draft_event), do: "draft"
  defp evidence_value(:draft_product), do: "draft"
  defp evidence_value(:draft_variation), do: "draft"
  defp evidence_value(:trashed_event), do: "trash"
  defp evidence_value(:trashed_product), do: "trash"
  defp evidence_value(:deleted_event), do: "deleted"
  defp evidence_value(:deleted_product), do: "deleted"
  defp evidence_value(:missing_ticket_template), do: "missing"
  defp evidence_value(:subscription), do: "present"
  defp evidence_value(:missing_source_risk_data), do: nil
  defp evidence_value(:unknown_product_semantics), do: "unknown"
  defp evidence_value(:unsupported_product_type), do: "unsupported"
  defp evidence_value(_code), do: "mismatch"
end
