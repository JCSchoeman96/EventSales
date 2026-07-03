defmodule EventSales.Catalog.Resources.TicketType do
  @moduledoc """
  Reportable ticket category under an event.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Catalog

  postgres do
    table "catalog_ticket_types"
    repo EventSales.Repo

    references do
      reference :event, on_delete: :restrict, on_update: :update
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :event_id,
        :name,
        :capacity,
        :active,
        :external_ticket_type_id,
        :external_ticket_type_kind,
        :external_product_id,
        :external_variation_id,
        :source_status,
        :source_updated_at,
        :last_synced_at
      ]
    end

    update :update do
      accept [
        :name,
        :capacity,
        :active,
        :external_ticket_type_id,
        :external_ticket_type_kind,
        :external_product_id,
        :external_variation_id,
        :source_status,
        :source_updated_at,
        :last_synced_at
      ]

      require_atomic? false
    end

    update :deactivate do
      accept []
      require_atomic? false
      change set_attribute(:active, false)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :capacity, :integer do
      public? true
      constraints min: 0
    end

    attribute :active, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :external_ticket_type_id, :integer do
      public? true
    end

    attribute :external_ticket_type_kind, :atom do
      constraints one_of: [:woo_product, :woo_variation]
      public? true
    end

    attribute :external_product_id, :integer do
      public? true
    end

    attribute :external_variation_id, :integer do
      public? true
    end

    attribute :source_status, :string do
      public? true
    end

    attribute :source_updated_at, :utc_datetime_usec do
      public? true
    end

    attribute :last_synced_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :event, EventSales.Catalog.Resources.Event do
      allow_nil? false
      public? true
    end

    has_many :product_mappings, EventSales.Catalog.Resources.ProductMapping do
      destination_attribute :ticket_type_id
    end
  end

  identities do
    identity :unique_name_per_event, [:event_id, :name]
  end

  validations do
    validate present([:event_id, :name]) do
      on [:create]
    end
  end
end
