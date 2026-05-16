defmodule EventSales.Sales.Resources.OrderItem do
  @moduledoc """
  Normalized order line item and event/ticket reporting unit for mixed-event orders.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Sales,
    extensions: [AshStateMachine]

  alias EventSales.Sales.Changes.ValidateTicketTypeEvent

  @mapping_statuses [
    :pending_mapping_resolution,
    :mapped,
    :unmapped,
    :non_ticket,
    :ignored
  ]

  @create_accept [
    :order_id,
    :event_id,
    :ticket_type_id,
    :woo_line_item_id,
    :woo_product_id,
    :woo_variation_id,
    :name,
    :quantity,
    :line_subtotal,
    :line_total,
    :discount_total,
    :item_kind,
    :mapping_status
  ]

  postgres do
    table "sales_order_items"
    repo EventSales.Repo

    references do
      reference :order, on_delete: :delete, on_update: :update
      reference :event, on_delete: :restrict, on_update: :update
      reference :ticket_type, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index :order_id, name: "sales_order_items_order_id_idx"
      index :event_id, name: "sales_order_items_event_id_idx"
      index :ticket_type_id, name: "sales_order_items_ticket_type_id_idx"
      index :mapping_status, name: "sales_order_items_mapping_status_idx"

      index [:woo_product_id, :woo_variation_id],
        name: "sales_order_items_woo_product_variation_idx"

      index [:event_id, :mapping_status],
        name: "sales_order_items_event_mapping_status_idx"
    end
  end

  actions do
    defaults [:read]

    create :create_normalized do
      accept @create_accept
      change ValidateTicketTypeEvent
      validate compare(:quantity, greater_than: 0)
    end

    update :sync_from_order do
      accept [
        :woo_product_id,
        :woo_variation_id,
        :name,
        :quantity,
        :line_subtotal,
        :line_total,
        :discount_total
      ]

      validate compare(:quantity, greater_than: 0)
    end

    update :apply_mapping do
      accept [:event_id, :ticket_type_id, :woo_product_id, :woo_variation_id, :name]
      require_atomic? false
      validate present([:event_id, :ticket_type_id])
      change ValidateTicketTypeEvent
      change transition_state(:mapped)
      change set_attribute(:item_kind, :ticket)
    end

    update :mark_unmapped do
      change transition_state(:unmapped)
    end

    update :mark_non_ticket do
      change transition_state(:non_ticket)
      change set_attribute(:item_kind, :non_ticket)
    end

    update :mark_ignored do
      change transition_state(:ignored)
    end

    update :remap do
      accept []
      require_atomic? false
      change transition_state(:pending_mapping_resolution)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :woo_line_item_id, :integer do
      allow_nil? false
      public? true
    end

    attribute :woo_product_id, :integer do
      allow_nil? false
      public? true
    end

    attribute :woo_variation_id, :integer do
      public? true
    end

    attribute :name, :string do
      public? true
    end

    attribute :quantity, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :line_subtotal, :decimal do
      allow_nil? false
      public? true
    end

    attribute :line_total, :decimal do
      allow_nil? false
      public? true
    end

    attribute :discount_total, :decimal do
      allow_nil? false
      default Decimal.new(0)
      public? true
    end

    attribute :item_kind, :atom do
      allow_nil? false
      default :unknown
      constraints one_of: [:ticket, :non_ticket, :unknown]
      public? true
    end

    attribute :mapping_status, :atom do
      allow_nil? false
      default :pending_mapping_resolution
      constraints one_of: @mapping_statuses
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :order, EventSales.Sales.Resources.Order do
      allow_nil? false
      public? true
    end

    belongs_to :event, EventSales.Catalog.Resources.Event do
      public? true
    end

    belongs_to :ticket_type, EventSales.Catalog.Resources.TicketType do
      public? true
    end
  end

  identities do
    identity :unique_order_line, [:order_id, :woo_line_item_id]
  end

  state_machine do
    state_attribute :mapping_status
    initial_states [:pending_mapping_resolution]
    default_initial_state :pending_mapping_resolution

    transitions do
      transition :apply_mapping, from: [:pending_mapping_resolution, :unmapped], to: :mapped
      transition :mark_unmapped, from: :pending_mapping_resolution, to: :unmapped
      transition :mark_non_ticket, from: :pending_mapping_resolution, to: :non_ticket
      transition :mark_ignored, from: :pending_mapping_resolution, to: :ignored
      transition :remap, from: :mapped, to: :pending_mapping_resolution
    end
  end
end
