defmodule EventSales.Catalog.Resources.ProductMapping do
  @moduledoc """
  Maps WooCommerce product and optional variation IDs to events and ticket types.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Catalog,
    extensions: [AshPaperTrail.Resource]

  alias EventSales.Catalog.Changes.MappingSideEffectsAfterAction
  alias EventSales.Catalog.Changes.ValidateTicketTypeEvent

  postgres do
    table "catalog_product_mappings"
    repo EventSales.Repo

    references do
      reference :source_system, on_delete: :restrict, on_update: :update
      reference :event, on_delete: :restrict, on_update: :update
      reference :ticket_type, on_delete: :restrict, on_update: :update
    end

    custom_indexes do
      index [:source_system_id, :woo_product_id],
        unique: true,
        where: "active = TRUE AND woo_variation_id IS NULL",
        name: "catalog_mappings_unique_active_product_idx"

      index [:source_system_id, :woo_product_id, :woo_variation_id],
        unique: true,
        where: "active = TRUE AND woo_variation_id IS NOT NULL",
        name: "catalog_mappings_unique_active_variation_idx"
    end
  end

  @mapping_accept [
    :source_system_id,
    :event_id,
    :ticket_type_id,
    :woo_product_id,
    :woo_variation_id,
    :original_label,
    :current_label,
    :active
  ]

  actions do
    defaults [:read]

    create :create do
      accept @mapping_accept
      change ValidateTicketTypeEvent
      change MappingSideEffectsAfterAction
    end

    update :update do
      accept @mapping_accept
      require_atomic? false
      change ValidateTicketTypeEvent
      change MappingSideEffectsAfterAction
    end

    update :deactivate do
      accept []
      require_atomic? false
      change set_attribute(:active, false)
      change MappingSideEffectsAfterAction
    end

    update :remap do
      accept [
        :event_id,
        :ticket_type_id,
        :woo_product_id,
        :woo_variation_id,
        :original_label,
        :current_label,
        :active
      ]

      require_atomic? false
      change ValidateTicketTypeEvent
      change MappingSideEffectsAfterAction
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :woo_product_id, :integer do
      allow_nil? false
      public? true
    end

    attribute :woo_variation_id, :integer do
      public? true
    end

    attribute :original_label, :string do
      public? true
    end

    attribute :current_label, :string do
      public? true
    end

    attribute :active, :boolean do
      allow_nil? false
      default true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :source_system, EventSales.Catalog.Resources.SourceSystem do
      allow_nil? false
      public? true
    end

    belongs_to :event, EventSales.Catalog.Resources.Event do
      allow_nil? false
      public? true
    end

    belongs_to :ticket_type, EventSales.Catalog.Resources.TicketType do
      allow_nil? false
      public? true
    end
  end

  validations do
    validate present([:source_system_id, :event_id, :ticket_type_id, :woo_product_id]) do
      on [:create]
    end
  end

  paper_trail do
    change_tracking_mode :changes_only
    ignore_attributes [:inserted_at, :updated_at]
    ignore_actions [:create]
    on_actions [:update, :deactivate, :remap]
    store_action_name? true
    table_name "catalog_product_mapping_versions"
  end
end
