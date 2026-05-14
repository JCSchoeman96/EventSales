defmodule EventSales.TestSupport.MappingSetupHelpers do
  @moduledoc """
  Test-only mapping intent helpers for the Slice 1.5 acceptance harness.

  These helpers return plain maps only. Real Catalog resources and mappings are
  owned by later slices.
  """

  @spec completed_order_mapping_context() :: map()
  def completed_order_mapping_context do
    source_system = %{
      id: "source-system-woocommerce-synthetic",
      kind: :woocommerce,
      name: "Synthetic WooCommerce",
      base_url: "https://woocommerce.example.test"
    }

    event = %{
      id: "event-synthetic-summer-festival",
      source_system_id: source_system.id,
      name: "Synthetic Summer Festival",
      slug: "synthetic-summer-festival"
    }

    ticket_type = %{
      id: "ticket-general-admission",
      event_id: event.id,
      name: "General Admission"
    }

    product_mapping = %{
      source_system_id: source_system.id,
      event_id: event.id,
      ticket_type_id: ticket_type.id,
      woo_product_id: 501,
      woo_variation_id: 601,
      original_label: "Synthetic General Admission",
      current_label: "Synthetic General Admission",
      active: true
    }

    %{
      source_system: source_system,
      event: event,
      ticket_type: ticket_type,
      product_mapping: product_mapping,
      expected_dashboard: %{
        event_id: event.id,
        tickets_sold: 2,
        completed_revenue: "900.00",
        currency: "ZAR"
      }
    }
  end
end
