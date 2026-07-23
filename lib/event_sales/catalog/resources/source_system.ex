defmodule EventSales.Catalog.Resources.SourceSystem do
  @moduledoc """
  WooCommerce (or future) source system for catalog and ingestion scope.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Catalog

  alias EventSales.Catalog.Changes.NormalizeBaseUrl

  postgres do
    table "catalog_source_systems"
    repo EventSales.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :name,
        :kind,
        :base_url,
        :active,
        :catalog_auto_apply_mode,
        :catalog_auto_apply_allowlisted
      ]

      change NormalizeBaseUrl
    end

    update :update do
      accept [
        :name,
        :kind,
        :base_url,
        :active,
        :catalog_auto_apply_mode,
        :catalog_auto_apply_allowlisted
      ]

      require_atomic? false
      change NormalizeBaseUrl
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

    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: [:woocommerce]
      public? true
    end

    attribute :base_url, :string do
      allow_nil? false
      public? true
    end

    attribute :active, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :catalog_auto_apply_mode, :atom do
      allow_nil? false
      default :inherit
      constraints one_of: [:inherit, :disabled, :observe, :enabled]
      public? true
    end

    attribute :catalog_auto_apply_allowlisted, :boolean do
      allow_nil? false
      default false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :events, EventSales.Catalog.Resources.Event do
      destination_attribute :source_system_id
    end

    has_many :product_mappings, EventSales.Catalog.Resources.ProductMapping do
      destination_attribute :source_system_id
    end
  end

  identities do
    identity :unique_kind_base_url, [:kind, :base_url]
  end

  validations do
    validate present([:name, :kind, :base_url]) do
      on [:create, :update]
    end

    validate attribute_does_not_equal(:base_url, "") do
      on [:create, :update]
    end
  end
end
