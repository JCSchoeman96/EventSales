defmodule EventSales.Ingestion.Resources.TickeraCatalogSyncFinding do
  @moduledoc """
  Sanitized dry-run finding for Tickera catalog sync.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: EventSales.Ingestion

  @severities [:info, :warning, :blocking]

  postgres do
    table "ingestion_tickera_catalog_sync_findings"
    repo EventSales.Repo

    references do
      reference :run, on_delete: :delete, on_update: :update
    end
  end

  actions do
    defaults [:read]

    destroy :destroy_for_retry do
      require_atomic? false
    end

    create :create do
      accept [
        :run_id,
        :severity,
        :code,
        :message,
        :tickera_event_id,
        :woo_product_id,
        :woo_variation_id,
        :metadata
      ]

      validate present([:run_id, :severity, :code, :message])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :severity, :atom do
      allow_nil? false
      constraints one_of: @severities
      public? true
    end

    attribute :code, :atom do
      allow_nil? false
      public? true
    end

    attribute :message, :string do
      allow_nil? false
      public? true
    end

    attribute :tickera_event_id, :integer do
      public? true
    end

    attribute :woo_product_id, :integer do
      public? true
    end

    attribute :woo_variation_id, :integer do
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :run, EventSales.Ingestion.Resources.TickeraCatalogSyncRun do
      allow_nil? false
      public? true
    end
  end
end
