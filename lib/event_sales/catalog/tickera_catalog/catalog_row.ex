defmodule EventSales.Catalog.TickeraCatalog.CatalogRow do
  @moduledoc """
  Normalized Tickera Bridge catalog mapping candidate.
  """

  @type t :: %__MODULE__{
          tickera_event_id: integer() | nil,
          event_title: String.t() | nil,
          event_slug: String.t() | nil,
          event_status: String.t() | nil,
          event_source_updated_at: DateTime.t() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          venue_name: String.t() | nil,
          booking_fee_type: :fixed | :percentage | nil,
          booking_fee_value: Decimal.t() | nil,
          woo_product_id: integer() | nil,
          product_title: String.t() | nil,
          product_slug: String.t() | nil,
          product_status: String.t() | nil,
          product_source_updated_at: DateTime.t() | nil,
          ticket_display_name: String.t() | nil,
          ticket_type_name: String.t() | nil,
          ticket_type_kind: :woo_product | :woo_variation | nil,
          price: String.t() | nil,
          regular_price: String.t() | nil,
          ticket_template_id: String.t() | nil,
          woo_variation_id: integer() | nil,
          variation_title: String.t() | nil,
          variation_status: String.t() | nil,
          variation_source_updated_at: DateTime.t() | nil
        }

  defstruct [
    :tickera_event_id,
    :event_title,
    :event_slug,
    :event_status,
    :event_source_updated_at,
    :starts_at,
    :ends_at,
    :venue_name,
    :booking_fee_type,
    :booking_fee_value,
    :woo_product_id,
    :product_title,
    :product_slug,
    :product_status,
    :product_source_updated_at,
    :ticket_display_name,
    :ticket_type_name,
    :ticket_type_kind,
    :price,
    :regular_price,
    :ticket_template_id,
    :woo_variation_id,
    :variation_title,
    :variation_status,
    :variation_source_updated_at
  ]
end
